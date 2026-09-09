import XCTest

@testable import NativeShell
@testable import WorkspaceCore

@MainActor
final class ReplyWorkspaceTests: XCTestCase {
  private var storeURL: URL?
  func testEditingRestoredReplyDraftPreservesItsReference() async throws {
    let (workspace, repository, conversationID, parentID, _) = try await fixture()
    try await repository.apply(
      .saveDraft(Draft(conversationID: conversationID, text: "Original draft", replyToID: parentID))
    )
    try await workspace.connect(repository, displayName: "Reply fixture")
    workspace.draft = "Edited draft"
    try await workspace.flushDrafts()
    let snapshot = try await repository.snapshot()
    let draft = try XCTUnwrap(snapshot.drafts.first { $0.conversationID == conversationID })
    XCTAssertEqual(draft.text, "Edited draft")
    XCTAssertEqual(draft.replyToID, parentID)
  }

  func testReplyAndCancelAreConversationScopedAndKeepDraftText() async throws {
    let (workspace, repository, first, parent, _) = try await fixture()
    workspace.draft = "Keep this text"
    await workspace.beginReply(to: parent, in: first)
    XCTAssertEqual(workspace.currentReply?.id, parent)
    XCTAssertEqual(workspace.currentReply?.speakerName, "Research Partner")
    XCTAssertEqual(workspace.draft, "Keep this text")
    _ = try await workspace.performCreateBot(
      name: "Second", description: "", color: "blue", shape: .circle)
    let second = try XCTUnwrap(workspace.selectedID)
    XCTAssertNil(workspace.currentReply)
    workspace.draft = "Independent draft"
    workspace.clearReply(in: first)  // a stale control from another conversation has no authority
    XCTAssertEqual(workspace.draftReplyIDs[first], parent)
    workspace.selectedID = first
    workspace.clearReply(in: first)
    XCTAssertNil(workspace.currentReply)
    XCTAssertEqual(workspace.draft, "Keep this text")
    XCTAssertEqual(workspace.drafts[second], "Independent draft")
    try await workspace.flushDrafts()
    let snapshot = try await repository.snapshot()
    XCTAssertNil(snapshot.drafts.first { $0.conversationID == first }?.replyToID)
  }

  func testReplyDraftRestoresAfterRealRepositoryReopen() async throws {
    let (workspace, repository, conversationID, parentID, _) = try await fixture()
    workspace.draft = "สวัสดี — explain this source 👩🏽‍💻"
    await workspace.beginReply(to: parentID, in: conversationID)
    try await workspace.flushDrafts()
    workspace.draftSaveTask?.cancel()
    let url = try XCTUnwrap(storeURL)
    try await workspace.prepareForClose()
    try await repository.close()
    let reopened = try await CoreDataWorkspaceRepository.open(at: url)
    addTeardownBlock { try? await reopened.close() }
    let restored = PreviewWorkspace(seed: false)
    try await restored.connect(reopened, displayName: "Reply fixture")
    XCTAssertEqual(restored.draft, "สวัสดี — explain this source 👩🏽‍💻")
    XCTAssertEqual(restored.currentReply?.id, parentID)
    XCTAssertEqual(restored.currentReply?.speakerName, "Research Partner")
    XCTAssertTrue(restored.currentReply?.isAvailable == true)
  }

