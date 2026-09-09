import Foundation
import XCTest

@testable import NativeShell
@testable import WorkspaceCore

@MainActor final class BotDeletionWorkspaceTests: XCTestCase {
  func testPreviewFlushesDraftShowsCountsAndCancelKeepsRecords() async throws {
    let f = try await fixture()
    f.store.selectedID = f.directID
    f.store.draft = "Keep this draft"
    await f.store.beginBotDeletion(f.botID)?.value
    XCTAssertEqual(f.store.botDeletionPlan?.name, "Delete fixture")
    XCTAssertEqual(f.store.botDeletionPlan?.directConversationCount, 1)
    XCTAssertEqual(f.store.botDeletionPlan?.draftCount, 1)
    XCTAssertEqual(f.store.botDeletionPlan?.routineCount, 1)
    XCTAssertEqual(f.store.botDeletionPlan?.affectedGroupCount, 1)
    XCTAssertFalse(f.store.canExportWorkspace)
    f.store.cancelBotDeletion()
    XCTAssertNil(f.store.botDeletionTarget)
    XCTAssertNil(f.store.botDeletionPlan)
    let snapshot = try await f.repository.snapshot()
    XCTAssertEqual(snapshot.bots.count, 2)
    XCTAssertEqual(
      snapshot.drafts.first { $0.conversationID == f.directID }?.text, "Keep this draft")
  }

  func testConfirmationUsesCapturedBotAndPreservesGroupDraftAndProvider() async throws {
    let f = try await fixture()
    f.store.selectedID = f.directID
    f.store.draft = "Delete only this draft"
    await f.store.beginBotDeletion(f.botID)?.value
    f.store.selectedID = f.groupID
    f.store.draft = "Keep the group draft"
    f.store.selectedTargetBotIDs[f.groupID] = f.botID
    let task = try XCTUnwrap(f.store.confirmBotDeletion())
    XCTAssertNil(f.store.confirmBotDeletion())
    await task.value
    let snapshot = try await f.repository.snapshot()
    XCTAssertFalse(snapshot.bots.contains { $0.id == f.botID })
    XCTAssertEqual(snapshot.providers, [f.provider])
    XCTAssertTrue(snapshot.routines.isEmpty)
    XCTAssertFalse(snapshot.conversations.contains { $0.id == f.directID })
    XCTAssertEqual(
      snapshot.conversations.first { $0.id == f.groupID }?.memberBotIDs, [f.otherBotID])
    XCTAssertEqual(f.store.selectedID, f.groupID)
    XCTAssertEqual(f.store.draft, "Keep the group draft")
    XCTAssertTrue(f.store.currentNeedsMembershipRepair)
    XCTAssertNil(f.store.selectedTargetBotIDs[f.groupID])
    XCTAssertNil(f.store.drafts[f.directID])
    XCTAssertNil(f.store.messages[f.directID])
    XCTAssertNil(f.store.botDeletionError)
    XCTAssertNil(f.store.botDeletionTarget)
    XCTAssertTrue(f.store.canExportWorkspace)
  }

  func testDeletedSelectedConversationFallsBackWithoutGhostDraft() async throws {
    let f = try await fixture()
    f.store.selectedID = f.directID
    f.store.draft = "Remove"
    await f.store.beginBotDeletion(f.botID)?.value
    await f.store.confirmBotDeletion()?.value
    XCTAssertNotNil(f.store.selectedID)
    XCTAssertNotEqual(f.store.selectedID, f.directID)
    XCTAssertFalse(f.store.dirtyDrafts.contains(f.directID))
    try await f.store.flushDrafts()
    let snapshot = try await f.repository.snapshot()
    XCTAssertFalse(snapshot.drafts.contains { $0.conversationID == f.directID })
  }

