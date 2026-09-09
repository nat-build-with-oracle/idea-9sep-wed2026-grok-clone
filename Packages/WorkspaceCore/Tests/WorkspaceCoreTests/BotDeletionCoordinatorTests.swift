import XCTest

@testable import WorkspaceCore

@MainActor final class BotDeletionCoordinatorTests: XCTestCase {
  private struct Fixture {
    let repository: CoreDataWorkspaceRepository
    let target: Bot
    let targetConversationID: UUID
    let other: Bot
    let otherConversationID: UUID
    let configuration: ProviderConfig
  }

  private func fixture() async throws -> Fixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "BotDeletionCoordinatorTests-\(UUID())")
    let repository = try await CoreDataWorkspaceRepository.open(
      at: directory.appendingPathComponent("workspace.sqlite"))
    addTeardownBlock {
      try await repository.close()
      try? FileManager.default.removeItem(at: directory)
    }
    let target = Bot(name: "Delete Me")
    let other = Bot(name: "Keep Me")
    let targetConversationID = UUID()
    let otherConversationID = UUID()
    let configuration = ProviderConfig(
      name: "Fixture", apiRoot: URL(string: "https://fixture.invalid/v1")!,
      modelID: "fixture-model", credentialReference: "fixture-ref")
    try await repository.apply(.createBot(target, conversationID: targetConversationID))
    try await repository.apply(.createBot(other, conversationID: otherConversationID))
    try await repository.apply(.saveProvider(configuration))
    return Fixture(
      repository: repository, target: target, targetConversationID: targetConversationID,
      other: other, otherConversationID: otherConversationID, configuration: configuration)
  }

  func testDeletionCancelsAffectedActiveAndQueuedButPreservesUnrelatedWork() async throws {
    let fixture = try await fixture()
    let provider = DeletionControlledProvider()
    let coordinator = GenerationCoordinator(
      repository: fixture.repository, credentials: DeletionCredentials(), provider: provider)
    var starts = provider.starts.makeAsyncIterator()

    _ = try await coordinator.submit(
      SendCommand(
        conversationID: fixture.targetConversationID, targetBotID: fixture.target.id, text: "One"),
      configuration: fixture.configuration)
    _ = await starts.next()
    _ = try await coordinator.submit(
      SendCommand(
        conversationID: fixture.targetConversationID, targetBotID: fixture.target.id, text: "Two"),
      configuration: fixture.configuration)
    let unrelatedID = try await coordinator.submit(
      SendCommand(
        conversationID: fixture.otherConversationID, targetBotID: fixture.other.id, text: "Keep"),
      configuration: fixture.configuration)
    _ = await starts.next()

    let plan = try await fixture.repository.botDeletionPlan(botID: fixture.target.id)
    try await coordinator.deleteBot(expected: plan)
    // A provider that ignores its cancelled continuation cannot recreate deleted storage.
    provider.complete(0, text: "Late target event")

    XCTAssertEqual(provider.callCount, 2)
    XCTAssertEqual(provider.cancelledCount, 1)
    let afterDelete = try await fixture.repository.snapshot()
    XCTAssertFalse(afterDelete.bots.contains { $0.id == fixture.target.id })
    XCTAssertTrue(afterDelete.bots.contains { $0.id == fixture.other.id })
    XCTAssertNotNil(afterDelete.generations.first { $0.id == unrelatedID })

    provider.complete(1, text: "Still running")
    await coordinator.waitForIdle()
    let completed = try await fixture.repository.snapshot()
    XCTAssertEqual(completed.generations.first { $0.id == unrelatedID }?.state, .completed)
  }

  func testStaleConfirmationHasZeroCancellationEffects() async throws {
    let fixture = try await fixture()
    let provider = DeletionControlledProvider()
    let coordinator = GenerationCoordinator(
      repository: fixture.repository, credentials: DeletionCredentials(), provider: provider)
    var starts = provider.starts.makeAsyncIterator()
    let generationID = try await coordinator.submit(
      SendCommand(
        conversationID: fixture.targetConversationID, targetBotID: fixture.target.id,
        text: "Continue"), configuration: fixture.configuration)
    _ = await starts.next()
    let stale = try await fixture.repository.botDeletionPlan(botID: fixture.target.id)
    try await fixture.repository.apply(
      .saveRoutine(
        Routine(
          ownerBotID: fixture.target.id, name: "New content", prompt: "Do not ignore me",
          trigger: .interval(minutes: 60), timezoneID: "UTC")))

    do {
      try await coordinator.deleteBot(expected: stale)
      XCTFail("Expected changed confirmation")
    } catch {
      XCTAssertEqual(error as? BotDeletionError, .confirmationChanged)
    }
    XCTAssertEqual(provider.cancelledCount, 0)
    let snapshot = try await fixture.repository.snapshot()
    XCTAssertTrue(snapshot.bots.contains { $0.id == fixture.target.id })
    XCTAssertFalse(snapshot.generations.first { $0.id == generationID }?.state.isTerminal ?? true)

    provider.complete(0, text: "Completed")
    await coordinator.waitForIdle()
  }

  func testSuspendedCredentialReadCannotTransmitAfterDeletionUnblocks() async throws {
    let fixture = try await fixture()
    let credentials = GatedDeletionCredentials()
    let provider = DeletionControlledProvider()
    let coordinator = GenerationCoordinator(
      repository: fixture.repository, credentials: credentials, provider: provider)
    let command = SendCommand(
      conversationID: fixture.targetConversationID, targetBotID: fixture.target.id, text: "Race")
    let submit = Task {
      try await coordinator.submit(command, configuration: fixture.configuration)
    }
    await credentials.waitUntilRead()

    let plan = try await fixture.repository.botDeletionPlan(botID: fixture.target.id)
    try await coordinator.deleteBot(expected: plan)
    await credentials.release()
    do {
      _ = try await submit.value
      XCTFail("Expected invalidated submit")
    } catch {
      XCTAssertEqual(error as? WorkspaceError, .missingRecord)
    }
    XCTAssertEqual(provider.callCount, 0)
    let snapshot = try await fixture.repository.snapshot()
    XCTAssertFalse(snapshot.bots.contains { $0.id == fixture.target.id })
    XCTAssertFalse(snapshot.generations.contains { $0.id == command.generationID })
  }

  func testNewGroupWorkAfterPreviewRequiresFreshConfirmationWithoutCancellation() async throws {
    let fixture = try await fixture()
    let group = Conversation(
      kind: .group, title: "Shared", memberBotIDs: [fixture.target.id, fixture.other.id])
    try await fixture.repository.apply(.createGroup(group))
    let stale = try await fixture.repository.botDeletionPlan(botID: fixture.target.id)
    let provider = DeletionControlledProvider()
    let coordinator = GenerationCoordinator(
      repository: fixture.repository, credentials: DeletionCredentials(), provider: provider)
    var starts = provider.starts.makeAsyncIterator()
    _ = try await coordinator.submit(
      SendCommand(conversationID: group.id, targetBotID: fixture.other.id, text: "New group work"),
      configuration: fixture.configuration)
    _ = await starts.next()

    do {
      try await coordinator.deleteBot(expected: stale)
      XCTFail("Expected fresh confirmation")
    } catch {
      XCTAssertEqual(error as? BotDeletionError, .confirmationChanged)
    }
    XCTAssertEqual(provider.cancelledCount, 0)
    let unchanged = try await fixture.repository.snapshot()
    XCTAssertTrue(unchanged.bots.contains { $0.id == fixture.target.id })
    provider.complete(0, text: "Uninterrupted")
    await coordinator.waitForIdle()
  }

  func testFailedPhysicalDeleteLeavesHistoryAndRequiresExplicitRetry() async throws {
    let fixture = try await fixture()
    let repository = FailFirstDeleteRepository(base: fixture.repository)
    let provider = DeletionControlledProvider()
    let coordinator = GenerationCoordinator(
      repository: repository, credentials: DeletionCredentials(), provider: provider)
    var starts = provider.starts.makeAsyncIterator()
    let generationID = try await coordinator.submit(
      SendCommand(
        conversationID: fixture.targetConversationID, targetBotID: fixture.target.id,
        text: "Preserve this"), configuration: fixture.configuration)
    _ = await starts.next()
    let plan = try await repository.botDeletionPlan(botID: fixture.target.id)

    do {
      try await coordinator.deleteBot(expected: plan)
      XCTFail("Expected injected deletion failure")
    } catch {
      XCTAssertEqual(error as? WorkspaceError, .storeUnavailable)
    }
    let preserved = try await repository.snapshot()
    XCTAssertTrue(preserved.bots.contains { $0.id == fixture.target.id })
    XCTAssertEqual(preserved.generations.first { $0.id == generationID }?.state, .cancelled)
    let history = try await repository.messages(conversationID: fixture.targetConversationID)
    XCTAssertTrue(history.messages.contains { $0.text == "Preserve this" })
    XCTAssertEqual(provider.callCount, 1)

    try await coordinator.retry(generationID, configuration: fixture.configuration)
    _ = await starts.next()
    XCTAssertEqual(provider.callCount, 2)
    provider.complete(1, text: "Explicit retry")
    await coordinator.waitForIdle()
    let retried = try await repository.snapshot()
    XCTAssertEqual(retried.generations.first { $0.id == generationID }?.state, .completed)
  }

  func testCallerCannotWidenCancellationScopeWithForgedPlanFields() async throws {
    let fixture = try await fixture()
    let provider = DeletionControlledProvider()
    let coordinator = GenerationCoordinator(
      repository: fixture.repository, credentials: DeletionCredentials(), provider: provider)
    var starts = provider.starts.makeAsyncIterator()
    let unrelatedID = try await coordinator.submit(
      SendCommand(
        conversationID: fixture.otherConversationID, targetBotID: fixture.other.id,
        text: "Must remain active"), configuration: fixture.configuration)
    _ = await starts.next()
    let actual = try await fixture.repository.botDeletionPlan(botID: fixture.target.id)
    let forged = BotDeletionPlan(
      botID: actual.botID, name: actual.name,
      directConversationIDs: actual.directConversationIDs, messageIDs: actual.messageIDs,
      draftConversationIDs: actual.draftConversationIDs, generationIDs: actual.generationIDs,
      routineIDs: actual.routineIDs, affectedGroups: actual.affectedGroups,
      activeGenerationIDs: actual.activeGenerationIDs + [unrelatedID],
      cancellationConversationIDs: actual.cancellationConversationIDs
        + [fixture.otherConversationID])

    try await coordinator.deleteBot(expected: forged)
    XCTAssertEqual(provider.cancelledCount, 0)
    let stillRunning = try await fixture.repository.snapshot()
    let unrelatedIsTerminal =
      stillRunning.generations.first { $0.id == unrelatedID }?.state.isTerminal ?? true
    XCTAssertFalse(unrelatedIsTerminal)
    provider.complete(0, text: "Unrelated completed")
    await coordinator.waitForIdle()
    let snapshot = try await fixture.repository.snapshot()
    XCTAssertEqual(snapshot.generations.first { $0.id == unrelatedID }?.state, .completed)
  }

  func testRetrySuspendedOnInitialSnapshotCannotReadCredentialsAfterDeletion() async throws {
    let fixture = try await fixture()
    let command = SendCommand(
      conversationID: fixture.targetConversationID, targetBotID: fixture.target.id,
      text: "Terminal first")
    try await fixture.repository.apply(.beginGeneration(command))
    try await fixture.repository.apply(
      .applyGenerationEvent(
        GenerationEvent(
          generationID: command.generationID, attemptID: command.attemptID, sequence: 1,
          kind: .failed(.offline))))
    let repository = PauseNextSnapshotRepository(base: fixture.repository)
    let credentials = CountingDeletionCredentials()
    let provider = DeletionControlledProvider()
    let coordinator = GenerationCoordinator(
      repository: repository, credentials: credentials, provider: provider)
    await repository.pauseNextSnapshot()
    let retry = Task {
      try await coordinator.retry(command.generationID, configuration: fixture.configuration)
    }
    await repository.waitUntilPaused()

    let plan = try await fixture.repository.botDeletionPlan(botID: fixture.target.id)
    try await coordinator.deleteBot(expected: plan)
    await repository.release()
    do {
      try await retry.value
      XCTFail("Expected invalidated retry")
    } catch {
      XCTAssertEqual(error as? WorkspaceError, .missingRecord)
    }
    let readCount = await credentials.readCount
    XCTAssertEqual(readCount, 0)
    XCTAssertEqual(provider.callCount, 0)
  }

  func testDegradedGroupIsRejectedBeforeCredentialRead() async throws {
    let fixture = try await fixture()
    let group = Conversation(
      kind: .group, title: "Valid first",
      memberBotIDs: [fixture.target.id, fixture.other.id])
    try await fixture.repository.apply(.createGroup(group))
    let repository = DegradedGroupRepository(base: fixture.repository, groupID: group.id)
    let credentials = CountingDeletionCredentials()
    let provider = DeletionControlledProvider()
    let coordinator = GenerationCoordinator(
      repository: repository, credentials: credentials, provider: provider)

    do {
      _ = try await coordinator.submit(
        SendCommand(conversationID: group.id, targetBotID: fixture.target.id, text: "Unsafe"),
        configuration: fixture.configuration)
      XCTFail("Expected invalid group")
    } catch {
      XCTAssertEqual(error as? WorkspaceError, .invalidMembers)
    }
    let readCount = await credentials.readCount
    XCTAssertEqual(readCount, 0)
    XCTAssertEqual(provider.callCount, 0)
  }
}