  func testOldReplyPreviewAndJumpLoadContiguousHistoryWithoutLosingDraft() async throws {
    let (workspace, repository, conversationID, parentID, botID) = try await fixture()
    for index in 0..<55 {
      _ = try await appendReply(
        repository, conversationID: conversationID, botID: botID, text: "Later answer \(index)")
    }
    try await workspace.loadMessages(conversationID)
    XCTAssertEqual(workspace.currentMessages.count, 100)
    XCTAssertFalse(workspace.currentMessages.contains { $0.id == parentID })
    workspace.draft = "Compare with the first answer"
    await workspace.beginReply(to: parentID, in: conversationID)
    XCTAssertEqual(workspace.currentReply?.excerpt, "A fictional source with useful context.")
    await workspace.jumpToReply(messageID: parentID, in: conversationID)
    XCTAssertEqual(workspace.transcriptJumpRequest?.messageID, parentID)
    XCTAssertEqual(workspace.selectedID, conversationID)
    XCTAssertEqual(workspace.currentMessages.count, 112)
    XCTAssertEqual(Set(workspace.currentMessages.map(\.id)).count, 112)
    XCTAssertEqual(workspace.currentMessages.compactMap(\.sequence), Array(Int64(1)...112))
    XCTAssertEqual(workspace.draft, "Compare with the first answer")
    XCTAssertEqual(workspace.currentReply?.id, parentID)
  }

  func testOverlappingOlderPageDoesNotRegressCursorOrReplaceVisibleText() async throws {
    let (workspace, repository, conversationID, _, botID) = try await fixture()
    for index in 0..<5 {
      _ = try await appendReply(
        repository, conversationID: conversationID, botID: botID, text: "Answer \(index)")
    }
    try await workspace.loadMessages(conversationID)
    XCTAssertFalse(workspace.hasOlderMessages)
    let latest = try XCTUnwrap(workspace.currentMessages.last)
    workspace.messages[conversationID]?[11] = PreviewMessage(
      .assistant, "Newer visible text", id: latest.id, sequence: latest.sequence)
    let overlapping = try await repository.messages(
      conversationID: conversationID, beforeSequence: nil, limit: 5)
    XCTAssertTrue(overlapping.hasMore)
    workspace.mergeOlderMessages(overlapping, in: conversationID)
    XCTAssertFalse(workspace.hasOlderMessages)
    XCTAssertNil(workspace.olderCursor)
    XCTAssertEqual(workspace.currentMessages.count, 12)
    XCTAssertEqual(workspace.currentMessages.last?.text, "Newer visible text")
  }

  func testCancellingPendingParentLookupCannotRestoreReply() async throws {
    let (workspace, base, conversationID, parentID, _) = try await fixture()
    let repository = PausedReplyLookupRepository(base: base)
    try await workspace.connect(repository, displayName: "Reply fixture")
    workspace.draft = "Keep"
    await repository.pause(parentID)
    let selection = Task { await workspace.beginReply(to: parentID, in: conversationID) }
    await repository.waitUntilPaused()
    workspace.clearReply(in: conversationID)
    await repository.release()
    await selection.value
    XCTAssertNil(workspace.currentReply)
    XCTAssertEqual(workspace.draft, "Keep")
  }

  func testSelectionChangeRejectsLateParentLookupAndJumpDoesNotNavigate() async throws {
    let (workspace, base, first, parentID, _) = try await fixture()
    _ = try await workspace.performCreateBot(
      name: "Other", description: "", color: "green", shape: .circle)
    let second = try XCTUnwrap(workspace.selectedID)
    let repository = PausedReplyLookupRepository(base: base)
    try await workspace.connect(repository, displayName: "Reply fixture")
    workspace.selectedID = first
    await repository.pause(parentID)
    let selection = Task { await workspace.beginReply(to: parentID, in: first) }
    await repository.waitUntilPaused()
    workspace.select(second)
    try await waitUntil { workspace.selectedID == second }
    await repository.release()
    await selection.value
    XCTAssertNil(workspace.draftReplyIDs[first])
    await workspace.jumpToReply(messageID: parentID, in: first)
    XCTAssertNil(workspace.transcriptJumpRequest)
    XCTAssertEqual(workspace.selectedID, second)
  }

