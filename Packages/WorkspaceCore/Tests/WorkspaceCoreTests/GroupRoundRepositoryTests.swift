import XCTest

@testable import WorkspaceCore

@MainActor final class GroupRoundRepositoryTests: XCTestCase {
  private struct Fixture {
    let repository: CoreDataWorkspaceRepository
    let directory: URL
    let storeURL: URL
    let bots: [Bot]
    let conversationID: UUID
  }

  private func fixture(botCount: Int = 3) async throws -> Fixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "GroupRoundRepositoryTests-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let storeURL = directory.appendingPathComponent("workspace.sqlite")
    let repository = try await CoreDataWorkspaceRepository.open(at: storeURL)
    addTeardownBlock {
      try? await repository.close()
      try? FileManager.default.removeItem(at: directory)
    }
    var bots = [Bot]()
    for index in 0..<botCount {
      let bot = Bot(name: "Member \(index + 1)")
      try await repository.apply(.createBot(bot, conversationID: UUID()))
      bots.append(bot)
    }
    let conversationID = UUID()
    try await repository.apply(
      .createGroup(
        Conversation(
          id: conversationID, kind: .group, title: "Round", memberBotIDs: bots.map(\.id))))
    return Fixture(
      repository: repository, directory: directory, storeURL: storeURL, bots: bots,
      conversationID: conversationID)
  }

  private func command(
    _ fixture: Fixture, text: String = "Ask everyone", attachmentIDs: [UUID] = []
  ) -> SendRoundCommand {
    SendRoundCommand(
      conversationID: fixture.conversationID,
      targets: fixture.bots.map { .init(targetBotID: $0.id) }, text: text,
      attachmentIDs: attachmentIDs)
  }

  private func assertWorkspaceError(
    _ expected: WorkspaceError, operation: () async throws -> Void,
    file: StaticString = #filePath, line: UInt = #line
  ) async {
    do {
      try await operation()
      XCTFail("Expected \(expected)", file: file, line: line)
    } catch {
      XCTAssertEqual(error as? WorkspaceError, expected, file: file, line: line)
    }
  }

  func testRoundAtomicallyPersistsOneUserMessageOrderedGenerationsAttachmentAndDraftClear()
    async throws
  {
    let fixture = try await fixture()
    let attachment = try AttachmentContent(
      conversationID: fixture.conversationID, originalName: "context.txt",
      data: Data("shared context".utf8))
    let draft = Draft(
      conversationID: fixture.conversationID, text: "  Ask everyone  ",
      attachmentIDs: [attachment.attachment.id])
    try await fixture.repository.apply(
      .saveDraftWithAttachments(draft, attachments: [attachment]))
    let round = command(
      fixture, text: "  Ask everyone  ", attachmentIDs: [attachment.attachment.id])

    try await fixture.repository.apply(.beginGenerationRound(round))

    let page = try await fixture.repository.messages(conversationID: fixture.conversationID)
    let snapshot = try await fixture.repository.snapshot()
    let generations = snapshot.generations.filter { $0.userMessageID == round.userMessageID }
      .sorted { ($0.roundIndex ?? .max) < ($1.roundIndex ?? .max) }
    XCTAssertEqual(page.messages.count, 1)
    XCTAssertEqual(page.messages[0].id, round.userMessageID)
    XCTAssertEqual(page.messages[0].text, "Ask everyone")
    XCTAssertEqual(page.messages[0].attachmentIDs, [attachment.attachment.id])
    XCTAssertNil(page.messages[0].generationID)
    XCTAssertEqual(generations.map(\.id), round.targets.map(\.generationID))
    XCTAssertEqual(generations.map(\.attemptID), round.targets.map(\.attemptID))
    XCTAssertEqual(generations.map(\.targetBotID), fixture.bots.map(\.id))
    XCTAssertEqual(generations.map(\.roundIndex), [0, 1, 2])
    XCTAssertEqual(generations.map(\.targetSpeakerNameSnapshot), fixture.bots.map(\.name))
    XCTAssertTrue(snapshot.drafts.allSatisfy { $0.conversationID != fixture.conversationID })
    XCTAssertEqual(
      snapshot.conversations.first { $0.id == fixture.conversationID }?.nextSequence, 2)
  }

  func testSingleTargetRoundRetainsUserGenerationLink() async throws {
    let fixture = try await fixture()
    let target = SendRoundCommand.Target(targetBotID: fixture.bots[1].id)
    let round = SendRoundCommand(
      conversationID: fixture.conversationID, targets: [target], text: "One")
    try await fixture.repository.apply(.beginGenerationRound(round))
    let message = try await fixture.repository.message(id: round.userMessageID)
    XCTAssertEqual(message.generationID, target.generationID)
  }

  func testInvalidTargetDuplicateIdentityAndTooManyTargetsRollBackEverything() async throws {
    let fixture = try await fixture()
    try await fixture.repository.apply(
      .saveDraft(Draft(conversationID: fixture.conversationID, text: "Keep me")))
    let before = try await fixture.repository.snapshot()
    let foreign = Bot(name: "Foreign")
    try await fixture.repository.apply(.createBot(foreign, conversationID: UUID()))
    let foreignRound = SendRoundCommand(
      conversationID: fixture.conversationID,
      targets: [.init(targetBotID: fixture.bots[0].id), .init(targetBotID: foreign.id)],
      text: "Question")
    await assertWorkspaceError(.invalidMembers) {
      try await fixture.repository.apply(.beginGenerationRound(foreignRound))
    }

    let sharedGenerationID = UUID()
    let duplicateRound = SendRoundCommand(
      conversationID: fixture.conversationID,
      targets: [
        .init(targetBotID: fixture.bots[0].id, generationID: sharedGenerationID),
        .init(targetBotID: fixture.bots[1].id, generationID: sharedGenerationID),
      ], text: "Question")
    await assertWorkspaceError(.identityConflict) {
      try await fixture.repository.apply(.beginGenerationRound(duplicateRound))
    }

    let tooMany = SendRoundCommand(
      conversationID: fixture.conversationID,
      targets: (0..<7).map { _ in .init(targetBotID: fixture.bots[0].id) }, text: "Question")
    await assertWorkspaceError(.invalidMembers) {
      try await fixture.repository.apply(.beginGenerationRound(tooMany))
    }
    let after = try await fixture.repository.snapshot()
    XCTAssertEqual(after.generations, before.generations)
    XCTAssertEqual(
      after.drafts.first { $0.conversationID == fixture.conversationID },
      before.drafts.first { $0.conversationID == fixture.conversationID })
    let messages = try await fixture.repository.messages(conversationID: fixture.conversationID)
    XCTAssertTrue(messages.messages.isEmpty)
  }

  func testExistingIdentityAndSaveFailureAreAtomic() async throws {
    let fixture = try await fixture()
    let collision = SendRoundCommand(
      conversationID: fixture.conversationID,
      targets: [
        .init(targetBotID: fixture.bots[0].id, generationID: fixture.bots[1].id),
        .init(targetBotID: fixture.bots[1].id),
      ], text: "Collision")
    await assertWorkspaceError(.identityConflict) {
      try await fixture.repository.apply(.beginGenerationRound(collision))
    }
    try await fixture.repository.apply(
      .saveDraft(Draft(conversationID: fixture.conversationID, text: "Persist")))
    await fixture.repository.injectNextSaveFailure()
    await assertWorkspaceError(.storeUnavailable) {
      try await fixture.repository.apply(
        .beginGenerationRound(command(fixture, text: "Persist")))
    }
    let snapshot = try await fixture.repository.snapshot()
    XCTAssertTrue(snapshot.generations.isEmpty)
    XCTAssertEqual(
      snapshot.drafts.first { $0.conversationID == fixture.conversationID }?.text, "Persist")
    let messages = try await fixture.repository.messages(conversationID: fixture.conversationID)
    XCTAssertTrue(messages.messages.isEmpty)
  }

  func testRoutineReservationCannotBeStolenAndRoundCancellationSkipsRoutineGeneration()
    async throws
  {
    let fixture = try await fixture()
    let snapshot = try await fixture.repository.snapshot()
    let directID = try XCTUnwrap(
      snapshot.conversations.first {
        $0.kind == .direct && $0.memberBotIDs == [fixture.bots[0].id]
      }?.id)
    let provider = ProviderConfig(
      name: "Routine fixture", apiRoot: URL(string: "https://fixture.invalid/v1")!,
      modelID: "fixture", credentialReference: "fixture")
    let routine = Routine(
      ownerBotID: fixture.bots[0].id, name: "Reserved", prompt: "Run once",
      trigger: .interval(minutes: 5), timezoneID: "UTC",
      providerBinding: RoutineProviderBinding(provider), scheduleID: UUID())
    try await fixture.repository.apply(.saveProvider(provider))
    try await fixture.repository.apply(.saveRoutine(routine))
    let reservedGenerationID = UUID()
    let run = RoutineRun(
      routineID: routine.id, ownerBotID: fixture.bots[0].id, conversationID: directID,
      name: routine.name, prompt: routine.prompt, providerBinding: routine.providerBinding,
      createdAt: Date(), generationID: reservedGenerationID)
    try await fixture.repository.apply(
      .claimRoutineRun(expected: routine, run: run, skipped: nil, nextRunAt: nil))

    let stealingRound = SendRoundCommand(
      conversationID: fixture.conversationID,
      targets: [
        .init(targetBotID: fixture.bots[0].id, generationID: reservedGenerationID),
        .init(targetBotID: fixture.bots[1].id),
      ], text: "Do not steal")
    await assertWorkspaceError(.identityConflict) {
      try await fixture.repository.apply(.beginGenerationRound(stealingRound))
    }
    let stealingUserIdentity = SendRoundCommand(
      conversationID: fixture.conversationID, userMessageID: reservedGenerationID,
      targets: [
        .init(targetBotID: fixture.bots[0].id),
        .init(targetBotID: fixture.bots[1].id),
      ], text: "Do not occupy a reservation")
    await assertWorkspaceError(.identityConflict) {
      try await fixture.repository.apply(.beginGenerationRound(stealingUserIdentity))
    }

    let routineCommand = SendCommand(
      conversationID: directID, generationID: reservedGenerationID,
      targetBotID: fixture.bots[0].id, text: routine.prompt)
    try await fixture.repository.apply(
      .beginRoutineGeneration(runID: run.id, command: routineCommand))
    try await fixture.repository.apply(
      .cancelGenerationRound(userMessageID: routineCommand.userMessageID))
    let after = try await fixture.repository.snapshot()
    let generation = try XCTUnwrap(after.generations.first { $0.id == reservedGenerationID })
    XCTAssertEqual(generation.state, .queued)
    XCTAssertEqual(generation.routineRunID, run.id)
  }

  func testCapturedSpeakerNameSurvivesRenameAndReopen() async throws {
    let fixture = try await fixture()
    let round = command(fixture)
    try await fixture.repository.apply(.beginGenerationRound(round))
    var renamed = fixture.bots[1]
    renamed.name = "Renamed after commit"
    try await fixture.repository.apply(.updateBot(renamed))
    let target = round.targets[1]
    try await fixture.repository.apply(
      .applyGenerationEvent(
        GenerationEvent(
          generationID: target.generationID, attemptID: target.attemptID, sequence: 1,
          kind: .started)))
    try await fixture.repository.apply(
      .applyGenerationEvent(
        GenerationEvent(
          generationID: target.generationID, attemptID: target.attemptID, sequence: 2,
          kind: .delta("Original attribution"))))
    try await fixture.repository.close()

    let reopened = try await CoreDataWorkspaceRepository.open(at: fixture.storeURL)
    addTeardownBlock { try? await reopened.close() }
    let snapshot = try await reopened.snapshot()
    let generation = try XCTUnwrap(snapshot.generations.first { $0.id == target.generationID })
    let reopenedMessages = try await reopened.messages(conversationID: fixture.conversationID)
    let assistant = try XCTUnwrap(reopenedMessages.messages.last)
    XCTAssertEqual(generation.roundIndex, 1)
    XCTAssertEqual(generation.targetSpeakerNameSnapshot, "Member 2")
    XCTAssertEqual(assistant.speakerNameSnapshot, "Member 2")
  }

  func testRoundCancellationPreservesCompletedAndRejectsLateEvents() async throws {
    let fixture = try await fixture()
    let round = command(fixture)
    try await fixture.repository.apply(.beginGenerationRound(round))
    let completed = round.targets[0]
    try await fixture.repository.apply(
      .applyGenerationEvent(
        GenerationEvent(
          generationID: completed.generationID, attemptID: completed.attemptID, sequence: 1,
          kind: .started)))
    try await fixture.repository.apply(
      .applyGenerationEvent(
        GenerationEvent(
          generationID: completed.generationID, attemptID: completed.attemptID, sequence: 2,
          kind: .completed)))
    try await fixture.repository.apply(.cancelGenerationRound(userMessageID: round.userMessageID))
    let cancelled = round.targets[1]
    try await fixture.repository.apply(
      .applyGenerationEvent(
        GenerationEvent(
          generationID: cancelled.generationID, attemptID: cancelled.attemptID, sequence: 1,
          kind: .started)))

    let generations = try await fixture.repository.snapshot().generations.filter {
      $0.userMessageID == round.userMessageID
    }
    XCTAssertEqual(generations.first { $0.id == completed.generationID }?.state, .completed)
    XCTAssertEqual(generations.first { $0.id == cancelled.generationID }?.state, .cancelled)
    XCTAssertEqual(generations.first { $0.id == round.targets[2].generationID }?.state, .cancelled)
  }

  func testLegacyGenerationJSONDecodesNewFieldsAsNil() throws {
    let generation = Generation(
      id: UUID(), conversationID: UUID(), userMessageID: UUID(), attemptID: UUID(),
      targetBotID: UUID(), state: .queued, lastEventSequence: 0, error: nil)
    let encoded = try JSONEncoder().encode(generation)
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "roundIndex")
    object.removeValue(forKey: "targetSpeakerNameSnapshot")
    let legacy = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(Generation.self, from: legacy)
    XCTAssertNil(decoded.roundIndex)
    XCTAssertNil(decoded.targetSpeakerNameSnapshot)
  }
}
