import XCTest

@testable import WorkspaceCore

@MainActor final class GenerationTests: XCTestCase {
  private func workspace() async throws -> (CoreDataWorkspaceRepository, Bot, UUID, ProviderConfig)
  {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "GenerationTests-\(UUID())")
    let repository = try await CoreDataWorkspaceRepository.open(
      at: directory.appendingPathComponent("workspace.sqlite"))
    addTeardownBlock {
      try await repository.close()
      try? FileManager.default.removeItem(at: directory)
    }
    let bot = Bot(name: "Research Partner")
    let conversationID = UUID()
    let config = ProviderConfig(
      name: "Fixture", apiRoot: URL(string: "https://fixture.invalid/v1")!,
      modelID: "fixture-model", credentialReference: "fixture-ref")
    try await repository.apply(.createBot(bot, conversationID: conversationID))
    try await repository.apply(.saveProvider(config))
    return (repository, bot, conversationID, config)
  }
  private func event(_ command: SendCommand, _ sequence: Int64, _ kind: GenerationEvent.Kind)
    -> WorkspaceMutation
  {
    .applyGenerationEvent(
      GenerationEvent(
        generationID: command.generationID, attemptID: command.attemptID, sequence: sequence,
        kind: kind))
  }

  func testDuplicateAndOutOfOrderDeltasAreIgnored() async throws {
    let (repository, bot, id, _) = try await workspace()
    let command = SendCommand(conversationID: id, targetBotID: bot.id, text: "Question")
    try await repository.apply(.beginGeneration(command))
    try await repository.apply(event(command, 1, .started))
    try await repository.apply(event(command, 3, .delta("Hello")))
    try await repository.apply(event(command, 3, .delta(" duplicate")))
    try await repository.apply(event(command, 2, .delta(" stale")))
    try await repository.apply(event(command, 4, .completed))
    let page = try await repository.messages(conversationID: id)
    XCTAssertEqual(page.messages.filter { $0.role == .assistant }.map(\.text), ["Hello"])
  }

  func testCancellationPreservesPartialTextAndRejectsLateDelta() async throws {
    let (repository, bot, id, _) = try await workspace()
    let command = SendCommand(conversationID: id, targetBotID: bot.id, text: "Question")
    try await repository.apply(.beginGeneration(command))
    try await repository.apply(event(command, 1, .started))
    try await repository.apply(event(command, 2, .delta("Partial")))
    try await repository.apply(
      .cancelGeneration(id: command.generationID, attemptID: command.attemptID))
    try await repository.apply(event(command, 3, .delta(" late")))
    let snapshot = try await repository.snapshot()
    let page = try await repository.messages(conversationID: id)
    XCTAssertEqual(snapshot.generations.first?.state, .cancelled)
    XCTAssertEqual(page.messages.last?.text, "Partial")
  }

  func testRetryKeepsOriginalUserAndPartialWithNewAttemptAndProvenance() async throws {
    let (repository, bot, id, _) = try await workspace()
    let command = SendCommand(conversationID: id, targetBotID: bot.id, text: "Question")
    try await repository.apply(.beginGeneration(command))
    try await repository.apply(event(command, 1, .started))
    try await repository.apply(event(command, 2, .delta("Original partial")))
    try await repository.apply(event(command, 3, .failed(.offline)))
    let attempt = UUID()
    try await repository.apply(.retryGeneration(id: command.generationID, attemptID: attempt))
    try await repository.apply(event(command, 99, .delta("Stale previous attempt")))
    try await repository.apply(
      .applyGenerationEvent(
        GenerationEvent(
          generationID: command.generationID, attemptID: attempt, sequence: 1, kind: .started)))
    try await repository.apply(
      .applyGenerationEvent(
        GenerationEvent(
          generationID: command.generationID, attemptID: attempt, sequence: 2,
          kind: .delta("New reply"))))
    let page = try await repository.messages(conversationID: id)
    XCTAssertEqual(page.messages.filter { $0.role == .user }.map(\.id), [command.userMessageID])
    XCTAssertEqual(
      page.messages.filter { $0.role == .assistant }.map(\.text), ["Original partial", "New reply"])
    XCTAssertEqual(page.messages.filter { $0.role == .event }.count, 1)
  }

  func testSpeakerNameSnapshotSurvivesBotRename() async throws {
    let (repository, original, id, _) = try await workspace()
    let command = SendCommand(conversationID: id, targetBotID: original.id, text: "Question")
    try await repository.apply(.beginGeneration(command))
    try await repository.apply(event(command, 1, .started))
    try await repository.apply(event(command, 2, .delta("Attributed reply")))
    var renamed = original
    renamed.name = "Renamed"
    try await repository.apply(.updateBot(renamed))
    let page = try await repository.messages(conversationID: id)
    XCTAssertEqual(page.messages.last?.speakerNameSnapshot, "Research Partner")
    XCTAssertEqual(page.messages.last?.speakerBotID, original.id)
  }

  func testSaveFailureMakesZeroProviderCallsAndRetainsDraft() async throws {
    let (repository, bot, id, config) = try await workspace()
    let provider = ControlledProvider()
    let coordinator = GenerationCoordinator(
      repository: repository, credentials: FixtureCredentials(), provider: provider)
    try await repository.apply(.saveDraft(Draft(conversationID: id, text: "Keep draft")))
    await repository.injectNextSaveFailure()
    do {
      _ = try await coordinator.submit(
        SendCommand(conversationID: id, targetBotID: bot.id, text: "Keep draft"),
        configuration: config)
      XCTFail("Expected persistence error")
    } catch { XCTAssertEqual(error as? WorkspaceError, .storeUnavailable) }
    let snapshot = try await repository.snapshot()
    XCTAssertEqual(provider.callCount, 0)
    XCTAssertTrue(snapshot.generations.isEmpty)
    XCTAssertEqual(snapshot.drafts.first?.text, "Keep draft")
  }

  func testMissingCredentialMakesNoMessageAndNoProviderCall() async throws {
    let (repository, bot, id, config) = try await workspace()
    let provider = ControlledProvider()
    let coordinator = GenerationCoordinator(
      repository: repository, credentials: MissingCredentials(), provider: provider)
    do {
      _ = try await coordinator.submit(
        SendCommand(conversationID: id, targetBotID: bot.id, text: "Question"),
        configuration: config)
      XCTFail("Expected missing key")
    } catch { XCTAssertEqual(error as? ProviderError, .missingCredential) }
    let page = try await repository.messages(conversationID: id)
    XCTAssertTrue(page.messages.isEmpty)
    XCTAssertEqual(provider.callCount, 0)
  }

  func testCoordinatorPersistsStreamAndCompletion() async throws {
    let (repository, bot, id, config) = try await workspace()
    let provider = ControlledProvider()
    let coordinator = GenerationCoordinator(
      repository: repository, credentials: FixtureCredentials(), provider: provider)
    var starts = provider.starts.makeAsyncIterator()
    _ = try await coordinator.submit(
      SendCommand(conversationID: id, targetBotID: bot.id, text: "Question"), configuration: config)
    let first = await starts.next()
    XCTAssertEqual(first, 0)
    provider.complete(0, text: "สวัสดี 👋")
    await coordinator.waitForIdle()
    let snapshot = try await repository.snapshot()
    let page = try await repository.messages(conversationID: id)
    XCTAssertEqual(snapshot.generations.first?.state, .completed)
    XCTAssertEqual(page.messages.last?.text, "สวัสดี 👋")
  }

  func testQueuedSameConversationCanCancelBeforeTransmission() async throws {
    let (repository, bot, id, config) = try await workspace()
    let provider = ControlledProvider()
    let coordinator = GenerationCoordinator(
      repository: repository, credentials: FixtureCredentials(), provider: provider)
    var starts = provider.starts.makeAsyncIterator()
    _ = try await coordinator.submit(
      SendCommand(conversationID: id, targetBotID: bot.id, text: "First"), configuration: config)
    _ = await starts.next()
    let queued = try await coordinator.submit(
      SendCommand(conversationID: id, targetBotID: bot.id, text: "Second"), configuration: config)
    XCTAssertEqual(provider.callCount, 1)
    try await coordinator.cancel(queued)
    provider.complete(0, text: "First answer")
    await coordinator.waitForIdle()
    XCTAssertEqual(provider.callCount, 1)
    let snapshot = try await repository.snapshot()
    XCTAssertEqual(snapshot.generations.first { $0.id == queued }?.state, .cancelled)
  }

  func testGlobalCapIsThreeAndFourthStartsAfterCompletion() async throws {
    let (repository, bot, first, config) = try await workspace()
    var targets = [(bot, first)]
    for index in 1...3 {
      let bot = Bot(name: "Bot \(index)")
      let id = UUID()
      try await repository.apply(.createBot(bot, conversationID: id))
      targets.append((bot, id))
    }
    let provider = ControlledProvider()
    let coordinator = GenerationCoordinator(
      repository: repository, credentials: FixtureCredentials(), provider: provider)
    var starts = provider.starts.makeAsyncIterator()
    for (index, target) in targets.enumerated() {
      _ = try await coordinator.submit(
        SendCommand(conversationID: target.1, targetBotID: target.0.id, text: "Question"),
        configuration: config)
      if index < 3 { _ = await starts.next() }
    }
    XCTAssertEqual(provider.callCount, 3)
    provider.complete(0, text: "Done")
    let fourth = await starts.next()
    XCTAssertEqual(fourth, 3)
    for index in 1...3 { provider.complete(index, text: "Done") }
    await coordinator.waitForIdle()
  }

  func testShutdownCancelsActiveAndQueuedWithoutReplaying() async throws {
    let (repository, bot, id, config) = try await workspace()
    let provider = ControlledProvider()
    let coordinator = GenerationCoordinator(
      repository: repository, credentials: FixtureCredentials(), provider: provider)
    var starts = provider.starts.makeAsyncIterator()
    _ = try await coordinator.submit(
      SendCommand(conversationID: id, targetBotID: bot.id, text: "First"), configuration: config)
    _ = await starts.next()
    _ = try await coordinator.submit(
      SendCommand(conversationID: id, targetBotID: bot.id, text: "Second"), configuration: config)
    try await coordinator.shutdown()
    let snapshot = try await repository.snapshot()
    XCTAssertTrue(snapshot.generations.allSatisfy { $0.state == .cancelled })
    XCTAssertEqual(provider.callCount, 1)
  }
}

