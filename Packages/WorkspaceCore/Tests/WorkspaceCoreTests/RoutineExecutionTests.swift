import Foundation
import XCTest

@testable import WorkspaceCore

@MainActor final class RoutineExecutionTests: XCTestCase {
  private struct Fixture {
    let repository: CoreDataWorkspaceRepository
    let url: URL
    let bot: Bot
    let conversationID: UUID
    let providerConfig: ProviderConfig
    let provider: RoutineTestProvider
    let coordinator: GenerationCoordinator
    let scheduler: RoutineScheduler
    let clock: RoutineTestClock
  }

  private func fixture(credentials: any CredentialStore = RoutineTestCredentials()) async throws
    -> Fixture
  {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "RoutineExecution-\(UUID())")
    let url = directory.appendingPathComponent("workspace.sqlite")
    let repository = try await CoreDataWorkspaceRepository.open(at: url)
    let bot = Bot(name: "Routine helper", description: "A synthetic offline fixture")
    let conversationID = UUID()
    let config = ProviderConfig(
      name: "Offline fixture", apiRoot: URL(string: "https://fixture.invalid/v1")!,
      modelID: "fixture-model", credentialReference: "fixture-only")
    try await repository.apply(.createBot(bot, conversationID: conversationID))
    try await repository.apply(.saveProvider(config))
    let provider = RoutineTestProvider()
    let coordinator = GenerationCoordinator(
      repository: repository, credentials: credentials, provider: provider)
    let clock = RoutineTestClock(Date(timeIntervalSince1970: 1_789_000_000))
    let scheduler = RoutineScheduler(
      repository: repository, coordinator: coordinator, now: { clock.now })
    addTeardownBlock {
      if let gated = credentials as? GatedRoutineCredentials { await gated.release() }
      await scheduler.shutdown()
      try? await coordinator.shutdown()
      try await repository.close()
      try? FileManager.default.removeItem(at: directory)
    }
    return Fixture(
      repository: repository, url: url, bot: bot, conversationID: conversationID,
      providerConfig: config, provider: provider, coordinator: coordinator, scheduler: scheduler,
      clock: clock)
  }

  private func routine(
    _ fixture: Fixture, enabled: Bool = false, binding: Bool = true,
    nextRunAt: Date? = nil
  ) async throws -> Routine {
    let routine = Routine(
      ownerBotID: fixture.bot.id, name: "Check-in", prompt: "Summarize the next step",
      trigger: .interval(minutes: 5), timezoneID: "Asia/Bangkok", enabled: enabled,
      nextRunAt: nextRunAt,
      providerBinding: binding ? RoutineProviderBinding(fixture.providerConfig) : nil,
      scheduleID: UUID())
    try await fixture.repository.apply(.saveRoutine(routine))
    return routine
  }

  func testRunNowWhilePausedStreamsAndPreservesEqualTextDraftAndCalendar() async throws {
    let f = try await fixture()
    let planned = f.clock.now.addingTimeInterval(300)
    let routine = try await routine(f, nextRunAt: planned)
    try await f.repository.apply(
      .saveDraft(Draft(conversationID: f.conversationID, text: routine.prompt)))
    let runID = try await f.scheduler.runNow(routineID: routine.id)
    var starts = f.provider.starts.makeAsyncIterator()
    _ = await starts.next()
    f.provider.complete(0)
    await f.coordinator.waitForIdle()
    let run = try await f.repository.routineRun(id: runID)
    XCTAssertEqual(run.status, .completed)
    XCTAssertNil(run.occurrenceID)
    XCTAssertNotNil(run.startedAt)
    XCTAssertNotNil(run.endedAt)
    let snapshot = try await f.repository.snapshot()
    XCTAssertEqual(snapshot.routines.first?.nextRunAt, planned)
    XCTAssertEqual(snapshot.drafts.first?.text, routine.prompt)
    let messages = try await f.repository.messages(conversationID: f.conversationID).messages
    XCTAssertEqual(messages.map(\.text), [routine.prompt, "Offline routine result"])
    XCTAssertEqual(messages.last?.speakerNameSnapshot, f.bot.name)
  }

  func testWakeAfterWeekRunsOneAndRecordsOlderMissesWithoutBurst() async throws {
    let f = try await fixture()
    let first = f.clock.now.addingTimeInterval(-7 * 86_400)
    let routine = try await routine(f, enabled: true, nextRunAt: first)
    try await f.scheduler.reconcile()
    var starts = f.provider.starts.makeAsyncIterator()
    _ = await starts.next()
    f.provider.complete(0)
    await f.coordinator.waitForIdle()
    try await f.scheduler.reconcile()
    let runs = try await f.repository.routineRuns(routineID: routine.id)
    XCTAssertEqual(runs.count, 2)
    XCTAssertEqual(runs.first(where: { $0.status == .skipped })?.skippedCount, 2016)
    XCTAssertEqual(runs.first(where: { $0.status == .completed })?.scheduledAt, f.clock.now)
    XCTAssertEqual(f.provider.callCount, 1)
    let snapshot = try await f.repository.snapshot()
    XCTAssertEqual(snapshot.routines.first?.nextRunAt, f.clock.now.addingTimeInterval(300))
  }

  func testDuplicateReconciliationAndRunNowCannotCreateConcurrentRoutineWork() async throws {
    let f = try await fixture()
    let routine = try await routine(f, enabled: true, nextRunAt: f.clock.now)
    async let first: Void = f.scheduler.reconcile()
    async let second: Void = f.scheduler.reconcile()
    _ = try await (first, second)
    var starts = f.provider.starts.makeAsyncIterator()
    _ = await starts.next()
    do {
      _ = try await f.scheduler.runNow(routineID: routine.id)
      XCTFail("An active routine must not create another run")
    } catch { XCTAssertEqual(error as? WorkspaceError, .identityConflict) }
    let runs = try await f.repository.routineRuns(routineID: routine.id)
    XCTAssertEqual(runs.count, 1)
    XCTAssertEqual(f.provider.callCount, 1)
    f.provider.complete(0)
    await f.coordinator.waitForIdle()
  }

  func testLegacyMissingBindingRecordsBlockedAndDoesNotLoopOrBorrowProvider() async throws {
    let f = try await fixture()
    let routine = try await routine(f, enabled: true, binding: false, nextRunAt: f.clock.now)
    try await f.scheduler.reconcile()
    try await f.scheduler.reconcile()
    let runs = try await f.repository.routineRuns(routineID: routine.id)
    XCTAssertEqual(runs.count, 1)
    XCTAssertEqual(runs.first?.status, .blocked)
    XCTAssertEqual(runs.first?.error, .missingProvider)
    XCTAssertEqual(f.provider.callCount, 0)
    let snapshot = try await f.repository.snapshot()
    XCTAssertTrue(snapshot.generations.isEmpty)
    XCTAssertEqual(snapshot.routines.first?.nextRunAt, f.clock.now.addingTimeInterval(300))
  }

  func testProviderDestinationChangeRequiresNewRoutineAuthorization() async throws {
    let f = try await fixture()
    let routine = try await routine(f)
    var changed = f.providerConfig
    changed.apiRoot = URL(string: "https://other.invalid/v1")!
    try await f.repository.apply(.saveProvider(changed))
    let id = try await f.scheduler.runNow(routineID: routine.id)
    let run = try await f.repository.routineRun(id: id)
    XCTAssertEqual(run.status, .blocked)
    XCTAssertEqual(run.error, .providerChanged)
    XCTAssertEqual(f.provider.callCount, 0)
  }

  func testMissingCredentialIsVisibleBlockedNotFakeSuccess() async throws {
    let f = try await fixture(credentials: RoutineTestCredentials(missing: true))
    let routine = try await routine(f)
    let id = try await f.scheduler.runNow(routineID: routine.id)
    let run = try await f.repository.routineRun(id: id)
    XCTAssertEqual(run.status, .blocked)
    XCTAssertEqual(run.error, .missingCredential)
    XCTAssertEqual(f.provider.callCount, 0)
  }

  func testExportRoundTripsRunHistoryWithoutCredentialReferencesOrValues() async throws {
    let f = try await fixture(credentials: RoutineTestCredentials(missing: true))
    let routine = try await routine(f)
    let id = try await f.scheduler.runNow(routineID: routine.id)
    let run = try await f.repository.routineRun(id: id)
    let document = try await f.repository.exportSnapshot()
    let data = try document.encoded()
    let decoded = try JSONDecoder().decode(WorkspaceExportDocument.self, from: data)
    XCTAssertEqual(decoded.formatVersion, 3)
    XCTAssertEqual(decoded.sourceSchemaVersion, 3)
    XCTAssertEqual(decoded.summary.routineRunCount, 1)
    XCTAssertEqual(decoded.routineRuns, [run])
    XCTAssertEqual(
      decoded.routineRuns.first?.providerBinding, RoutineProviderBinding(f.providerConfig))
    let json = String(decoding: data, as: UTF8.self)
    XCTAssertFalse(json.contains(f.providerConfig.credentialReference))
    XCTAssertFalse(json.contains("synthetic-routine-fixture"))
    XCTAssertEqual(f.provider.callCount, 0)
  }

  func testClaimSaveFailureMakesZeroProviderCallsAndNoRun() async throws {
    let f = try await fixture()
    let routine = try await routine(f)
    await f.repository.injectNextSaveFailure()
    do {
      _ = try await f.scheduler.runNow(routineID: routine.id)
      XCTFail("Expected persistence failure")
    } catch { XCTAssertEqual(error as? WorkspaceError, .storeUnavailable) }
    let runs = try await f.repository.routineRuns(routineID: routine.id)
    XCTAssertTrue(runs.isEmpty)
    XCTAssertEqual(f.provider.callCount, 0)
  }

  func testDestinationChangeDuringCredentialReadIsRecheckedBeforeEffect() async throws {
    let credentials = GatedRoutineCredentials()
    let f = try await fixture(credentials: credentials)
    let routine = try await routine(f)
    let task = Task { try await f.scheduler.runNow(routineID: routine.id) }
    var reads = credentials.reads.makeAsyncIterator()
    _ = await reads.next()
    var changed = f.providerConfig
    changed.modelID = "different-model"
    try await f.repository.apply(.saveProvider(changed))
    await credentials.release()
    _ = try? await task.value
    let runs = try await f.repository.routineRuns(routineID: routine.id)
    XCTAssertEqual(runs.first?.status, .blocked)
    XCTAssertEqual(runs.first?.error, .providerChanged)
    XCTAssertEqual(f.provider.callCount, 0)
  }

  func testStopDuringCredentialReadPreventsDispatchAndKeepsTerminalCancellation() async throws {
    let credentials = GatedRoutineCredentials()
    let f = try await fixture(credentials: credentials)
    let routine = try await routine(f)
    let task = Task { try await f.scheduler.runNow(routineID: routine.id) }
    var reads = credentials.reads.makeAsyncIterator()
    _ = await reads.next()
    let runs = try await f.repository.routineRuns(routineID: routine.id)
    let run = try XCTUnwrap(runs.first)
    // Cancel at the coordinator boundary while credential I/O remains suspended.
    try await f.coordinator.cancelRoutine(run.id)
    await credentials.release()
    _ = try? await task.value
    let cancelled = try await f.repository.routineRun(id: run.id)
    XCTAssertEqual(cancelled.status, .cancelled)
    XCTAssertEqual(f.provider.callCount, 0)
    let snapshot = try await f.repository.snapshot()
    XCTAssertTrue(snapshot.generations.isEmpty)
  }

  func testGenerationSaveFailureAfterClaimRecordsFailureWithoutClearingDraft() async throws {
    let credentials = GatedRoutineCredentials()
    let f = try await fixture(credentials: credentials)
    let routine = try await routine(f)
    try await f.repository.apply(
      .saveDraft(Draft(conversationID: f.conversationID, text: "Keep typing")))
    let task = Task { try await f.scheduler.runNow(routineID: routine.id) }
    var reads = credentials.reads.makeAsyncIterator()
    _ = await reads.next()
    await f.repository.injectNextSaveFailure()
    await credentials.release()
    do {
      _ = try await task.value
      XCTFail("Expected generation-save failure")
    } catch { XCTAssertEqual(error as? WorkspaceError, .storeUnavailable) }
    let runs = try await f.repository.routineRuns(routineID: routine.id)
    XCTAssertEqual(runs.first?.status, .blocked)
    XCTAssertEqual(runs.first?.error, .storageUnavailable)
    let snapshot = try await f.repository.snapshot()
    XCTAssertTrue(snapshot.generations.isEmpty)
    XCTAssertEqual(snapshot.drafts.first?.text, "Keep typing")
    XCTAssertEqual(f.provider.callCount, 0)
  }

  func testPauseDoesNotCancelActiveRunButPreventsNextScheduledDispatch() async throws {
    let f = try await fixture()
    let routine = try await routine(f, enabled: true, nextRunAt: f.clock.now)
    try await f.scheduler.reconcile()
    var starts = f.provider.starts.makeAsyncIterator()
    _ = await starts.next()
    let snapshot = try await f.repository.snapshot()
    let current = try XCTUnwrap(snapshot.routines.first)
    var paused = current
    paused.enabled = false
    try await f.repository.apply(.editRoutine(expected: current, replacement: paused))
    f.clock.advance(3600)
    try await f.scheduler.reconcile()
    XCTAssertEqual(f.provider.callCount, 1)
    f.provider.complete(0)
    await f.coordinator.waitForIdle()
    let runs = try await f.repository.routineRuns(routineID: routine.id)
    XCTAssertEqual(runs.first?.status, .completed)
  }

  func testStopPreservesPartialReplyAndRejectsLateProviderEvents() async throws {
    let f = try await fixture()
    let routine = try await routine(f)
    let id = try await f.scheduler.runNow(routineID: routine.id)
    var starts = f.provider.starts.makeAsyncIterator()
    _ = await starts.next()
    f.provider.emit(0, text: "Partial")
    var partial = ""
    for _ in 0..<200 {
      partial =
        try await f.repository.messages(conversationID: f.conversationID).messages
        .first(where: { $0.role == .assistant })?.text ?? ""
      if partial == "Partial" { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(partial, "Partial")
    try await f.scheduler.stop(runID: id)
    f.provider.complete(0)
    await f.coordinator.waitForIdle()
    let run = try await f.repository.routineRun(id: id)
    XCTAssertEqual(run.status, .cancelled)
    let messages = try await f.repository.messages(conversationID: f.conversationID).messages
    XCTAssertEqual(messages.filter { $0.role == .assistant }.map(\.text), ["Partial"])
  }

  func testRestartInterruptsClaimedRunAndNeverSilentlyResubmitsIt() async throws {
    let f = try await fixture()
    let routine = try await routine(f, enabled: true, nextRunAt: f.clock.now)
    try await f.scheduler.reconcile()
    var starts = f.provider.starts.makeAsyncIterator()
    _ = await starts.next()
    // Simulate persisted nonterminal recovery. A separate repository test covers no-generation
    // claims; here the shared generation/run transaction must agree on interrupted state.
    try await f.repository.apply(.interruptPendingGenerations)
    try await f.coordinator.shutdown()
    try await f.repository.close()
    let reopened = try await CoreDataWorkspaceRepository.open(at: f.url)
    defer { Task { try? await reopened.close() } }
    let provider = RoutineTestProvider()
    let coordinator = GenerationCoordinator(
      repository: reopened, credentials: RoutineTestCredentials(), provider: provider)
    let scheduler = RoutineScheduler(
      repository: reopened, coordinator: coordinator, now: { f.clock.now })
    try await scheduler.reconcile()
    let runs = try await reopened.routineRuns(routineID: routine.id)
    XCTAssertEqual(runs.count, 1)
    XCTAssertEqual(runs.first?.status, .interrupted)
    XCTAssertEqual(provider.callCount, 0)
    await scheduler.shutdown()
    try await coordinator.shutdown()
    try await reopened.close()
  }

  func testShutdownDuringCredentialReadCancelsClaimBeforeHostCloses() async throws {
    let credentials = GatedRoutineCredentials()
    let f = try await fixture(credentials: credentials)
    let routine = try await routine(f)
    let task = Task { try await f.scheduler.runNow(routineID: routine.id) }
    var reads = credentials.reads.makeAsyncIterator()
    _ = await reads.next()
    let stop = Task { await f.scheduler.shutdown() }
    var cancellations = credentials.cancellations.makeAsyncIterator()
    _ = await cancellations.next()
    await credentials.release()
    await stop.value
    _ = try? await task.value
    try await f.coordinator.shutdown()
    let runs = try await f.repository.routineRuns(routineID: routine.id)
    XCTAssertEqual(runs.first?.status, .cancelled)
    XCTAssertEqual(f.provider.callCount, 0)
  }

  func testStopAfterGenerationCommitBeforeEnqueueMakesZeroProviderCalls() async throws {
    let f = try await fixture()
    let routine = try await routine(f)
    let gated = RoutineBeginGateRepository(f.repository)
    let coordinator = GenerationCoordinator(
      repository: gated, credentials: RoutineTestCredentials(), provider: f.provider)
    let scheduler = RoutineScheduler(
      repository: gated, coordinator: coordinator, now: { f.clock.now })
    let task = Task { try await scheduler.runNow(routineID: routine.id) }
    var starts = gated.commits.makeAsyncIterator()
    _ = await starts.next()
    let runs = try await f.repository.routineRuns(routineID: routine.id)
    let run = try XCTUnwrap(runs.first)
    try await coordinator.cancelRoutine(run.id)
    await gated.release()
    _ = try? await task.value
    await coordinator.waitForIdle()
    XCTAssertEqual(f.provider.callCount, 0)
    let cancelled = try await f.repository.routineRun(id: run.id)
    XCTAssertEqual(cancelled.status, .cancelled)
    let snapshot = try await f.repository.snapshot()
    XCTAssertEqual(snapshot.generations.first?.state, .cancelled)
    await scheduler.shutdown()
    try await coordinator.shutdown()
  }

  func testShutdownJoinsClaimSaveAndCancelsItEvenAfterClockRollback() async throws {
    let f = try await fixture()
    let routine = try await routine(f)
    let gated = RoutineBeginGateRepository(f.repository, pauseClaim: true)
    let coordinator = GenerationCoordinator(
      repository: gated, credentials: RoutineTestCredentials(), provider: f.provider)
    let scheduler = RoutineScheduler(
      repository: gated, coordinator: coordinator, now: { f.clock.now })
    let task = Task { try await scheduler.runNow(routineID: routine.id) }
    var commits = gated.commits.makeAsyncIterator()
    _ = await commits.next()
    var shutdownReturned = false
    let shutdown = Task {
      await scheduler.shutdown()
      shutdownReturned = true
    }
    // Observe the stop latch rather than guessing that one Task.yield scheduled shutdown. These
    // probes use missing identities and cannot claim work or contact a provider.
    var stopObserved = false
    for _ in 0..<100 {
      do { _ = try await scheduler.runNow(routineID: UUID()) } catch WorkspaceError.storeClosed {
        stopObserved = true
        break
      } catch WorkspaceError.missingRecord {}
      await Task.yield()
    }
    XCTAssertTrue(stopObserved)
    XCTAssertFalse(shutdownReturned)
    f.clock.advance(-3600)
    await gated.release()
    await shutdown.value
    _ = try? await task.value
    XCTAssertTrue(shutdownReturned)
    let runs = try await f.repository.routineRuns(routineID: routine.id)
    let run = try XCTUnwrap(runs.first)
    XCTAssertEqual(run.status, .cancelled)
    XCTAssertEqual(run.endedAt, run.createdAt)
    XCTAssertEqual(f.provider.callCount, 0)
    try await coordinator.shutdown()
  }

  func testRoutineAndInteractiveChatShareTheSameGlobalCap() async throws {
    let f = try await fixture()
    var starts = f.provider.starts.makeAsyncIterator()
    _ = try await f.coordinator.submit(
      SendCommand(conversationID: f.conversationID, targetBotID: f.bot.id, text: "Interactive"),
      configuration: f.providerConfig)
    _ = await starts.next()
    for index in 0..<3 {
      let bot = Bot(name: "Routine bot \(index)")
      try await f.repository.apply(.createBot(bot, conversationID: UUID()))
      let routine = Routine(
        ownerBotID: bot.id, name: "Bounded run \(index)", prompt: "Next step",
        trigger: .interval(minutes: 5), timezoneID: "UTC",
        providerBinding: RoutineProviderBinding(f.providerConfig))
      try await f.repository.apply(.saveRoutine(routine))
      _ = try await f.scheduler.runNow(routineID: routine.id)
      if index < 2 { _ = await starts.next() }
    }
    XCTAssertEqual(f.provider.callCount, 3)
    f.provider.complete(0)
    let fourth = await starts.next()
    XCTAssertEqual(fourth, 3)
    for index in 1...3 { f.provider.complete(index) }
    await f.coordinator.waitForIdle()
    let runs = try await f.repository.routineRuns(routineID: nil)
    XCTAssertEqual(runs.count, 3)
    XCTAssertTrue(runs.allSatisfy { $0.status == .completed })
  }

  func testDeletingRoutineHistoryCannotConvertItsGenerationIntoAnOrdinaryRetry() async throws {
    let credentials = RoutineTestCredentials()
    let f = try await fixture(credentials: credentials)
    let routine = try await routine(f)
    let id = try await f.scheduler.runNow(routineID: routine.id)
    var starts = f.provider.starts.makeAsyncIterator()
    _ = await starts.next()
    try await f.scheduler.stop(runID: id)
    let run = try await f.repository.routineRun(id: id)
    let generationID = try XCTUnwrap(run.generationID)
    try await f.repository.apply(.deleteRoutine(expected: routine))
    let readsBefore = await credentials.readCount
    do {
      try await f.coordinator.retry(generationID, configuration: f.providerConfig)
      XCTFail("Routine provenance survives definition/history deletion")
    } catch { XCTAssertEqual(error as? WorkspaceError, .invalidRoutine) }
    let snapshot = try await f.repository.snapshot()
    XCTAssertEqual(snapshot.generations.first?.routineRunID, id)
    XCTAssertEqual(snapshot.generations.first?.state, .cancelled)
    XCTAssertEqual(f.provider.callCount, 1)
    let readsAfter = await credentials.readCount
    XCTAssertEqual(readsAfter, readsBefore)
    let messages = try await f.repository.messages(conversationID: f.conversationID).messages
    XCTAssertEqual(messages.filter { $0.role == .user }.count, 1)
  }
}

private final class RoutineTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Date
  init(_ value: Date) { self.value = value }
  var now: Date { lock.withLock { value } }
  func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}