private actor DeletionCredentials: CredentialStore {
  func read(_ reference: String) -> Data { Data("test-only-sentinel".utf8) }
  func write(_ secret: Data, for reference: String) {}
  func remove(_ reference: String) {}
}

private actor CountingDeletionCredentials: CredentialStore {
  private(set) var readCount = 0
  func read(_ reference: String) -> Data {
    readCount += 1
    return Data("test-only-sentinel".utf8)
  }
  func write(_ secret: Data, for reference: String) {}
  func remove(_ reference: String) {}
}

private actor GatedDeletionCredentials: CredentialStore {
  private var didRead = false
  private var released = false
  private var readWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  func read(_ reference: String) async -> Data {
    didRead = true
    let waiters = readWaiters
    readWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
    if !released {
      await withCheckedContinuation { releaseWaiters.append($0) }
    }
    return Data("test-only-sentinel".utf8)
  }
  func write(_ secret: Data, for reference: String) {}
  func remove(_ reference: String) {}
  func waitUntilRead() async {
    if didRead { return }
    await withCheckedContinuation { readWaiters.append($0) }
  }
  func release() {
    released = true
    let waiters = releaseWaiters
    releaseWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }
}

private final class DeletionControlledProvider: ChatProvider, @unchecked Sendable {
  private let lock = NSLock()
  private var continuations: [AsyncThrowingStream<ChatEvent, Error>.Continuation] = []
  private var cancellations = 0
  let starts: AsyncStream<Int>
  private let startContinuation: AsyncStream<Int>.Continuation

