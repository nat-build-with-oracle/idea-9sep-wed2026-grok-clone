import Foundation
import XCTest

@testable import NativeShell
@testable import WorkspaceCore

@MainActor final class RoutineWorkspaceTests: XCTestCase {
  private struct Fixture {
    let store: PreviewWorkspace
    let repository: CoreDataWorkspaceRepository
    let routine: Routine
    let provider: ProviderConfig
    let directID: UUID
    let groupID: UUID
  }

  private func fixture(enabled: Bool = false, due: Date? = nil) async throws -> Fixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "RoutineNative-\(UUID())")
    let repository = try await CoreDataWorkspaceRepository.open(
      at: directory.appendingPathComponent("workspace.sqlite"))
    let bot = Bot(name: "Routine owner")
    let other = Bot(name: "Group partner")
    let direct = UUID()
    let group = Conversation(kind: .group, title: "Group", memberBotIDs: [bot.id, other.id])
    let provider = ProviderConfig(
      name: "Offline fixture", apiRoot: URL(string: "https://fixture.invalid/v1")!,
      modelID: "fixture", credentialReference: "fixture-routine")
    let routine = Routine(
      ownerBotID: bot.id, name: "Check", prompt: "Give a short update",
      trigger: .interval(minutes: 5), timezoneID: "Asia/Bangkok", enabled: enabled, nextRunAt: due,
      providerBinding: RoutineProviderBinding(provider), scheduleID: UUID())
    try await repository.apply(.createBot(bot, conversationID: direct))
    try await repository.apply(.createBot(other, conversationID: UUID()))
    try await repository.apply(.createGroup(group))
    try await repository.apply(.saveProvider(provider))
    try await repository.apply(.saveRoutine(routine))
    let credentials = SmokeCredentials()
    await credentials.write(Data("offline-routine-fixture".utf8), for: provider.credentialReference)
    let store = PreviewWorkspace(seed: false)
    store.routinePollingEnabled = false
    try await store.connect(repository, credentials: credentials, provider: SmokeChatProvider())
    await store.routineHost?.waitForReconciliation()
    await store.coordinator?.waitForIdle()
    store.selectedID = direct
    addTeardownBlock { @MainActor in
      try await store.prepareForClose()
      try await repository.close()
      try? FileManager.default.removeItem(at: directory)
    }
    return Fixture(
      store: store, repository: repository, routine: routine, provider: provider, directID: direct,
      groupID: group.id)
  }

  func testGroupCreateRequiresExplicitOwnerAndDoesNotBorrowComposerProvider() async throws {
    let f = try await fixture()
    f.store.selectedID = f.groupID
    f.store.beginRoutineEditing()
    let target = try XCTUnwrap(f.store.routineEditTarget)
    XCTAssertNil(target.preferredOwnerID)
    XCTAssertEqual(target.allowedOwnerIDs.count, 2)
    let editor = RoutineEditorController(store: f.store, target: target)
    await editor.load()?.value
    XCTAssertNil(editor.ownerID)
    XCTAssertNil(editor.providerID)
    XCTAssertEqual(f.store.visibleRoutineDefinitions.map(\.id), [f.routine.id])
  }

  func testRunNowWhilePausedWritesOwnersDirectChatAndKeepsDraftAndSchedule() async throws {
    let f = try await fixture()
    f.store.selectedID = f.groupID
    f.store.draft = "Group draft stays"
    f.store.drafts[f.directID] = f.routine.prompt
    f.store.dirtyDrafts.insert(f.directID)
    try await f.store.flushDrafts()
    let run = try f.store.startRoutineRunNow(f.routine, authorizedTransmission: true)
    XCTAssertTrue(f.store.pendingRoutineActions.contains("run-\(f.routine.id)"))
    XCTAssertThrowsError(try f.store.startRoutineRunNow(f.routine, authorizedTransmission: true))
    try await run.value
    await f.store.coordinator?.waitForIdle()
    let snapshot = try await f.repository.snapshot()
    let runs = try await f.repository.routineRuns(routineID: f.routine.id)
    XCTAssertEqual(runs.count, 1)
    XCTAssertEqual(runs.first?.status, .completed)
    XCTAssertEqual(runs.first?.conversationID, f.directID)
    XCTAssertNil(runs.first?.occurrenceID)
    XCTAssertEqual(snapshot.routines.first, f.routine)
    XCTAssertEqual(
      snapshot.drafts.first { $0.conversationID == f.directID }?.text, f.routine.prompt)
    XCTAssertEqual(f.store.draft, "Group draft stays")
    XCTAssertEqual(snapshot.generations.first?.conversationID, f.directID)
  }

  func testRunNowRequiresConsentAndRejectsChangedDefinitionBeforeClaim() async throws {
    let f = try await fixture()
    XCTAssertThrowsError(try f.store.startRoutineRunNow(f.routine, authorizedTransmission: false))
    var changed = f.routine
    changed.prompt = "Different prompt, not authorized"
    try await f.repository.apply(.editRoutine(expected: f.routine, replacement: changed))
    do {
      try await f.store.startRoutineRunNow(f.routine, authorizedTransmission: true).value
      XCTFail("Old confirmation cannot send changed prompt")
    } catch { XCTAssertEqual(error as? WorkspaceError, .editConflict) }
    let runs = try await f.repository.routineRuns(routineID: f.routine.id)
    XCTAssertTrue(runs.isEmpty)
  }

  func testChangedProviderCreatesBlockedHistoryAndCanStillBePaused() async throws {
    let f = try await fixture(enabled: true, due: Date().addingTimeInterval(3600))
    var changed = f.provider
    changed.modelID = "different-fixture"
    try await f.repository.apply(.saveProvider(changed))
    try await f.store.startRoutineRunNow(f.routine, authorizedTransmission: true).value
    let runs = try await f.repository.routineRuns(routineID: f.routine.id)
    XCTAssertEqual(runs.first?.status, .blocked)
    XCTAssertEqual(runs.first?.error, .providerChanged)
    try await f.store.startRoutinePause(f.routine).value
    let snapshot = try await f.repository.snapshot()
    XCTAssertFalse(try XCTUnwrap(snapshot.routines.first).enabled)
    XCTAssertTrue(snapshot.generations.isEmpty)
  }

  func testLaunchCatchesUpOnceAndWakeDoesNotReplay() async throws {
    let f = try await fixture(enabled: true, due: Date().addingTimeInterval(-3600))
    let first = try await f.repository.routineRuns(routineID: f.routine.id)
    XCTAssertEqual(first.filter { $0.status == .completed }.count, 1)
    XCTAssertEqual(first.filter { $0.status == .skipped }.count, 1)
    XCTAssertGreaterThan(try XCTUnwrap(first.first { $0.status == .skipped }?.skippedCount), 5)
    f.store.routineHost?.suspend()
    f.store.routineHost?.wake()
    await f.store.routineHost?.waitForReconciliation()
    await f.store.coordinator?.waitForIdle()
    let after = try await f.repository.routineRuns(routineID: f.routine.id)
    XCTAssertEqual(after, first)
  }

  func testPausedLegacyRoutineDoesNotAutoSelectOrRunAtLaunch() async throws {
    let f = try await fixture()
    var legacy = f.routine
    legacy.providerBinding = nil
    try await f.repository.apply(.editRoutine(expected: f.routine, replacement: legacy))
    f.store.routineHost?.wake()
    await f.store.routineHost?.waitForReconciliation()
    let runs = try await f.repository.routineRuns(routineID: legacy.id)
    XCTAssertTrue(runs.isEmpty)
    try await f.store.startRoutineRunNow(legacy, authorizedTransmission: true).value
    let blocked = try await f.repository.routineRuns(routineID: legacy.id)
    XCTAssertEqual(blocked.first?.error, .missingProvider)
  }

  func testConfirmedDeletePreservesTranscriptAndRejectsNewHistory() async throws {
    let f = try await fixture()
    let oldPlan = try await f.repository.routineDeletionPlan(routineID: f.routine.id)
    try await f.store.startRoutineRunNow(f.routine, authorizedTransmission: true).value
    await f.store.coordinator?.waitForIdle()
    do {
      try await f.store.startRoutineDeletion(oldPlan, stopActive: false).value
      XCTFail("A newly completed run changes the destructive impact")
    } catch { XCTAssertEqual(error as? WorkspaceError, .editConflict) }
    let plan = try await f.repository.routineDeletionPlan(routineID: f.routine.id)
    XCTAssertEqual(plan.runIDs.count, 1)
    f.store.openRoutine(f.routine.id)
    await f.store.routineHistoryTask?.value
    try await f.store.startRoutineDeletion(plan, stopActive: false).value
    XCTAssertNil(f.store.routineDetailTarget)
    XCTAssertNil(f.store.routineError)
    let after = try await f.repository.snapshot()
    let messages = try await f.repository.messages(conversationID: f.directID)
    XCTAssertTrue(after.routines.isEmpty)
    XCTAssertEqual(messages.messages.count, 2)
    XCTAssertEqual(after.providers, [f.provider])
    XCTAssertNotNil(after.generations.first?.routineRunID)
  }

  func testStopAndDeleteCancelsPredispatchClaimAndKeepsOwner() async throws {
    let f = try await fixture()
    let run = RoutineRun(
      routineID: f.routine.id, ownerBotID: f.routine.ownerBotID, conversationID: f.directID,
      name: f.routine.name, prompt: f.routine.prompt, providerBinding: f.routine.providerBinding,
      generationID: UUID())
    try await f.repository.apply(
      .claimRoutineRun(expected: f.routine, run: run, skipped: nil, nextRunAt: nil))
    let plan = try await f.repository.routineDeletionPlan(routineID: f.routine.id)
    XCTAssertEqual(plan.activeRunIDs, [run.id])
    XCTAssertThrowsError(try f.store.startRoutineDeletion(plan, stopActive: false))
    try await f.store.startRoutineDeletion(plan, stopActive: true).value
    let snapshot = try await f.repository.snapshot()
    XCTAssertTrue(snapshot.routines.isEmpty)
    XCTAssertEqual(snapshot.bots.count, 2)
    XCTAssertTrue(snapshot.generations.isEmpty)
  }

  func testClosedWorkspaceRejectsRoutineActionsAndRecoveryCreatesFreshHost() async throws {
    let f = try await fixture()
    let oldHost = f.store.routineHost
    try await f.store.prepareForClose()
    XCTAssertNil(f.store.routineHost)
    XCTAssertThrowsError(try f.store.startRoutineRunNow(f.routine, authorizedTransmission: true))
    f.store.resumeAfterCloseFailure()
    XCTAssertNotNil(f.store.routineHost)
    XCTAssertFalse(f.store.routineHost === oldHost)
    try await f.store.startRoutineRunNow(f.routine, authorizedTransmission: true).value
    await f.store.coordinator?.waitForIdle()
    let runs = try await f.repository.routineRuns(routineID: f.routine.id)
    XCTAssertEqual(runs.count, 1)
  }

  func testNativeSaveChecksConsentOwnerAndClaimsBeforeYielding() async throws {
    let f = try await fixture()
    f.store.beginRoutineEditing(f.routine)
    var enabled = f.routine
    enabled.enabled = true
    enabled.nextRunAt = Date().addingTimeInterval(3600)
    XCTAssertThrowsError(
      try f.store.startRoutineSave(
        expected: f.routine, replacement: enabled, authorizedTransmission: false))
    let save = try f.store.startRoutineSave(
      expected: f.routine, replacement: enabled, authorizedTransmission: true)
    XCTAssertTrue(f.store.isRoutineSaving)
    XCTAssertThrowsError(
      try f.store.startRoutineSave(
        expected: f.routine, replacement: enabled, authorizedTransmission: true))
    try await save.value
    XCTAssertFalse(f.store.isRoutineSaving)
    let snapshot = try await f.repository.snapshot()
    XCTAssertEqual(snapshot.routines.first, enabled)
  }

  func testActiveHistoryRemainsStoppableAfterClockRollbackBehindPageLimit() async throws {
    let f = try await fixture()
    for offset in 0..<101 {
      let run = RoutineRun(
        routineID: f.routine.id, ownerBotID: f.routine.ownerBotID,
        conversationID: f.directID, name: f.routine.name, prompt: f.routine.prompt,
        providerBinding: f.routine.providerBinding,
        createdAt: Date().addingTimeInterval(3600 + Double(offset)), generationID: UUID())
      try await f.repository.apply(
        .claimRoutineRun(expected: f.routine, run: run, skipped: nil, nextRunAt: nil))
      try await f.repository.apply(.cancelRoutineRun(id: run.id, at: run.createdAt))
    }
    let active = RoutineRun(
      routineID: f.routine.id, ownerBotID: f.routine.ownerBotID,
      conversationID: f.directID, name: f.routine.name, prompt: f.routine.prompt,
      providerBinding: f.routine.providerBinding, createdAt: Date(), generationID: UUID())
    try await f.repository.apply(
      .claimRoutineRun(expected: f.routine, run: active, skipped: nil, nextRunAt: nil))
    f.store.openRoutine(f.routine.id)
    await f.store.routineHistoryTask?.value
    XCTAssertEqual(f.store.routineHistory.count, 101)
    XCTAssertEqual(f.store.routineHistory.first?.id, active.id)
    try await f.store.startRoutineStop(active.id).value
    let stopped = try await f.repository.routineRun(id: active.id)
    XCTAssertEqual(stopped.status, .cancelled)
  }

  func testQuitJoinsAcceptedRoutineSaveBeforeClosingCoordinator() async throws {
    let f = try await fixture()
    let gated = RoutineSaveGateRepository(base: f.repository)
    try await f.store.connect(gated, provider: SmokeChatProvider())
    f.store.selectedID = f.directID
    f.store.beginRoutineEditing(f.routine)
    var changed = f.routine
    changed.name = "Accepted edit"
    let save = try f.store.startRoutineSave(
      expected: f.routine, replacement: changed, authorizedTransmission: false)
    await gated.waitUntilPaused()
    var didClose = false
    let close = Task {
      try await f.store.prepareForClose()
      didClose = true
    }
    while !f.store.routineShutdownStarted { await Task.yield() }
    await Task.yield()
    XCTAssertFalse(didClose)
    XCTAssertTrue(f.store.isRoutineSaving)
    await gated.release()
    try await save.value
    try await close.value
    let snapshot = try await f.repository.snapshot()
    XCTAssertEqual(snapshot.routines.first?.name, "Accepted edit")
    XCTAssertTrue(f.store.coordinatorStopped)
    XCTAssertTrue(f.store.routineTasks.isEmpty)
  }

  func testNativeStopCancelsStreamingRoutineAndKeepsPartialText() async throws {
    let f = try await fixture()
    let credentials = SmokeCredentials()
    await credentials.write(
      Data("offline-routine-fixture".utf8), for: f.provider.credentialReference)
    let provider = HeldRoutineProvider()
    try await f.store.connect(f.repository, credentials: credentials, provider: provider)
    var starts = provider.starts.makeAsyncIterator()
    try await f.store.startRoutineRunNow(f.routine, authorizedTransmission: true).value
    _ = await starts.next()
    // The started callback precedes any delta processing. Wait for persisted streaming text.
    var page = try await f.repository.messages(conversationID: f.directID)
    for _ in 0..<100 where page.messages.count < 2 {
      try await Task.sleep(for: .milliseconds(5))
      page = try await f.repository.messages(conversationID: f.directID)
    }
    let runs = try await f.repository.routineRuns(routineID: f.routine.id)
    let run = try XCTUnwrap(runs.first)
    try await f.store.startRoutineStop(run.id).value
    await f.store.coordinator?.waitForIdle()
    let stopped = try await f.repository.routineRun(id: run.id)
    let after = try await f.repository.messages(conversationID: f.directID)
    XCTAssertEqual(stopped.status, .cancelled)
    XCTAssertEqual(after.messages.last?.text, "Partial offline routine reply")
  }

  func testHostSuspensionSkipsTicksAndShutdownJoinsAcceptedReconcile() async throws {
    let f = try await fixture()
    await f.store.shutdownRoutines()
    let coordinator = try XCTUnwrap(f.store.coordinator)
    let scheduler = RoutineScheduler(repository: f.repository, coordinator: coordinator)
    var calls = 0
    var resume: CheckedContinuation<Void, Never>?
    let host = RoutineHost(scheduler: scheduler, polling: false) {
      calls += 1
      await withCheckedContinuation { resume = $0 }
    }
    host.wake()
    while resume == nil { await Task.yield() }
    host.suspend()
    host.requestReconciliation()
    var didClose = false
    let close = Task {
      await host.shutdown()
      didClose = true
    }
    await Task.yield()
    XCTAssertFalse(didClose)
    XCTAssertEqual(calls, 1)
    resume?.resume()
    await close.value
    host.wake()
    await Task.yield()
    XCTAssertEqual(calls, 1)
  }
}

