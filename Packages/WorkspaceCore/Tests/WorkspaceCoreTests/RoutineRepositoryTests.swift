import XCTest

@testable import WorkspaceCore

@MainActor final class RoutineRepositoryTests: XCTestCase {
  private struct Fixture {
    let repository: CoreDataWorkspaceRepository
    let bot: Bot
    let conversationID: UUID
    let provider: ProviderConfig
    let routine: Routine
  }

  private func fixture(enabled: Bool = false, nextRunAt: Date? = nil) async throws -> Fixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "RoutineRepositoryTests-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let repository = try await CoreDataWorkspaceRepository.open(
      at: directory.appendingPathComponent("workspace.sqlite"))
    addTeardownBlock {
      try await repository.close()
      try? FileManager.default.removeItem(at: directory)
    }
    let bot = Bot(name: "Routine bot")
    let conversationID = UUID()
    let provider = ProviderConfig(
      name: "Fixture", apiRoot: URL(string: "https://fixture.invalid/v1")!,
      modelID: "fixture", credentialReference: "fixture")
    let routine = Routine(
      ownerBotID: bot.id, name: "Check", prompt: "Report", trigger: .interval(minutes: 5),
      timezoneID: "UTC", enabled: enabled, nextRunAt: nextRunAt,
      providerBinding: RoutineProviderBinding(provider), scheduleID: UUID())
    try await repository.apply(.createBot(bot, conversationID: conversationID))
    try await repository.apply(.saveProvider(provider))
    try await repository.apply(.saveRoutine(routine))
    return Fixture(
      repository: repository, bot: bot, conversationID: conversationID, provider: provider,
      routine: routine)
  }

  private func run(_ fixture: Fixture, at: Date = Date()) -> RoutineRun {
    RoutineRun(
      routineID: fixture.routine.id, ownerBotID: fixture.bot.id,
      conversationID: fixture.conversationID, name: fixture.routine.name,
      prompt: fixture.routine.prompt, providerBinding: fixture.routine.providerBinding,
      createdAt: at, generationID: UUID())
  }

  func testCreateRoutineCannotOverwriteExistingDefinition() async throws {
    let f = try await fixture()
    var replacement = f.routine
    replacement.prompt = "Must not replace"
    do {
      try await f.repository.apply(.createRoutine(replacement))
      XCTFail("Create must reject an existing identity")
    } catch { XCTAssertEqual(error as? WorkspaceError, .identityConflict) }
    let snapshot = try await f.repository.snapshot()
    XCTAssertEqual(snapshot.routines, [f.routine])
  }

  func testConfirmedDeleteRechecksHistoryAfterPauseEvenWhenNewRunIsTerminal() async throws {
    let f = try await fixture()
    let plan = try await f.repository.routineDeletionPlan(routineID: f.routine.id)
    try await f.repository.apply(
      .pauseRoutineForDeletion(expected: f.routine, expectedRunIDs: plan.runIDs))
    let claimed = run(f)
    try await f.repository.apply(
      .claimRoutineRun(expected: f.routine, run: claimed, skipped: nil, nextRunAt: nil))
    try await f.repository.apply(.cancelRoutineRun(id: claimed.id, at: claimed.createdAt))
    do {
      try await f.repository.apply(.deleteRoutine(expected: f.routine, expectedRunIDs: plan.runIDs))
      XCTFail("New history needs a new confirmation, even if already terminal")
    } catch { XCTAssertEqual(error as? WorkspaceError, .editConflict) }
    let fresh = try await f.repository.routineDeletionPlan(routineID: f.routine.id)
    XCTAssertEqual(fresh.runIDs, [claimed.id])
    XCTAssertTrue(fresh.activeRunIDs.isEmpty)
    try await f.repository.apply(.deleteRoutine(expected: f.routine, expectedRunIDs: fresh.runIDs))
    let snapshot = try await f.repository.snapshot()
    XCTAssertTrue(snapshot.routines.isEmpty)
  }

  func testClaimReservesGenerationAndBeginPreservesEqualDraft() async throws {
    let fixture = try await fixture()
    let run = run(fixture)
    try await fixture.repository.apply(
      .saveDraft(Draft(conversationID: fixture.conversationID, text: run.prompt)))
    try await fixture.repository.apply(
      .claimRoutineRun(expected: fixture.routine, run: run, skipped: nil, nextRunAt: nil))

    do {
      try await fixture.repository.apply(
        .beginGeneration(
          SendCommand(
            conversationID: fixture.conversationID, generationID: try XCTUnwrap(run.generationID),
            targetBotID: fixture.bot.id, text: "ordinary")))
      XCTFail("An ordinary send must not steal a reserved routine generation identity")
    } catch { XCTAssertEqual(error as? WorkspaceError, .identityConflict) }

    let command = SendCommand(
      conversationID: fixture.conversationID, generationID: try XCTUnwrap(run.generationID),
      targetBotID: fixture.bot.id, text: run.prompt)
    try await fixture.repository.apply(.beginRoutineGeneration(runID: run.id, command: command))
    let snapshot = try await fixture.repository.snapshot()
    XCTAssertEqual(snapshot.drafts.first?.text, run.prompt)
    XCTAssertEqual(snapshot.generations.first?.id, run.generationID)
  }

  func testAtomicCancelTerminalsRunAndLinkedGeneration() async throws {
    let fixture = try await fixture()
    let run = run(fixture)
    try await fixture.repository.apply(
      .claimRoutineRun(expected: fixture.routine, run: run, skipped: nil, nextRunAt: nil))
    let command = SendCommand(
      conversationID: fixture.conversationID, generationID: try XCTUnwrap(run.generationID),
      targetBotID: fixture.bot.id, text: run.prompt)
    try await fixture.repository.apply(.beginRoutineGeneration(runID: run.id, command: command))
    do {
      try await fixture.repository.apply(
        .finishRoutineRun(
          id: run.id, status: .blocked, at: run.createdAt, error: .storageUnavailable))
      XCTFail("A run with a linked generation must finish through generation lifecycle or cancel")
    } catch { XCTAssertEqual(error as? WorkspaceError, .invalidRoutine) }
    let cancelledAt = run.createdAt.addingTimeInterval(1)
    try await fixture.repository.apply(.cancelRoutineRun(id: run.id, at: cancelledAt))
    let cancelled = try await fixture.repository.routineRun(id: run.id)
    let snapshot = try await fixture.repository.snapshot()
    XCTAssertEqual(cancelled.status, .cancelled)
    XCTAssertEqual(snapshot.generations.first?.state, .cancelled)
  }

  func testScheduledClaimAtomicallyRecordsSkippedWindowAndAdvancesCalendar() async throws {
    let now = Date(timeIntervalSince1970: 1_789_000_000)
    let first = now.addingTimeInterval(-600)
    let fixture = try await fixture(enabled: true, nextRunAt: first)
    let window = try XCTUnwrap(
      RoutineSchedule.due(
        from: first, through: now, trigger: fixture.routine.trigger,
        timezoneID: fixture.routine.timezoneID))
    let occurrence = try RoutineSchedule.occurrenceID(
      scheduleID: try XCTUnwrap(fixture.routine.scheduleID), at: window.latest,
      trigger: fixture.routine.trigger, timezoneID: fixture.routine.timezoneID)
    let execution = RoutineRun(
      routineID: fixture.routine.id, ownerBotID: fixture.bot.id,
      conversationID: fixture.conversationID, name: fixture.routine.name,
      prompt: fixture.routine.prompt, providerBinding: fixture.routine.providerBinding,
      occurrenceID: occurrence, scheduledAt: window.latest, createdAt: now, generationID: UUID())
    let skipped = RoutineRun(
      routineID: fixture.routine.id, ownerBotID: fixture.bot.id,
      conversationID: fixture.conversationID, name: fixture.routine.name,
      prompt: fixture.routine.prompt, providerBinding: fixture.routine.providerBinding,
      createdAt: now, generationID: nil, status: .skipped, endedAt: now,
      error: .supersededOccurrence,
      skippedCount: window.skippedCount, firstSkippedAt: window.firstSkippedAt,
      lastSkippedAt: window.lastSkippedAt)
    try await fixture.repository.apply(
      .claimRoutineRun(
        expected: fixture.routine, run: execution, skipped: skipped, nextRunAt: window.next))
    let runs = try await fixture.repository.routineRuns(routineID: fixture.routine.id, limit: 100)
    let snapshot = try await fixture.repository.snapshot()
    XCTAssertEqual(Set(runs.map(\.id)), [execution.id, skipped.id])
    XCTAssertEqual(snapshot.routines.first?.nextRunAt, window.next)
  }

  func testRunQueryIsBoundedAndRoutineDeletePreservesTranscript() async throws {
    let fixture = try await fixture()
    for offset in 0..<3 {
      var item = run(fixture, at: Date(timeIntervalSince1970: TimeInterval(offset)))
      item.status = .blocked
      item.endedAt = item.createdAt
      item.error = .missingProvider
      try await fixture.repository.apply(
        .claimRoutineRun(
          expected: fixture.routine,
          run: run(fixture, at: item.createdAt), skipped: nil, nextRunAt: nil))
      let claimed = try await fixture.repository.routineRuns(
        routineID: fixture.routine.id, limit: 1)
      try await fixture.repository.apply(
        .finishRoutineRun(
          id: try XCTUnwrap(claimed.first?.id), status: .blocked, at: item.createdAt,
          error: .missingProvider))
    }
    let bounded = try await fixture.repository.routineRuns(routineID: fixture.routine.id, limit: 2)
    XCTAssertEqual(bounded.count, 2)
    let snapshot = try await fixture.repository.snapshot()
    try await fixture.repository.apply(
      .deleteRoutine(expected: try XCTUnwrap(snapshot.routines.first)))
    let afterRuns = try await fixture.repository.routineRuns(
      routineID: fixture.routine.id, limit: 100)
    let afterSnapshot = try await fixture.repository.snapshot()
    XCTAssertTrue(afterRuns.isEmpty)
    XCTAssertEqual(afterSnapshot.conversations.count, 1)
  }

  func testCodexProviderBindingUsesCredentialFreeValidation() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "RoutineCodexBinding-\(UUID())")
    let repository = try await CoreDataWorkspaceRepository.open(
      at: directory.appendingPathComponent("workspace.sqlite"))
    addTeardownBlock {
      try await repository.close()
      try? FileManager.default.removeItem(at: directory)
    }
    let provider = ProviderConfig(
      name: "Codex", apiRoot: CodexResponsesProvider.apiRoot, modelID: "codex-model",
      credentialReference: CodexSessionCredential.makeReference(), kind: .codexResponses)
    let bot = Bot(name: "Codex routine", providerConfigID: provider.id)
    try await repository.apply(.saveProvider(provider))
    try await repository.apply(.createBot(bot, conversationID: UUID()))
    let routine = Routine(
      ownerBotID: bot.id, name: "Codex check", prompt: "Report",
      trigger: .interval(minutes: 5), timezoneID: "UTC",
      providerBinding: RoutineProviderBinding(provider))
    try await repository.apply(.saveRoutine(routine))
    let snapshot = try await repository.snapshot()
    XCTAssertEqual(snapshot.routines.first, routine)
  }

  func testBotDeletionPlanCountsRoutineRunsAndRejectsANewlyClaimedRun() async throws {
    let fixture = try await fixture()
    let first = run(fixture)
    try await fixture.repository.apply(
      .claimRoutineRun(expected: fixture.routine, run: first, skipped: nil, nextRunAt: nil))
    let activePlan = try await fixture.repository.botDeletionPlan(botID: fixture.bot.id)
    XCTAssertEqual(activePlan.routineRunIDs, [first.id])
    XCTAssertEqual(activePlan.activeRoutineRunIDs, [first.id])
    do {
      try await fixture.repository.apply(.deleteBot(expected: activePlan))
      XCTFail("Repository deletion must refuse active routine work")
    } catch { XCTAssertEqual(error as? BotDeletionError, .activeWork) }

    try await fixture.repository.apply(
      .finishRoutineRun(
        id: first.id, status: .blocked, at: first.createdAt, error: .missingProvider))
    let confirmed = try await fixture.repository.botDeletionPlan(botID: fixture.bot.id)
    let second = run(fixture, at: first.createdAt.addingTimeInterval(1))
    try await fixture.repository.apply(
      .claimRoutineRun(expected: fixture.routine, run: second, skipped: nil, nextRunAt: nil))
    do {
      try await fixture.repository.apply(.deleteBot(expected: confirmed))
      XCTFail("A newly claimed run changes destructive impact and requires reconfirmation")
    } catch { XCTAssertEqual(error as? BotDeletionError, .confirmationChanged) }
    let preserved = try await fixture.repository.snapshot()
    XCTAssertEqual(preserved.bots, [fixture.bot])
  }
}
