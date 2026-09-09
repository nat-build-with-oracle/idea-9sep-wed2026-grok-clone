import Foundation
import WorkspaceCore

extension PreviewWorkspace {
  func connect(
    _ repository: any WorkspaceRepository,
    credentials: any CredentialStore = SessionAwareCredentialStore(),
    provider: any ChatProvider = ProviderRouter(), displayName: String? = nil
  ) async throws {
    isLoading = true
    defer { isLoading = false }
    await botDeletionTask?.value
    cancelBotDeletion()
    cancelExportSelection?()
    // A selected-file write already in progress belongs to the old workspace. Let it
    // finish before replacing that workspace; earlier capture/choice work is invalidated.
    if isExportWriting { await exportTask?.value }
    replyContextGeneration += 1
    notice = nil
    exportStatus = nil
    exportError = nil
    selectionRequest += 1
    replyJumpGeneration += 1
    isJumpingToReply = false
    // An accepted old-workspace draft write must finish before any repository is replaced.
    draftSaveTask?.cancel()
    await draftSaveTask?.value
    try await flushDrafts()
    try await coordinator?.shutdown()
    replyPreviews = [:]
    transcriptJumpRequest = nil
    isPersistent = true
    drafts = [:]
    draftReplyIDs = [:]
    dirtyDrafts = []
    draftVersions = [:]
    messages = [:]
    selectedID = nil
    selectedTargetBotIDs = [:]
    self.repository = repository
    self.credentials = credentials
    self.chatProvider = provider
    name =
      displayName ?? UserDefaults.standard.string(forKey: "workspace.displayName")
      ?? "Your workspace"
    // Never silently replay an unfinished request after restart.
    try await repository.apply(.interruptPendingGenerations)
    try await refreshPersistent()
    selectedID = conversations.first?.id
    if let selectedID { try await loadMessages(selectedID) }
    makeCoordinator()
  }

  func refreshPersistent() async throws {
    guard let repository else { throw WorkspaceError.storeUnavailable }
    let snapshot = try await repository.snapshot()
    providers = snapshot.providers.sorted {
      $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
    if !providers.contains(where: { $0.id == selectedProviderID }) {
      selectedProviderID = providers.count == 1 ? providers.first?.id : nil
    }
    generations = snapshot.generations
    bots = snapshot.bots.map { bot in
      var projected = PreviewBot(
        id: bot.id, name: bot.name, description: bot.description,
        color: bot.color, shape: AvatarKind(rawValue: bot.shape.rawValue) ?? .circle)
      projected.isHidden = bot.hiddenAt != nil
      return projected
    }
    conversations = snapshot.conversations.sorted { $0.createdAt > $1.createdAt }.map {
      PreviewConversation(
        id: $0.id, title: $0.title, kind: $0.kind == .direct ? .direct : .group,
        memberIDs: $0.memberBotIDs)
    }
    for draft in snapshot.drafts where !dirtyDrafts.contains(draft.conversationID) {
      drafts[draft.conversationID] = draft.text
      draftReplyIDs[draft.conversationID] = draft.replyToID
    }
    routines = snapshot.routines.map { routine in
      let minutes: Int
      switch routine.trigger {
      case .interval(let value): minutes = value
      case .daily: minutes = 1440
      }
      return PreviewRoutine(
        id: routine.id, botID: routine.ownerBotID, name: routine.name,
        intervalMinutes: minutes, enabled: routine.enabled)
    }
    storageError = nil
    if let selectedID { await refreshReplyPreviews(in: selectedID) }
    if !search.isEmpty { await searchPersistent() }
  }

  func loadMessages(_ id: UUID) async throws {
    guard let repository else { return }
    let context = replyContextGeneration
    let page = try await repository.messages(conversationID: id, limit: 100)
    guard context == replyContextGeneration, conversations.contains(where: { $0.id == id }) else {
      return
    }
    messages[id] = page.messages.map(projectMessage)
    if selectedID == id {
      hasOlderMessages = page.hasMore
      olderCursor = page.beforeSequence
    }
    await refreshReplyPreviews(in: id, retryUnavailable: true)
  }

  func searchPersistent() async {
    guard isPersistent, let repository else { return }
    searchRequest += 1
    let request = searchRequest
    let query = search
    do {
      let results = try await repository.search(query, includeHidden: showHidden)
      guard request == searchRequest, query == search else { return }
      persistentSearchIDs = Set(results.map(\.id))
    } catch { storageError = error.localizedDescription }
  }

  func loadOlderMessages() async {
    guard let repository, let id = selectedID, let before = olderCursor else { return }
    do {
      let page = try await repository.messages(
        conversationID: id, beforeSequence: before, limit: 100)
      guard id == selectedID else { return }
      mergeOlderMessages(page, in: id)
      await refreshReplyPreviews(in: id)
    } catch { storageError = error.localizedDescription }
  }

  func projectMessage(_ message: Message) -> PreviewMessage {
    let role: PreviewMessage.Role
    switch message.role {
    case .user: role = .user
    case .assistant: role = .assistant
    case .event: role = .event
    }
    return PreviewMessage(
      role, message.text,
      timestamp: message.createdAt.formatted(date: .abbreviated, time: .shortened), id: message.id,
      speakerName: message.speakerNameSnapshot, replyToID: message.replyToID,
      sequence: message.sequence)
  }

  func scheduleDraftSave(_ id: UUID) {
    dirtyDrafts.insert(id)
    draftVersions[id, default: 0] += 1
    draftSaveTask?.cancel()
    draftSaveTask = Task { [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(300))
        try Task.checkCancellation()
        try await self?.flushDrafts()
      } catch is CancellationError {} catch { self?.storageError = error.localizedDescription }
    }
  }