private actor RoutineTestCredentials: CredentialStore {
  let missing: Bool
  private(set) var readCount = 0
  init(missing: Bool = false) { self.missing = missing }
  func read(_ reference: String) throws -> Data {
    readCount += 1
    if missing { throw ProviderError.missingCredential }
    return Data("synthetic-routine-fixture".utf8)
  }
  func write(_ secret: Data, for reference: String) {}
  func remove(_ reference: String) {}
}

private actor GatedRoutineCredentials: CredentialStore {
  nonisolated let reads: AsyncStream<Void>
  nonisolated let cancellations: AsyncStream<Void>
  private let continuation: AsyncStream<Void>.Continuation
  private let cancellationContinuation: AsyncStream<Void>.Continuation
  private var waiter: CheckedContinuation<Void, Never>?
  init() {
    (reads, continuation) = AsyncStream.makeStream()
    (cancellations, cancellationContinuation) = AsyncStream.makeStream()
  }
  func read(_ reference: String) async -> Data {
    await withTaskCancellationHandler {
      await withCheckedContinuation { waiter in
        self.waiter = waiter
        continuation.yield(())
      }
    } onCancel: {
      cancellationContinuation.yield(())
    }
    return Data("synthetic-routine-fixture".utf8)
  }
  func release() {
    waiter?.resume()
    waiter = nil
  }
  func write(_ secret: Data, for reference: String) {}
  func remove(_ reference: String) {}
}