  func testStaleImpactRequiresExplicitReloadBeforeRetry() async throws {
    let f = try await fixture()
    await f.store.beginBotDeletion(f.botID)?.value
    try await f.repository.apply(
      .saveRoutine(
        Routine(
          ownerBotID: f.botID, name: "New routine", prompt: "Keep", trigger: .interval(minutes: 10),
          timezoneID: "UTC")))
    await f.store.confirmBotDeletion()?.value
    let snapshot = try await f.repository.snapshot()
    XCTAssertTrue(snapshot.bots.contains { $0.id == f.botID })
    XCTAssertEqual(snapshot.routines.count, 2)
    XCTAssertNil(f.store.botDeletionPlan)
    XCTAssertNotNil(f.store.botDeletionError)
    XCTAssertNil(f.store.confirmBotDeletion())
    await f.store.reloadBotDeletionPlan()?.value
    XCTAssertEqual(f.store.botDeletionPlan?.routineCount, 2)
    f.store.cancelBotDeletion()
  }

  func testFailedDeletePreservesRowsAndRequiresReview() async throws {
    let f = try await fixture()
    await f.store.beginBotDeletion(f.botID)?.value
    let before = try await f.repository.snapshot()
    await f.repository.injectNextSaveFailure()
    await f.store.confirmBotDeletion()?.value
    let after = try await f.repository.snapshot()
    XCTAssertEqual(after, before)
    XCTAssertNotNil(f.store.botDeletionTarget)
    XCTAssertNil(f.store.botDeletionPlan)
    XCTAssertNotNil(f.store.botDeletionError)
    XCTAssertTrue(f.store.bots.contains { $0.id == f.botID })
    XCTAssertNil(f.store.notice)
  }

  func testDegradedGroupRetainsHistoryAndCanBeRepairedAfterReopen() async throws {
    let f = try await fixture()
    let command = SendCommand(
      conversationID: f.groupID, targetBotID: f.botID, text: "Recorded question")
    try await f.repository.apply(.beginGeneration(command))
    for (sequence, kind) in [
      (Int64(1), GenerationEvent.Kind.started), (2, .delta("Recorded answer")), (3, .completed),
    ] {
      try await f.repository.apply(
        .applyGenerationEvent(
          GenerationEvent(
            generationID: command.generationID, attemptID: command.attemptID, sequence: sequence,
            kind: kind)))
    }
    f.store.selectedID = f.groupID
    f.store.draft = "Repair before sending"
    await f.store.beginBotDeletion(f.botID)?.value
    await f.store.confirmBotDeletion()?.value
    XCTAssertTrue(f.store.currentNeedsMembershipRepair)
    f.store.performSend()
    XCTAssertEqual(f.store.draft, "Repair before sending")
    XCTAssertTrue(f.store.notice?.contains("Repair") == true)
    let snapshot = try await f.repository.snapshot()
    let oldGeneration = try XCTUnwrap(snapshot.generations.first)
    XCTAssertFalse(f.store.canRetry(oldGeneration))
    let page = try await f.repository.messages(conversationID: f.groupID)
    XCTAssertEqual(page.messages.last?.speakerNameSnapshot, "Delete fixture")
    XCTAssertEqual(page.messages.last?.text, "Recorded answer")
    try await f.store.prepareForClose()
    try await f.repository.close()
    let reopened = try await CoreDataWorkspaceRepository.open(at: f.url)
    addTeardownBlock { try? await reopened.close() }
    let restored = PreviewWorkspace(seed: false)
    try await restored.connect(reopened, displayName: "Deletion fixture")
    restored.selectedID = f.groupID
    try await restored.loadMessages(f.groupID)
    XCTAssertTrue(restored.currentNeedsMembershipRepair)
    XCTAssertEqual(restored.currentMessages.last?.speakerName, "Delete fixture")
    let newBot = Bot(name: "Repair member")
    try await reopened.apply(.createBot(newBot, conversationID: UUID()))
    try await restored.refreshPersistent()
    let target = ProfileEditTarget.group(f.groupID)
    let expected = try await restored.loadProfile(for: target)
    try await restored.saveProfile(
      for: target, expected: expected,
      replacement: .group(
        GroupProfile(title: "Repaired group", memberBotIDs: [f.otherBotID, newBot.id])))
    XCTAssertFalse(restored.currentNeedsMembershipRepair)
    XCTAssertEqual(restored.draft, "Repair before sending")
  }

