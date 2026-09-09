import Foundation

/// Persistence-before-effect, one active reply per conversation, at most three globally.
public actor GenerationCoordinator {
  private struct Job: Sendable {
    let generationID: UUID
    let attemptID: UUID
    let conversationID: UUID
    let userMessageID: UUID
    let targetBotID: UUID
    let request: ChatRequest
  }
  private let repository: any WorkspaceRepository
  private let credentials: any CredentialStore
  private let provider: any ChatProvider
  private let onChange: @Sendable (UUID) async -> Void
  private let onError: @Sendable (String) async -> Void
  private var pending: [Job] = []
  private var active: [UUID: Task<Void, Never>] = [:]
  private var activeConversations: Set<UUID> = []
  private var shuttingDown = false

  public init(
    repository: any WorkspaceRepository, credentials: any CredentialStore,
    provider: any ChatProvider = ChatCompletionsProvider(),
    onChange: @escaping @Sendable (UUID) async -> Void = { _ in },
    onError: @escaping @Sendable (String) async -> Void = { _ in }
  ) {
    self.repository = repository
    self.credentials = credentials
    self.provider = provider
    self.onChange = onChange
    self.onError = onError
  }

  public func submit(_ command: SendCommand, configuration: ProviderConfig) async throws -> UUID {
    guard !shuttingDown else { throw WorkspaceError.storeClosed }
    let request = try await prepare(
      configuration: configuration, conversationID: command.conversationID,
      targetBotID: command.targetBotID, beforeSequence: nil, newText: command.text)
    try Task.checkCancellation()
    guard !shuttingDown else { throw WorkspaceError.storeClosed }
    // A failing save cannot reach provider.stream(). The editable draft remains in the repository.
    try await repository.apply(.beginGeneration(command))
    guard !shuttingDown else {
      try await repository.apply(
        .cancelGeneration(id: command.generationID, attemptID: command.attemptID))
      throw WorkspaceError.storeClosed
    }
    pending.append(
      Job(
        generationID: command.generationID, attemptID: command.attemptID,
        conversationID: command.conversationID, userMessageID: command.userMessageID,
        targetBotID: command.targetBotID, request: request))
    pump()
    await onChange(command.conversationID)
    return command.generationID
  }

  public func retry(_ generationID: UUID, configuration: ProviderConfig) async throws {
    guard !shuttingDown else { throw WorkspaceError.storeClosed }
    let snapshot = try await repository.snapshot()
    guard let generation = snapshot.generations.first(where: { $0.id == generationID }),
      [.failed, .cancelled, .interrupted].contains(generation.state), active[generationID] == nil
    else {
      throw WorkspaceError.identityConflict
    }
    let message = try await repository.message(id: generation.userMessageID)
    let request = try await prepare(
      configuration: configuration, conversationID: generation.conversationID,
      targetBotID: generation.targetBotID, beforeSequence: message.sequence + 1, newText: nil)
    let attempt = UUID()
    guard !shuttingDown else { throw WorkspaceError.storeClosed }
    try await repository.apply(.retryGeneration(id: generationID, attemptID: attempt))
    guard !shuttingDown else {
      try await repository.apply(.cancelGeneration(id: generationID, attemptID: attempt))
      throw WorkspaceError.storeClosed
    }
    pending.append(
      Job(
        generationID: generationID, attemptID: attempt,
        conversationID: generation.conversationID, userMessageID: generation.userMessageID,
        targetBotID: generation.targetBotID, request: request))
    pump()
    await onChange(generation.conversationID)
  }

  public func cancel(_ generationID: UUID) async throws {
    let snapshot = try await repository.snapshot()
    guard let generation = snapshot.generations.first(where: { $0.id == generationID }) else {
      return
    }
    try await repository.apply(.cancelGeneration(id: generationID, attemptID: generation.attemptID))
    pending.removeAll { $0.generationID == generationID }
    active[generationID]?.cancel()
    pump()
    await onChange(generation.conversationID)
  }

  public func shutdown() async throws {
    shuttingDown = true
    let ids = Set(pending.map(\.generationID)).union(active.keys)
    for id in ids { try await cancel(id) }
    await waitForIdle()
  }

  public func waitForIdle() async {
    while !active.isEmpty || !pending.isEmpty {
      if let task = active.values.first { await task.value } else { pump() }
    }
  }

  private func prepare(
    configuration: ProviderConfig, conversationID: UUID, targetBotID: UUID,
    beforeSequence: Int64?, newText: String?
  ) async throws -> ChatRequest {
    let snapshot = try await repository.snapshot()
    guard snapshot.providers.contains(configuration),
      let bot = snapshot.bots.first(where: { $0.id == targetBotID }),
      let conversation = snapshot.conversations.first(where: { $0.id == conversationID }),
      conversation.memberBotIDs.contains(targetBotID)
    else { throw WorkspaceError.invalidProvider }
    let credential = try await credentials.read(configuration.credentialReference)
    let page = try await repository.messages(
      conversationID: conversationID, beforeSequence: beforeSequence, limit: 100)
    var turns = [ChatTurn(role: "system", content: "You are \(bot.name).\n\(bot.description)")]
    turns += page.messages.compactMap { message in
      guard message.role != .event, !message.text.isEmpty else { return nil }
      return ChatTurn(role: message.role == .user ? "user" : "assistant", content: message.text)
    }
    if let newText { turns.append(ChatTurn(role: "user", content: newText)) }
    let request = ChatRequest(provider: configuration, turns: turns, credential: credential)
    // Validate URL, key shape and payload before clearing a draft or queuing an effect.
    _ = try ChatCompletionsProvider.makeRequest(request)
    return request
  }

  private func pump() {
    while active.count < 3,
      let index = pending.firstIndex(where: { !activeConversations.contains($0.conversationID) })
    {
      let job = pending.remove(at: index)
      activeConversations.insert(job.conversationID)
      active[job.generationID] = Task { await self.run(job) }
    }
  }

  private func run(_ job: Job) async {
    var sequence: Int64 = 1
    do {
      try Task.checkCancellation()
      try await apply(job, sequence: sequence, kind: .started)
      try Task.checkCancellation()
      var completed = false
      for try await event in provider.stream(job.request) {
        try Task.checkCancellation()
        sequence += 1
        switch event {
        case .text(let text): try await apply(job, sequence: sequence, kind: .delta(text))
        case .finished:
          try await apply(job, sequence: sequence, kind: .completed)
          completed = true
        }
        if completed { break }
      }
      if !completed { throw ProviderError.streamEnded }
    } catch {
      if Task.isCancelled || (error as? ProviderError) == .cancelled {
        do {
          try await repository.apply(
            .cancelGeneration(id: job.generationID, attemptID: job.attemptID))
        } catch { await onError(ProviderError.storageFailure.localizedDescription) }
      } else {
        let failure =
          error is WorkspaceError ? ProviderError.storageFailure : ProviderError.sanitized(error)
        do { try await apply(job, sequence: sequence + 1, kind: .failed(failure)) } catch {
          await onError(ProviderError.storageFailure.localizedDescription)
        }
      }
      await onChange(job.conversationID)
    }
    active[job.generationID] = nil
    activeConversations.remove(job.conversationID)
    pump()
  }

  private func apply(_ job: Job, sequence: Int64, kind: GenerationEvent.Kind) async throws {
    try await repository.apply(
      .applyGenerationEvent(
        GenerationEvent(
          generationID: job.generationID,
          attemptID: job.attemptID, sequence: sequence, kind: kind)))
    await onChange(job.conversationID)
  }
}