private final class RoutineTestProvider: ChatProvider, @unchecked Sendable {
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
  func complete(_ index: Int) {
    let continuation = lock.withLock { continuations[index] }
    continuation.yield(.text("Offline routine result"))
    continuation.yield(.finished)
    continuation.finish()
  }
  func emit(_ index: Int, text: String) {
    lock.withLock { continuations[index] }.yield(.text(text))
  }
}

private actor RoutineBeginGateRepository: WorkspaceRepository {
  let base: CoreDataWorkspaceRepository
  let pauseClaim: Bool
  nonisolated let commits: AsyncStream<Void>
  private let continuation: AsyncStream<Void>.Continuation
  private var waiter: CheckedContinuation<Void, Never>?
  init(_ base: CoreDataWorkspaceRepository, pauseClaim: Bool = false) {
    self.base = base
    self.pauseClaim = pauseClaim
    (commits, continuation) = AsyncStream.makeStream()
  }
  func snapshot() async throws -> WorkspaceSnapshot { try await base.snapshot() }
  func apply(_ mutation: WorkspaceMutation, expectedRevision: Int64?) async throws -> Int64 {
    let revision = try await base.apply(mutation, expectedRevision: expectedRevision)
    let shouldPause: Bool
    switch mutation {
    case .beginRoutineGeneration: shouldPause = !pauseClaim
    case .claimRoutineRun: shouldPause = pauseClaim
    default: shouldPause = false
    }
    if shouldPause {
      await withCheckedContinuation { waiter in
        self.waiter = waiter
        continuation.yield(())
      }
    }
    return revision
  }
  func release() {
    waiter?.resume()
    waiter = nil
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
  func routineRuns(routineID: UUID?, limit: Int) async throws -> [RoutineRun] {
    try await base.routineRuns(routineID: routineID, limit: limit)
  }
  func routineRun(id: UUID) async throws -> RoutineRun { try await base.routineRun(id: id) }
}