  func testCancelledPendingPreviewCannotReopenSheet() async throws {
    let f = try await fixture()
    let paused = PausedDeletionRepository(base: f.repository)
    try await f.store.connect(paused)
    await paused.pausePreview()
    let load = try XCTUnwrap(f.store.beginBotDeletion(f.botID))
    await paused.waitUntilPaused()
    f.store.cancelBotDeletion()
    await paused.release()
    await load.value
    XCTAssertNil(f.store.botDeletionTarget)
    XCTAssertNil(f.store.botDeletionPlan)
    XCTAssertNil(f.store.botDeletionError)
  }

  func testReconnectInvalidatesPausedPreview() async throws {
    let f = try await fixture()
    let other = try await fixture()
    let paused = PausedDeletionRepository(base: f.repository)
    try await f.store.connect(paused)
    await paused.pausePreview()
    let load = try XCTUnwrap(f.store.beginBotDeletion(f.botID))
    await paused.waitUntilPaused()
    try await f.store.connect(other.repository)
    await paused.release()
    await load.value
    XCTAssertNil(f.store.botDeletionTarget)
    XCTAssertNil(f.store.botDeletionPlan)
    XCTAssertTrue(f.store.bots.contains { $0.id == other.botID })
    XCTAssertFalse(f.store.bots.contains { $0.id == f.botID })
  }

  func testCloseJoinsAcceptedDeleteAndDoesNotCancelIt() async throws {
    let f = try await fixture()
    let paused = PausedDeletionRepository(base: f.repository)
    try await f.store.connect(paused)
    await f.store.beginBotDeletion(f.botID)?.value
    await paused.pauseDeletion()
    let deletion = try XCTUnwrap(f.store.confirmBotDeletion())
    await paused.waitUntilPaused()
    var closeFinished = false
    f.store.isClosing = true
    let close = Task {
      try await f.store.prepareForClose()
      closeFinished = true
    }
    await Task.yield()
    XCTAssertFalse(closeFinished)
    XCTAssertTrue(f.store.isDeletingBot)
    await paused.release()
    await deletion.value
    try await close.value
    XCTAssertTrue(closeFinished)
    let snapshot = try await f.repository.snapshot()
    XCTAssertFalse(snapshot.bots.contains { $0.id == f.botID })
  }

  func testDeletingLastMemberKeepsZeroMemberGroupReadable() async throws {
    let f = try await fixture()
    f.store.selectedID = f.groupID
    f.store.draft = "Keep this empty group's draft"
    await f.store.beginBotDeletion(f.botID)?.value
    await f.store.confirmBotDeletion()?.value
    await f.store.beginBotDeletion(f.otherBotID)?.value
    await f.store.confirmBotDeletion()?.value
    XCTAssertTrue(f.store.bots.isEmpty)
    XCTAssertEqual(f.store.conversations.count, 1)
    XCTAssertEqual(f.store.selectedID, f.groupID)
    XCTAssertTrue(f.store.currentNeedsMembershipRepair)
    XCTAssertEqual(f.store.draft, "Keep this empty group's draft")
    let snapshot = try await f.repository.snapshot()
    XCTAssertEqual(snapshot.conversations.first?.memberBotIDs, [])
    XCTAssertEqual(snapshot.providers, [f.provider])
  }

  func testReconnectJoinsAcceptedDeletionBeforeReplacingRepository() async throws {
    let f = try await fixture()
    let replacement = try await fixture()
    let paused = PausedDeletionRepository(base: f.repository)
    try await f.store.connect(paused)
    await f.store.beginBotDeletion(f.botID)?.value
    await paused.pauseDeletion()
    let deletion = try XCTUnwrap(f.store.confirmBotDeletion())
    await paused.waitUntilPaused()
    var didConnect = false
    let connect = Task {
      try await f.store.connect(replacement.repository)
      didConnect = true
    }
    await Task.yield()
    XCTAssertFalse(didConnect)
    await paused.release()
    await deletion.value
    try await connect.value
    let original = try await f.repository.snapshot()
    XCTAssertFalse(original.bots.contains { $0.id == f.botID })
    XCTAssertTrue(f.store.bots.contains { $0.id == replacement.botID })
    XCTAssertNil(f.store.botDeletionTarget)
  }

