import XCTest

@testable import WorkspaceCore

@MainActor final class BotDeletionTests: XCTestCase {
  private func open(_ existingURL: URL? = nil) async throws -> (CoreDataWorkspaceRepository, URL) {
    let url: URL
    if let existingURL {
      url = existingURL
    } else {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "BotDeletionTests-\(UUID())")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
      url = directory.appendingPathComponent("workspace.sqlite")
    }
    let repository = try await CoreDataWorkspaceRepository.open(at: url)
    addTeardownBlock { try await repository.close() }
    return (repository, url)
  }

  private func createBot(
    _ repository: CoreDataWorkspaceRepository, name: String,
    providerConfigID: UUID? = nil
  ) async throws -> (Bot, UUID) {
    let bot = Bot(name: name, providerConfigID: providerConfigID)
    let conversationID = UUID()
    try await repository.apply(.createBot(bot, conversationID: conversationID))
    return (bot, conversationID)
  }

  @discardableResult private func beginTerminalGeneration(
    _ repository: CoreDataWorkspaceRepository, conversationID: UUID, botID: UUID,
    text: String = "Question"
  ) async throws -> SendCommand {
    let command = SendCommand(conversationID: conversationID, targetBotID: botID, text: text)
    try await repository.apply(.beginGeneration(command))
    try await repository.apply(
      .applyGenerationEvent(
        GenerationEvent(
          generationID: command.generationID, attemptID: command.attemptID, sequence: 1,
          kind: .failed(.offline))))
    return command
  }

  private func assertDeletionError(
    _ expected: BotDeletionError, _ operation: () async throws -> Void,
    file: StaticString = #filePath, line: UInt = #line
  ) async {
    do {
      try await operation()
      XCTFail("Expected \(expected)", file: file, line: line)
    } catch {
      XCTAssertEqual(error as? BotDeletionError, expected, file: file, line: line)
    }
  }

  func testPlanCountsAllDirectHistoryAndDeletionRetainsGroupHistoryAndSharedProvider()
    async throws
  {
    let (repository, url) = try await open()
    let provider = ProviderConfig(
      name: "Shared", apiRoot: URL(string: "https://example.invalid/v1")!, modelID: "model",
      credentialReference: "reference")
    try await repository.apply(.saveProvider(provider))
    let (deleted, directID) = try await createBot(
      repository, name: "Delete Me", providerConfigID: provider.id)
    let (remaining, _) = try await createBot(
      repository, name: "Remaining", providerConfigID: provider.id)
    let (repair, _) = try await createBot(repository, name: "Repair")
    let group = Conversation(
      kind: .group, title: "Keep History", memberBotIDs: [deleted.id, remaining.id])
    try await repository.apply(.createGroup(group))
    let groupGeneration = try await beginTerminalGeneration(
      repository, conversationID: group.id, botID: deleted.id, text: "Group history")
    for index in 0..<101 {
      try await beginTerminalGeneration(
        repository, conversationID: directID, botID: deleted.id, text: "Direct \(index)")
    }
    try await repository.apply(.saveDraft(Draft(conversationID: directID, text: "Unsent")))
    let routine = Routine(
      ownerBotID: deleted.id, name: "Owned", prompt: "Run",
      trigger: .interval(minutes: 60), timezoneID: "UTC")
    try await repository.apply(.saveRoutine(routine))

    let plan = try await repository.botDeletionPlan(botID: deleted.id)
    XCTAssertEqual(plan.name, "Delete Me")
    XCTAssertEqual(plan.directConversationIDs, [directID])
    XCTAssertEqual(plan.messageCount, 101)
    XCTAssertEqual(plan.draftConversationIDs, [directID])
    XCTAssertEqual(plan.generationCount, 101)
    XCTAssertEqual(plan.routineIDs, [routine.id])
    XCTAssertEqual(
      plan.affectedGroups,
      [.init(id: group.id, title: group.title, remainingMemberBotIDs: [remaining.id])])
    XCTAssertTrue(plan.activeGenerationIDs.isEmpty)
    XCTAssertEqual(Set(plan.cancellationConversationIDs), [directID, group.id])

    try await repository.apply(.deleteBot(expected: plan))
    let snapshot = try await repository.snapshot()
    XCTAssertFalse(snapshot.bots.contains { $0.id == deleted.id })
    XCTAssertEqual(snapshot.providers, [provider])
    XCTAssertFalse(snapshot.conversations.contains { $0.id == directID })
    XCTAssertEqual(snapshot.conversations.first { $0.id == group.id }?.memberBotIDs, [remaining.id])
    XCTAssertFalse(snapshot.routines.contains { $0.id == routine.id })
    XCTAssertEqual(snapshot.generations.map(\.id), [groupGeneration.generationID])
    let groupMessages = try await repository.messages(conversationID: group.id, limit: 500)
    XCTAssertEqual(groupMessages.messages.map(\.id), [groupGeneration.userMessageID])
    let exported = try await repository.exportSnapshot()
    XCTAssertFalse(exported.messages.contains { $0.conversationID == directID })
    XCTAssertFalse(exported.drafts.contains { $0.conversationID == directID })
    XCTAssertFalse(exported.generations.contains { $0.conversationID == directID })

    do {
      try await repository.apply(
        .beginGeneration(
          SendCommand(conversationID: group.id, targetBotID: remaining.id, text: "Blocked")))
      XCTFail("Expected degraded group to reject sends")
    } catch { XCTAssertEqual(error as? WorkspaceError, .invalidMembers) }
    do {
      try await repository.apply(
        .retryGeneration(id: groupGeneration.generationID, attemptID: UUID()))
      XCTFail("Expected degraded group to reject retry")
    } catch { XCTAssertEqual(error as? WorkspaceError, .invalidMembers) }

    try await repository.close()
    let (reopened, _) = try await open(url)
    let reopenedSnapshot = try await reopened.snapshot()
    XCTAssertEqual(
      reopenedSnapshot.conversations.first { $0.id == group.id }?.memberBotIDs,
      [remaining.id])
    let reopenedExport = try await reopened.exportSnapshot()
    XCTAssertFalse(reopenedExport.messages.contains { $0.conversationID == directID })
    try await reopened.apply(
      .updateGroup(id: group.id, title: group.title, members: [remaining.id, repair.id]))
    try await reopened.apply(
      .beginGeneration(
        SendCommand(conversationID: group.id, targetBotID: remaining.id, text: "Repaired")))
  }

  func testDeletingLastMembersLeavesReadableEmptyGroupThatCanBeRepaired() async throws {
    let (repository, url) = try await open()
    let (first, _) = try await createBot(repository, name: "First")
    let (second, _) = try await createBot(repository, name: "Second")
    let group = Conversation(
      kind: .group, title: "Empty Later", memberBotIDs: [first.id, second.id])
    try await repository.apply(.createGroup(group))
    try await repository.apply(.deleteBot(expected: repository.botDeletionPlan(botID: first.id)))
    try await repository.apply(.deleteBot(expected: repository.botDeletionPlan(botID: second.id)))
    try await repository.close()

    let (reopened, _) = try await open(url)
    let emptySnapshot = try await reopened.snapshot()
    XCTAssertEqual(
      emptySnapshot.conversations.first { $0.id == group.id }?.memberBotIDs, [])
    let (replacementA, _) = try await createBot(reopened, name: "Replacement A")
    let (replacementB, _) = try await createBot(reopened, name: "Replacement B")
    let degraded = GroupProfile(title: group.title, memberBotIDs: [])
    do {
      try await reopened.apply(
        .editGroup(
          id: group.id, expected: GroupProfile(title: "Stale", memberBotIDs: []),
          replacement: GroupProfile(
            title: "Repaired", memberBotIDs: [replacementA.id, replacementB.id])))
      XCTFail("Expected stale repair snapshot to fail")
    } catch { XCTAssertEqual(error as? WorkspaceError, .editConflict) }
    try await reopened.apply(
      .editGroup(
        id: group.id, expected: degraded,
        replacement: GroupProfile(
          title: "Repaired", memberBotIDs: [replacementA.id, replacementB.id])))
    let repairedSnapshot = try await reopened.snapshot()
    XCTAssertEqual(
      repairedSnapshot.conversations.first { $0.id == group.id }?.memberBotIDs,
      [replacementA.id, replacementB.id])
  }

  func testStalePlanRejectsBeforeAnyEffects() async throws {
    let (repository, _) = try await open()
    let (bot, conversationID) = try await createBot(repository, name: "Bot")
    let plan = try await repository.botDeletionPlan(botID: bot.id)
    try await beginTerminalGeneration(repository, conversationID: conversationID, botID: bot.id)
    let before = try await repository.exportSnapshot()
    await assertDeletionError(.confirmationChanged) {
      try await repository.apply(.deleteBot(expected: plan))
    }
    let after = try await repository.exportSnapshot()
    XCTAssertEqual(after.bots, before.bots)
    XCTAssertEqual(after.conversations, before.conversations)
    XCTAssertEqual(after.messages, before.messages)
    XCTAssertEqual(after.generations, before.generations)
  }

  func testActiveWorkAcrossAffectedGroupMustStopBeforeDeletion() async throws {
    let (repository, _) = try await open()
    let (deleted, _) = try await createBot(repository, name: "Deleted")
    let (other, _) = try await createBot(repository, name: "Other")
    let group = Conversation(kind: .group, title: "Team", memberBotIDs: [deleted.id, other.id])
    try await repository.apply(.createGroup(group))
    let active = SendCommand(conversationID: group.id, targetBotID: other.id, text: "Active")
    try await repository.apply(.beginGeneration(active))
    let plan = try await repository.botDeletionPlan(botID: deleted.id)
    XCTAssertEqual(plan.activeGenerationIDs, [active.generationID])
    XCTAssertEqual(
      Set(plan.cancellationConversationIDs), [plan.directConversationIDs[0], group.id])
    await assertDeletionError(.activeWork) {
      try await repository.apply(.deleteBot(expected: plan))
    }
    try await repository.apply(
      .cancelGeneration(id: active.generationID, attemptID: active.attemptID))
    try await repository.apply(.deleteBot(expected: plan))
    let snapshot = try await repository.snapshot()
    XCTAssertFalse(snapshot.bots.contains { $0.id == deleted.id })
  }

  func testUnrelatedRevisionDoesNotInvalidateConfirmedContent() async throws {
    let (repository, _) = try await open()
    let (deleted, _) = try await createBot(repository, name: "Deleted")
    let (unrelated, unrelatedConversationID) = try await createBot(repository, name: "Unrelated")
    let plan = try await repository.botDeletionPlan(botID: deleted.id)
    try await repository.apply(
      .saveDraft(Draft(conversationID: unrelatedConversationID, text: "Unrelated change")))
    try await repository.apply(.deleteBot(expected: plan))
    let snapshot = try await repository.snapshot()
    XCTAssertFalse(snapshot.bots.contains { $0.id == deleted.id })
    XCTAssertTrue(snapshot.bots.contains { $0.id == unrelated.id })
    XCTAssertEqual(snapshot.drafts.first?.text, "Unrelated change")
  }

  func testSaveFailureRollsBackEveryDeletionEffect() async throws {
    let (repository, _) = try await open()
    let (deleted, directID) = try await createBot(repository, name: "Rollback")
    let (remaining, _) = try await createBot(repository, name: "Remaining")
    let group = Conversation(kind: .group, title: "Team", memberBotIDs: [deleted.id, remaining.id])
    try await repository.apply(.createGroup(group))
    try await beginTerminalGeneration(repository, conversationID: directID, botID: deleted.id)
    try await repository.apply(.saveDraft(Draft(conversationID: directID, text: "Keep")))
    let before = try await repository.exportSnapshot()
    let plan = try await repository.botDeletionPlan(botID: deleted.id)
    await repository.injectNextSaveFailure()
    do {
      try await repository.apply(.deleteBot(expected: plan))
      XCTFail("Expected save failure")
    } catch { XCTAssertEqual(error as? WorkspaceError, .storeUnavailable) }
    let after = try await repository.exportSnapshot()
    XCTAssertEqual(after.bots, before.bots)
    XCTAssertEqual(after.conversations, before.conversations)
    XCTAssertEqual(after.messages, before.messages)
    XCTAssertEqual(after.drafts, before.drafts)
    XCTAssertEqual(after.generations, before.generations)
    XCTAssertEqual(after.routines, before.routines)
  }

  func testMissingBotIsExplicit() async throws {
    let (repository, _) = try await open()
    do {
      _ = try await repository.botDeletionPlan(botID: UUID())
      XCTFail("Expected missing record")
    } catch { XCTAssertEqual(error as? WorkspaceError, .missingRecord) }
  }

  func testUnexpectedAttachmentReferenceRefusesPlanWithoutDeletingAnything() async throws {
    let (repository, _) = try await open()
    let (bot, conversationID) = try await createBot(repository, name: "Attached")
    let command = try await beginTerminalGeneration(
      repository, conversationID: conversationID, botID: bot.id)
    try await repository.injectUnsupportedAttachmentReferenceForTesting(
      messageID: command.userMessageID)
    do {
      _ = try await repository.botDeletionPlan(botID: bot.id)
      XCTFail("Expected dangling attachment to fail closed")
    } catch { XCTAssertEqual(error as? AttachmentError, .missingAttachment) }
    let message = try await repository.message(id: command.userMessageID)
    let snapshot = try await repository.snapshot()
    XCTAssertEqual(message.attachmentIDs.count, 1)
    XCTAssertTrue(snapshot.bots.contains { $0.id == bot.id })
  }
}