  func testCrossConversationAndMissingParentsPreserveExistingReply() async throws {
    let (workspace, repository, first, parentID, _) = try await fixture()
    workspace.draft = "Keep"
    await workspace.beginReply(to: parentID, in: first)
    let bot = Bot(name: "Other")
    let second = UUID()
    try await repository.apply(.createBot(bot, conversationID: second))
    let foreignID = try await appendReply(repository, conversationID: second, botID: bot.id)
    await workspace.beginReply(to: foreignID, in: first)
    XCTAssertEqual(workspace.currentReply?.id, parentID)
    await workspace.beginReply(to: UUID(), in: first)
    XCTAssertEqual(workspace.currentReply?.id, parentID)
    XCTAssertEqual(workspace.draft, "Keep")
    XCTAssertNotNil(workspace.notice)
    await workspace.jumpToReply(messageID: foreignID, in: first)
    XCTAssertNil(workspace.transcriptJumpRequest)
  }

  func testFailedReplyDraftSaveRetainsTextAndReferenceForRetry() async throws {
    let (workspace, repository, conversationID, parentID, _) = try await fixture()
    workspace.draft = "Keep after write failure"
    await workspace.beginReply(to: parentID, in: conversationID)
    workspace.draftSaveTask?.cancel()
    await repository.injectNextSaveFailure()
    do {
      try await workspace.flushDrafts()
      XCTFail("Expected controlled save failure")
    } catch { XCTAssertEqual(error as? WorkspaceError, .storeUnavailable) }
    XCTAssertEqual(workspace.draft, "Keep after write failure")
    XCTAssertEqual(workspace.currentReply?.id, parentID)
    XCTAssertTrue(workspace.dirtyDrafts.contains(conversationID))
    try await workspace.flushDrafts()
    let snapshot = try await repository.snapshot()
    XCTAssertEqual(
      snapshot.drafts.first { $0.conversationID == conversationID }?.replyToID, parentID)
  }

  func testNoProviderSendKeepsReplyDraftWithoutCreatingMessages() async throws {
    let (workspace, repository, conversationID, parentID, _) = try await fixture()
    workspace.draft = "No provider"
    await workspace.beginReply(to: parentID, in: conversationID)
    workspace.performSend()
    try await workspace.flushDrafts()
    let snapshot = try await repository.snapshot()
    let page = try await repository.messages(conversationID: conversationID)
    XCTAssertEqual(page.messages.count, 2)
    XCTAssertEqual(
      snapshot.drafts.first { $0.conversationID == conversationID }?.replyToID, parentID)
    XCTAssertEqual(workspace.currentReply?.id, parentID)
  }

  func testNewReplyChoiceDuringSubmissionPreservesSameTextAndNewParent() async throws {
    let (workspace, repository, conversationID, firstParent, botID) = try await fixture()
    let secondParent = try await appendReply(
      repository, conversationID: conversationID, botID: botID, text: "Another source")
    let credentials = PausedReplyCredentials()
    try await workspace.connect(
      repository, credentials: credentials, provider: SmokeChatProvider(),
      displayName: "Reply fixture")
    _ = try await workspace.saveProvider(
      id: nil, name: "Offline fixture", apiRoot: "https://fixture.invalid/v1", modelID: "fixture",
      secret: "offline-reply-fixture", allowsLoopbackHTTP: false)
    workspace.draft = "Same text"
    await workspace.beginReply(to: firstParent, in: conversationID)
    await credentials.pauseNextRead()
    let submission = Task { try await workspace.submitDraft() }
    await credentials.waitUntilPaused()
    await workspace.beginReply(to: secondParent, in: conversationID)
    try await workspace.flushDrafts()
    await credentials.release()
    _ = try await submission.value
    await workspace.coordinator?.waitForIdle()
    try await workspace.flushDrafts()
    let snapshot = try await repository.snapshot()
    let page = try await repository.messages(conversationID: conversationID)
    let sent = try XCTUnwrap(page.messages.first { $0.text == "Same text" })
    XCTAssertEqual(sent.replyToID, firstParent)
    XCTAssertEqual(workspace.draft, "Same text")
    XCTAssertEqual(workspace.currentReply?.id, secondParent)
    XCTAssertEqual(
      snapshot.drafts.first { $0.conversationID == conversationID }?.replyToID, secondParent)
    XCTAssertEqual(
      workspace.replyPreview(
        for: try XCTUnwrap(workspace.currentMessages.first { $0.id == sent.id }))?.id, firstParent)
  }