  func testFailedAcceptedDeletePreventsClose() async throws {
    let f = try await fixture()
    let paused = PausedDeletionRepository(base: f.repository)
    try await f.store.connect(paused)
    await f.store.beginBotDeletion(f.botID)?.value
    await paused.pauseDeletion()
    let deletion = try XCTUnwrap(f.store.confirmBotDeletion())
    await paused.waitUntilPaused()
    await f.repository.injectNextSaveFailure()
    f.store.isClosing = true
    let close = Task { try await f.store.prepareForClose() }
    await Task.yield()
    await paused.release()
    await deletion.value
    do {
      try await close.value
      XCTFail("Failed accepted deletion must keep the workspace open")
    } catch { XCTAssertEqual(error as? WorkspaceError, .storeUnavailable) }
    let snapshot = try await f.repository.snapshot()
    XCTAssertTrue(snapshot.bots.contains { $0.id == f.botID })
    XCTAssertNotNil(f.store.botDeletionError)
  }

  private func fixture() async throws -> DeletionFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "NativeBotDeletionTests-\(UUID())")
    let url = directory.appendingPathComponent("workspace.sqlite")
    let repository = try await CoreDataWorkspaceRepository.open(at: url)
    addTeardownBlock {
      try? await repository.close()
      try? FileManager.default.removeItem(at: directory)
    }
    let bot = Bot(name: "Delete fixture")
    let other = Bot(name: "Keep fixture")
    let direct = UUID()
    let group = Conversation(kind: .group, title: "Keep group", memberBotIDs: [bot.id, other.id])
    let provider = ProviderConfig(
      name: "Shared", apiRoot: URL(string: "https://fixture.invalid/v1")!,
      modelID: "fixture", credentialReference: "fixture-reference")
    try await repository.apply(.saveProvider(provider))
    try await repository.apply(.createBot(bot, conversationID: direct))
    try await repository.apply(.createBot(other, conversationID: UUID()))
    try await repository.apply(.createGroup(group))
    try await repository.apply(
      .saveRoutine(
        Routine(
          ownerBotID: bot.id, name: "Owned routine", prompt: "Keep until delete",
          trigger: .interval(minutes: 10), timezoneID: "UTC")))
    let store = PreviewWorkspace(seed: false)
    try await store.connect(repository, displayName: "Deletion fixture")
    return DeletionFixture(
      store: store, repository: repository, url: url,
      botID: bot.id, otherBotID: other.id, directID: direct, groupID: group.id, provider: provider)
  }
}

private struct DeletionFixture {
  let store: PreviewWorkspace
  let repository: CoreDataWorkspaceRepository
  let url: URL
  let botID: UUID
  let otherBotID: UUID
  let directID: UUID
  let groupID: UUID
  let provider: ProviderConfig
}

private actor PausedDeletionRepository: WorkspaceRepository {
  let base: CoreDataWorkspaceRepository
  var previewPaused = false
  var deletionPaused = false
  var paused = false
  var continuation: CheckedContinuation<Void, Never>?
  var waiter: CheckedContinuation<Void, Never>?
  init(base: CoreDataWorkspaceRepository) { self.base = base }
  func pausePreview() { previewPaused = true }
  func pauseDeletion() { deletionPaused = true }
  func waitUntilPaused() async {
    if paused { return }
    await withCheckedContinuation { waiter = $0 }
  }
  func release() {
    continuation?.resume()
    continuation = nil
  }
  private func suspend() async {
    paused = true
    waiter?.resume()
    waiter = nil
    await withCheckedContinuation { continuation = $0 }
  }
  func botDeletionPlan(botID: UUID) async throws -> BotDeletionPlan {
    let plan = try await base.botDeletionPlan(botID: botID)
    if previewPaused {
      previewPaused = false
      await suspend()
    }
    return plan
  }
  func apply(_ mutation: WorkspaceMutation, expectedRevision: Int64?) async throws -> Int64 {
    if case .deleteBot = mutation, deletionPaused {
      deletionPaused = false
      await suspend()
    }
    return try await base.apply(mutation, expectedRevision: expectedRevision)
  }
  func snapshot() async throws -> WorkspaceSnapshot { try await base.snapshot() }
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