  init() { (starts, startContinuation) = AsyncStream.makeStream() }
  var callCount: Int { lock.withLock { continuations.count } }
  var cancelledCount: Int { lock.withLock { cancellations } }

  func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
    AsyncThrowingStream { continuation in
      continuation.onTermination = { [weak self] termination in
        if case .cancelled = termination, let self {
          self.lock.withLock { self.cancellations += 1 }
        }
      }
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

private actor FailFirstDeleteRepository: WorkspaceRepository {
  let base: CoreDataWorkspaceRepository
  private var shouldFail = true
  init(base: CoreDataWorkspaceRepository) { self.base = base }
  func snapshot() async throws -> WorkspaceSnapshot { try await base.snapshot() }
  func exportSnapshot() async throws -> WorkspaceExportDocument { try await base.exportSnapshot() }
  func botDeletionPlan(botID: UUID) async throws -> BotDeletionPlan {
    try await base.botDeletionPlan(botID: botID)
  }
  func apply(_ mutation: WorkspaceMutation, expectedRevision: Int64?) async throws -> Int64 {
    if case .deleteBot = mutation, shouldFail {
      shouldFail = false
      throw WorkspaceError.storeUnavailable
    }
    return try await base.apply(mutation, expectedRevision: expectedRevision)
  }
  func messages(conversationID: UUID, beforeSequence: Int64?, limit: Int) async throws
    -> MessagePage
  {
    try await base.messages(
      conversationID: conversationID, beforeSequence: beforeSequence, limit: limit)
  }
  func search(_ query: String, includeHidden: Bool) async throws -> [Conversation] {
    try await base.search(query, includeHidden: includeHidden)
  }
  func message(id: UUID) async throws -> Message { try await base.message(id: id) }
}

private actor DegradedGroupRepository: WorkspaceRepository {
  let base: CoreDataWorkspaceRepository
  let groupID: UUID
  init(base: CoreDataWorkspaceRepository, groupID: UUID) {
    self.base = base
    self.groupID = groupID
  }
  func snapshot() async throws -> WorkspaceSnapshot {
    let value = try await base.snapshot()
    let conversations = value.conversations.map { conversation in
      guard conversation.id == groupID, let only = conversation.memberBotIDs.first else {
        return conversation
      }
      return Conversation(
        id: conversation.id, kind: .group, title: conversation.title, memberBotIDs: [only],
        createdAt: conversation.createdAt, lastReadSequence: conversation.lastReadSequence)
    }
    return WorkspaceSnapshot(
      revision: value.revision, bots: value.bots, conversations: conversations,
      drafts: value.drafts, generations: value.generations, routines: value.routines,
      providers: value.providers)
  }
  func exportSnapshot() async throws -> WorkspaceExportDocument { try await base.exportSnapshot() }
  func botDeletionPlan(botID: UUID) async throws -> BotDeletionPlan {
    try await base.botDeletionPlan(botID: botID)
  }
  func apply(_ mutation: WorkspaceMutation, expectedRevision: Int64?) async throws -> Int64 {
    try await base.apply(mutation, expectedRevision: expectedRevision)
  }
  func messages(conversationID: UUID, beforeSequence: Int64?, limit: Int) async throws
    -> MessagePage
  {
    try await base.messages(
      conversationID: conversationID, beforeSequence: beforeSequence, limit: limit)
  }
  func search(_ query: String, includeHidden: Bool) async throws -> [Conversation] {
    try await base.search(query, includeHidden: includeHidden)
  }
  func message(id: UUID) async throws -> Message { try await base.message(id: id) }
}

private actor PauseNextSnapshotRepository: WorkspaceRepository {
  let base: CoreDataWorkspaceRepository
  private var shouldPause = false
  private var paused = false
  private var pauseContinuation: CheckedContinuation<Void, Never>?
  private var waitContinuation: CheckedContinuation<Void, Never>?

  init(base: CoreDataWorkspaceRepository) { self.base = base }
  func pauseNextSnapshot() { shouldPause = true }
  func waitUntilPaused() async {
    if paused { return }
    await withCheckedContinuation { waitContinuation = $0 }
  }
  func release() {
    pauseContinuation?.resume()
    pauseContinuation = nil
  }
  func snapshot() async throws -> WorkspaceSnapshot {
    let snapshot = try await base.snapshot()
    if shouldPause {
      shouldPause = false
      paused = true
      waitContinuation?.resume()
      waitContinuation = nil
      await withCheckedContinuation { pauseContinuation = $0 }
    }
    return snapshot
  }
  func exportSnapshot() async throws -> WorkspaceExportDocument { try await base.exportSnapshot() }
  func botDeletionPlan(botID: UUID) async throws -> BotDeletionPlan {
    try await base.botDeletionPlan(botID: botID)
  }
  func apply(_ mutation: WorkspaceMutation, expectedRevision: Int64?) async throws -> Int64 {
    try await base.apply(mutation, expectedRevision: expectedRevision)
  }
  func messages(conversationID: UUID, beforeSequence: Int64?, limit: Int) async throws
    -> MessagePage
  {
    try await base.messages(
      conversationID: conversationID, beforeSequence: beforeSequence, limit: limit)
  }
  func search(_ query: String, includeHidden: Bool) async throws -> [Conversation] {
    try await base.search(query, includeHidden: includeHidden)
  }
  func message(id: UUID) async throws -> Message { try await base.message(id: id) }
}