  func testEmptyParentCannotReplaceAnExistingReply() async throws {
    let (workspace, repository, conversationID, parentID, botID) = try await fixture()
    await workspace.beginReply(to: parentID, in: conversationID)
    let empty = try await appendReply(
      repository, conversationID: conversationID, botID: botID, text: "")
    await workspace.beginReply(to: empty, in: conversationID)
    XCTAssertEqual(workspace.currentReply?.id, parentID)
    XCTAssertFalse(ReplyPreview(message: PreviewMessage(.assistant, "")).isAvailable)
  }

  func testUnavailableParentReadIsCachedUntilExplicitReload() async throws {
    let (workspace, base, conversationID, _, _) = try await fixture()
    let repository = PausedReplyLookupRepository(base: base)
    try await workspace.connect(repository, displayName: "Reply fixture")
    workspace.draftReplyIDs[conversationID] = UUID()
    await workspace.refreshReplyPreviews(in: conversationID)
    await workspace.refreshReplyPreviews(in: conversationID)
    let firstCount = await repository.readCount()
    XCTAssertEqual(firstCount, 1)
    XCTAssertTrue(workspace.currentReply?.isAvailable == false)
    XCTAssertTrue(workspace.currentReply?.isLoading == false)
    try await workspace.loadMessages(conversationID)
    let secondCount = await repository.readCount()
    XCTAssertEqual(secondCount, 2)
  }

  func testConnectingAnotherStoreWaitsForOldReplyDraftAndDoesNotCopyIt() async throws {
    let (workspace, first, conversationID, parentID, _) = try await fixture()
    let repository = PausedReplyLookupRepository(base: first)
    try await workspace.connect(repository, displayName: "First fixture")
    workspace.draft = "First workspace draft"
    await workspace.beginReply(to: parentID, in: conversationID)
    workspace.draftSaveTask?.cancel()
    await repository.pauseNextDraft()
    let flush = Task { try await workspace.flushDrafts() }
    await repository.waitUntilPaused()
    let secondURL = try XCTUnwrap(storeURL).deletingLastPathComponent().appendingPathComponent(
      "second.sqlite")
    let second = try await CoreDataWorkspaceRepository.open(at: secondURL)
    addTeardownBlock { try? await second.close() }
    let firstSnapshot = try await first.snapshot()
    let bot = try XCTUnwrap(firstSnapshot.bots.first)
    try await second.apply(.createBot(bot, conversationID: conversationID))
    try await second.apply(
      .saveDraft(Draft(conversationID: conversationID, text: "Second workspace draft")))
    let connecting = Task { try await workspace.connect(second, displayName: "Second fixture") }
    try await waitUntil { workspace.isLoading }
    XCTAssertEqual(workspace.draft, "First workspace draft")
    await repository.release()
    try await flush.value
    try await connecting.value
    XCTAssertEqual(workspace.draft, "Second workspace draft")
    XCTAssertNil(workspace.currentReply)
    let original = try await first.snapshot()
    let replacement = try await second.snapshot()
    XCTAssertEqual(
      original.drafts.first { $0.conversationID == conversationID }?.replyToID, parentID)
    XCTAssertEqual(replacement.drafts.first?.text, "Second workspace draft")
    XCTAssertNil(replacement.drafts.first?.replyToID)
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<200 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("Timed out waiting for test condition")
    throw WorkspaceError.storeUnavailable
  }