private actor FixtureCredentials: CredentialStore {
  func read(_ reference: String) -> Data { Data("test-only-sentinel".utf8) }
  func write(_ secret: Data, for reference: String) {}
  func remove(_ reference: String) {}
}
private actor MissingCredentials: CredentialStore {
  func read(_ reference: String) throws -> Data { throw ProviderError.missingCredential }
  func write(_ secret: Data, for reference: String) {}
  func remove(_ reference: String) {}
}
private final class ControlledProvider: ChatProvider, @unchecked Sendable {
  private let lock = NSLock()
  private var continuations: [AsyncThrowingStream<ChatEvent, Error>.Continuation] = []
  let starts: AsyncStream<Int>
  private let startContinuation: AsyncStream<Int>.Continuation
  init() { (starts, startContinuation) = AsyncStream.makeStream() }
  var callCount: Int { lock.withLock { continuations.count } }
  func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
    AsyncThrowingStream { continuation in
      let index = lock.withLock {
        continuations.append(continuation)
        return continuations.count - 1
      }
      startContinuation.yield(index)
    }
  }
  func complete(_ index: Int, text: String) {
    let continuation = lock.withLock { continuations[index] }
    continuation.yield(.text(text))
    continuation.yield(.finished)
    continuation.finish()
  }
}