private actor RoutineSaveGateRepository: WorkspaceRepository {
  let base: CoreDataWorkspaceRepository
  private var paused = false
  private var observers: [CheckedContinuation<Void, Never>] = []
  private var releaseContinuation: CheckedContinuation<Void, Never>?
  init(base: CoreDataWorkspaceRepository) { self.base = base }
  func snapshot() async throws -> WorkspaceSnapshot { try await base.snapshot() }
  func routineRuns(routineID: UUID?, limit: Int) async throws -> [RoutineRun] {
    try await base.routineRuns(routineID: routineID, limit: limit)
  }
  func routineRun(id: UUID) async throws -> RoutineRun { try await base.routineRun(id: id) }
  func routineDeletionPlan(routineID: UUID) async throws -> RoutineDeletionPlan {
    try await base.routineDeletionPlan(routineID: routineID)
  }
  func apply(_ mutation: WorkspaceMutation, expectedRevision: Int64?) async throws -> Int64 {
    if case .editRoutine = mutation {
      paused = true
      for observer in observers { observer.resume() }
      observers.removeAll()
      await withCheckedContinuation { releaseContinuation = $0 }
    }
    return try await base.apply(mutation, expectedRevision: expectedRevision)
  }
  func waitUntilPaused() async {
    if paused { return }
    await withCheckedContinuation { observers.append($0) }
  }
  func release() {
    releaseContinuation?.resume()
    releaseContinuation = nil
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
}

private final class HeldRoutineProvider: ChatProvider, @unchecked Sendable {
  let starts: AsyncStream<Void>
  private let start: AsyncStream<Void>.Continuation
  init() {
    let stream = AsyncStream<Void>.makeStream()
    starts = stream.stream
    start = stream.continuation
  }
  func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
    AsyncThrowingStream { continuation in
      continuation.yield(.text("Partial offline routine reply"))
      start.yield(())
    }
  }
}