  private func fixture() async throws -> (
    PreviewWorkspace, CoreDataWorkspaceRepository, UUID, UUID, UUID
  ) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ReplyTests-\(UUID())")
    let url = directory.appendingPathComponent("workspace.sqlite")
    storeURL = url
    let repository = try await CoreDataWorkspaceRepository.open(at: url)
    let workspace = PreviewWorkspace(seed: false)
    addTeardownBlock {
      await workspace.draftSaveTask?.cancel()
      try? await workspace.prepareForClose()
      try? await repository.close()
      try? FileManager.default.removeItem(at: directory)
    }
    let bot = Bot(name: "Research Partner")
    let conversationID = UUID()
    try await repository.apply(.createBot(bot, conversationID: conversationID))
    let parentID = try await appendReply(repository, conversationID: conversationID, botID: bot.id)
    try await workspace.connect(repository, displayName: "Reply fixture")
    return (workspace, repository, conversationID, parentID, bot.id)
  }

  private func appendReply(
    _ repository: CoreDataWorkspaceRepository, conversationID: UUID, botID: UUID,
    text: String = "A fictional source with useful context."
  ) async throws -> UUID {
    let command = SendCommand(conversationID: conversationID, targetBotID: botID, text: "Question")
    try await repository.apply(.beginGeneration(command))
    try await repository.apply(
      .applyGenerationEvent(
        GenerationEvent(
          generationID: command.generationID, attemptID: command.attemptID,
          sequence: 1, kind: .started)))
    try await repository.apply(
      .applyGenerationEvent(
        GenerationEvent(
          generationID: command.generationID, attemptID: command.attemptID,
          sequence: 2, kind: .delta(text))))
    try await repository.apply(
      .applyGenerationEvent(
        GenerationEvent(
          generationID: command.generationID, attemptID: command.attemptID,
          sequence: 3, kind: .completed)))
    let page = try await repository.messages(conversationID: conversationID)
    return try XCTUnwrap(page.messages.last?.id)
  }
}

private actor PausedReplyLookupRepository: WorkspaceRepository {
  let base: CoreDataWorkspaceRepository
  private var target: UUID?
  private var shouldPauseDraft = false
  private var reads = 0
  private var isPaused = false
  private var observer: CheckedContinuation<Void, Never>?
  private var continuation: CheckedContinuation<Void, Never>?
  init(base: CoreDataWorkspaceRepository) { self.base = base }
  func pause(_ id: UUID) { target = id }
  func pauseNextDraft() { shouldPauseDraft = true }
  func readCount() -> Int { reads }
  func waitUntilPaused() async {
    if isPaused { return }
    await withCheckedContinuation { observer = $0 }
  }
  func release() {
    continuation?.resume()
    continuation = nil
  }
  func message(id: UUID) async throws -> Message {
    reads += 1
    if id == target {
      target = nil
      isPaused = true
      observer?.resume()
      observer = nil
      await withCheckedContinuation { continuation = $0 }
      isPaused = false
    }
    return try await base.message(id: id)
  }
  func snapshot() async throws -> WorkspaceSnapshot { try await base.snapshot() }
  func apply(_ mutation: WorkspaceMutation, expectedRevision: Int64?) async throws -> Int64 {
    if case .saveDraft = mutation, shouldPauseDraft {
      shouldPauseDraft = false
      isPaused = true
      observer?.resume()
      observer = nil
      await withCheckedContinuation { continuation = $0 }
      isPaused = false
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
}

private actor PausedReplyCredentials: CredentialStore {
  private var values: [String: Data] = [:]
  private var shouldPause = false
  private var isPaused = false
  private var observer: CheckedContinuation<Void, Never>?
  private var continuation: CheckedContinuation<Void, Never>?
  func pauseNextRead() { shouldPause = true }
  func waitUntilPaused() async {
    if isPaused { return }
    await withCheckedContinuation { observer = $0 }
  }
  func release() {
    continuation?.resume()
    continuation = nil
  }
  func read(_ reference: String) async throws -> Data {
    if shouldPause {
      shouldPause = false
      isPaused = true
      observer?.resume()
      observer = nil
      await withCheckedContinuation { continuation = $0 }
      isPaused = false
    }
    guard let value = values[reference] else { throw ProviderError.missingCredential }
    return value
  }
  func write(_ secret: Data, for reference: String) { values[reference] = secret }
  func remove(_ reference: String) { values[reference] = nil }
}