  func flushDrafts() async throws {
    guard isPersistent, let repository else { return }
    // One in-flight writer: an older paused flush must never restore a sent draft later.
    while !dirtyDrafts.isEmpty || draftFlushTask != nil {
      if let draftFlushTask {
        try await draftFlushTask.value
      } else {
        let task = Task { @MainActor in
          defer { self.draftFlushTask = nil }
          try await self.writeDirtyDrafts(to: repository)
        }
        draftFlushTask = task
        try await task.value
      }
    }
  }

  private func writeDirtyDrafts(to repository: any WorkspaceRepository) async throws {
    while !dirtyDrafts.isEmpty {
      for id in Array(dirtyDrafts) {
        let version = draftVersions[id]
        let draft = Draft(
          conversationID: id, text: drafts[id] ?? "", replyToID: draftReplyIDs[id])
        try await repository.apply(.saveDraft(draft))
        if version == draftVersions[id] { dirtyDrafts.remove(id) }
      }
    }
    if dirtyDrafts.isEmpty { storageError = nil }
  }

  @discardableResult func performCreateBot(
    name: String, description: String, color: String, shape: AvatarKind
  ) async throws -> UUID {
    guard isPersistent else {
      return try createBot(name: name, description: description, color: color, shape: shape)
    }
    guard let repository else { throw WorkspaceError.storeUnavailable }
    let bot = Bot(
      name: name, description: description, color: color,
      shape: AvatarShape(rawValue: shape.rawValue) ?? .circle)
    let conversationID = UUID()
    try await repository.apply(.createBot(bot, conversationID: conversationID))
    try await refreshPersistent()
    try await selectCreatedConversation(conversationID)
    panel = nil
    return bot.id
  }

  @discardableResult func performCreateGroup(name: String, members: [UUID]) async throws -> UUID {
    guard isPersistent else { return try createGroup(name: name, members: members) }
    guard let repository else { throw WorkspaceError.storeUnavailable }
    let group = Conversation(kind: .group, title: name, memberBotIDs: members)
    try await repository.apply(.createGroup(group))
    try await refreshPersistent()
    try await selectCreatedConversation(group.id)
    return group.id
  }

  func performToggleHidden(_ conversation: PreviewConversation) async {
    guard isPersistent else {
      toggleHidden(conversation)
      return
    }
    guard let repository, conversation.kind == .direct,
      let bot = bots.first(where: { $0.id == conversation.memberIDs.first })
    else { return }
    do {
      try await repository.apply(.setHidden(botID: bot.id, at: bot.isHidden ? nil : Date()))
      try await refreshPersistent()
    } catch { storageError = error.localizedDescription }
  }

  func performAddRoutine(name: String, prompt: String, interval: Int) async throws {
    guard isPersistent else {
      try addRoutine(name: name, interval: interval)
      return
    }
    guard let repository, let bot = currentBot else { throw WorkspaceError.missingRecord }
    let routine = Routine(
      ownerBotID: bot.id, name: name, prompt: prompt, trigger: .interval(minutes: interval),
      timezoneID: TimeZone.current.identifier, enabled: false)
    try await repository.apply(.saveRoutine(routine))
    try await refreshPersistent()
    panel = nil
    notice = "Paused routine saved. Scheduling is not connected yet."
  }

  func performSend() {
    guard !isDeletingBot else { return }
    if currentNeedsMembershipRepair {
      notice = "Repair this group's membership before sending. Your draft is kept."
      return
    }
    guard isPersistent else {
      do { try saveLocalMessage() } catch { notice = error.localizedDescription }
      return
    }
    guard selectedProvider != nil else {
      notice = "No AI provider is connected. Your draft is saved locally; no message has been sent."
      Task { do { try await flushDrafts() } catch { storageError = error.localizedDescription } }
      return
    }
    guard sendTask == nil, !isClosing else { return }
    sendTask = Task {
      defer { sendTask = nil }
      do { _ = try await submitDraft() } catch { notice = Self.providerErrorMessage(error) }
    }
  }

  func saveDisplayName(_ value: String) {
    name = value
    if isPersistent { UserDefaults.standard.set(value, forKey: "workspace.displayName") }
  }

  private func selectCreatedConversation(_ id: UUID) async throws {
    try await flushDrafts()
    selectionRequest += 1
    selectedID = id
    pickerMode = .closed
    notice = nil
    composerFocusRequest += 1
    try await loadMessages(id)
  }
}
