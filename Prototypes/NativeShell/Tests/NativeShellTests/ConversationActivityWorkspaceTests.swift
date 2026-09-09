import WorkspaceCore
import XCTest

@testable import NativeShell

@MainActor
final class ConversationActivityWorkspaceTests: XCTestCase {
  func testReadVisibilityDoesNotReuseAutoScrollTolerance() {
    XCTAssertTrue(ConversationReadViewport.bottomIsVisible(600, in: 600))
    XCTAssertTrue(ConversationReadViewport.bottomIsVisible(200, in: 600))
    XCTAssertFalse(ConversationReadViewport.bottomIsVisible(601, in: 600))
    XCTAssertFalse(ConversationReadViewport.bottomIsVisible(649, in: 600))
    XCTAssertFalse(ConversationReadViewport.bottomIsVisible(0, in: 600))
    XCTAssertFalse(ConversationReadViewport.bottomIsVisible(.infinity, in: 600))
    XCTAssertFalse(ConversationReadViewport.bottomIsVisible(100, in: .nan))
  }
  func testUnopenedConversationHasPersistedPreviewDateAndUnreadCount() async throws {
    let fixture = try await makeFixture()
    XCTAssertNil(fixture.workspace.messages[fixture.firstID])
    let conversation = try XCTUnwrap(
      fixture.workspace.conversations.first { $0.id == fixture.firstID })
    XCTAssertEqual(fixture.workspace.sidebarPreview(for: conversation), "First reply สวัสดี")
    XCTAssertNotNil(fixture.workspace.sidebarTimestamp(for: conversation))
    XCTAssertEqual(fixture.workspace.conversationActivity[fixture.firstID]?.unreadAssistantCount, 1)
    XCTAssertEqual(fixture.workspace.lastReadSequences[fixture.firstID], 0)
  }

  func testLoadingSelectionInBackgroundDoesNotMarkRead() async throws {
    let fixture = try await makeFixture()
    try await present(fixture, atBottom: true, foreground: false)
    fixture.workspace.requestVisibleReadReceipt()
    XCTAssertNil(fixture.workspace.readReceiptTask)
    XCTAssertNil(fixture.workspace.visibleReadReceipt)
    let savedMarker0 = try await marker(fixture)
    XCTAssertEqual(savedMarker0, 0)
  }

  func testScrolledBackStaleSequenceAndWrongConversationCannotMarkRead() async throws {
    let fixture = try await makeFixture()
    try await present(fixture, atBottom: false)
    XCTAssertNil(fixture.workspace.visibleReadReceipt)
    let workspace = fixture.workspace
    let last = try XCTUnwrap(workspace.currentMessages.last)
    workspace.readViewport = ConversationReadViewport(
      conversationID: fixture.firstID, latestSequence: 1,
      latestMessageID: last.id, latestMessageTextByteCount: last.text.utf8.count, isAtLatest: true)
    XCTAssertNil(workspace.visibleReadReceipt)
    workspace.readViewport = ConversationReadViewport(
      conversationID: fixture.secondID, latestSequence: last.sequence ?? 0,
      latestMessageID: last.id, latestMessageTextByteCount: last.text.utf8.count, isAtLatest: true)
    XCTAssertNil(workspace.visibleReadReceipt)
    let savedMarker1 = try await marker(fixture)
    XCTAssertEqual(savedMarker1, 0)
  }

  func testForegroundLatestReceiptPersistsWithoutChangingDraftOrOtherChat() async throws {
    let fixture = try await makeFixture()
    try await present(fixture)
    fixture.workspace.draft = "Keep this draft 👩🏽‍💻"
    try await fixture.workspace.flushDrafts()
    fixture.workspace.requestVisibleReadReceipt()
    await settleReadReceipts(fixture.workspace)
    let savedMarker2 = try await marker(fixture)
    XCTAssertEqual(savedMarker2, 2)
    XCTAssertEqual(fixture.workspace.conversationActivity[fixture.firstID]?.unreadAssistantCount, 0)
    XCTAssertEqual(
      fixture.workspace.conversationActivity[fixture.secondID]?.unreadAssistantCount, 1)
    XCTAssertEqual(fixture.workspace.draft, "Keep this draft 👩🏽‍💻")
    try await fixture.workspace.prepareForClose()
    try await fixture.base.close()
    let reopened = try await CoreDataWorkspaceRepository.open(at: fixture.url)
    addTeardownBlock { try await reopened.close() }
    let restored = PreviewWorkspace(seed: false)
    try await restored.connect(reopened, displayName: "Read fixture")
    XCTAssertEqual(restored.lastReadSequences[fixture.firstID], 2)
    XCTAssertEqual(restored.conversationActivity[fixture.firstID]?.unreadAssistantCount, 0)
    XCTAssertEqual(restored.conversationActivity[fixture.secondID]?.unreadAssistantCount, 1)
    XCTAssertEqual(restored.drafts[fixture.firstID], "Keep this draft 👩🏽‍💻")
  }

  func testPickerAndSheetsBlockAutomaticRead() async throws {
    let fixture = try await makeFixture()
    try await present(fixture)
    let workspace = fixture.workspace
    XCTAssertNotNil(workspace.visibleReadReceipt)
    workspace.openPicker()
    XCTAssertNil(workspace.visibleReadReceipt)
    workspace.pickerMode = .closed
    workspace.panel = .templates
    XCTAssertNil(workspace.visibleReadReceipt)
    workspace.panel = nil
    workspace.isAttachingFiles = true
    XCTAssertNil(workspace.visibleReadReceipt)
    workspace.isAttachingFiles = false
    workspace.isLoading = true
    XCTAssertNil(workspace.visibleReadReceipt)
    workspace.isLoading = false
    workspace.isClosing = true
    XCTAssertNil(workspace.visibleReadReceipt)
    workspace.isClosing = false
    XCTAssertNotNil(workspace.visibleReadReceipt)
  }

  func testActiveStreamAndUnrenderedFinalDeltaCannotAdvanceMarker() async throws {
    let fixture = try await makeFixture()
    let command = try await reply(
      fixture.base, conversationID: fixture.firstID, botID: fixture.firstBotID,
      text: "Partial", completed: false)
    try await fixture.workspace.refreshPersistent()
    try await present(fixture)
    XCTAssertNil(fixture.workspace.visibleReadReceipt)
    try await fixture.base.apply(
      .applyGenerationEvent(
        GenerationEvent(
          generationID: command.generationID, attemptID: command.attemptID,
          sequence: 3, kind: .delta(" final สวัสดี"))))
    try await fixture.base.apply(
      .applyGenerationEvent(
        GenerationEvent(
          generationID: command.generationID, attemptID: command.attemptID,
          sequence: 4, kind: .completed)))
    // A terminal snapshot alone is not evidence the final text reached the transcript.
    try await fixture.workspace.refreshPersistent()
    XCTAssertNil(fixture.workspace.visibleReadReceipt)
    try await fixture.workspace.loadMessages(fixture.firstID)
    XCTAssertNil(fixture.workspace.visibleReadReceipt)
    recordViewport(fixture.workspace)
    XCTAssertNotNil(fixture.workspace.visibleReadReceipt)
    fixture.workspace.requestVisibleReadReceipt()
    await settleReadReceipts(fixture.workspace)
    let savedMarker3 = try await marker(fixture)
    XCTAssertEqual(savedMarker3, 4)
  }

  func testFailedReadDoesNotOptimisticallyClearAndExplicitRetrySucceeds() async throws {
    let fixture = try await makeFixture()
    await fixture.gate.failNextRead()
    try await present(fixture)
    fixture.workspace.requestVisibleReadReceipt()
    await settleReadReceipts(fixture.workspace)
    XCTAssertNotNil(fixture.workspace.readStatusError)
    XCTAssertEqual(fixture.workspace.conversationActivity[fixture.firstID]?.unreadAssistantCount, 1)
    let savedMarker4 = try await marker(fixture)
    XCTAssertEqual(savedMarker4, 0)
    fixture.workspace.requestVisibleReadReceipt()
    XCTAssertNil(fixture.workspace.readReceiptTask, "No automatic failure retry loop")
    fixture.workspace.retryReadStatus()
    await settleReadReceipts(fixture.workspace)
    XCTAssertNil(fixture.workspace.readStatusError)
    let savedMarker5 = try await marker(fixture)
    XCTAssertEqual(savedMarker5, 2)
  }

  func testNavigationBeforeTaskSubmissionCancelsUnseenReceipt() async throws {
    let fixture = try await makeFixture()
    try await present(fixture)
    fixture.workspace.requestVisibleReadReceipt()
    // No actor suspension yet: the queued write has not entered the repository.
    fixture.workspace.selectedID = fixture.secondID
    await settleReadReceipts(fixture.workspace)
    let savedMarker6 = try await marker(fixture)
    XCTAssertEqual(savedMarker6, 0)
  }

  func testCommittedReadWithFailedRefreshClearsErrorWhenSnapshotProvesMarker() async throws {
    let fixture = try await makeFixture()
    await fixture.gate.failSnapshotAfterNextRead()
    try await present(fixture)
    fixture.workspace.requestVisibleReadReceipt()
    await settleReadReceipts(fixture.workspace)
    XCTAssertNotNil(fixture.workspace.readStatusError)
    let persisted = try await marker(fixture)
    XCTAssertEqual(persisted, 2)
    try await fixture.workspace.refreshPersistent()
    XCTAssertNil(fixture.workspace.readStatusError)
    XCTAssertNil(fixture.workspace.failedReadReceipt)
    XCTAssertEqual(fixture.workspace.conversationActivity[fixture.firstID]?.unreadAssistantCount, 0)
  }

  func testRetryRefreshesStatusEvenWhenNoReceiptIsEligible() async throws {
    let fixture = try await makeFixture()
    await fixture.gate.failNextRead()
    try await present(fixture)
    fixture.workspace.requestVisibleReadReceipt()
    await settleReadReceipts(fixture.workspace)
    recordViewport(fixture.workspace, atBottom: false)
    fixture.workspace.retryReadStatus()
    await settleReadReceipts(fixture.workspace)
    XCTAssertNil(fixture.workspace.readStatusError)
    XCTAssertEqual(fixture.workspace.conversationActivity[fixture.firstID]?.unreadAssistantCount, 1)
    let persisted = try await marker(fixture)
    XCTAssertEqual(persisted, 0)
  }

  func testReconnectJoinsAcceptedOldWorkspaceReadAndResetsPresentation() async throws {
    let fixture = try await makeFixture()
    await fixture.gate.pauseNextRead()
    try await present(fixture)
    fixture.workspace.requestVisibleReadReceipt()
    await fixture.gate.waitUntilPaused()
    let otherURL = fixture.url.deletingLastPathComponent().appendingPathComponent("other.sqlite")
    let other = try await CoreDataWorkspaceRepository.open(at: otherURL)
    addTeardownBlock { try await other.close() }
    let context = fixture.workspace.replyContextGeneration
    let reconnect = Task {
      try await fixture.workspace.connect(other, displayName: "Other fixture")
    }
    await Task.yield()
    XCTAssertEqual(fixture.workspace.replyContextGeneration, context)
    await fixture.gate.releaseRead()
    try await reconnect.value
    let persisted = try await marker(fixture)
    XCTAssertEqual(persisted, 2)
    XCTAssertGreaterThan(fixture.workspace.replyContextGeneration, context)
    XCTAssertTrue(fixture.workspace.conversationActivity.isEmpty)
    XCTAssertTrue(fixture.workspace.lastReadSequences.isEmpty)
    XCTAssertNil(fixture.workspace.readViewport)
    XCTAssertNil(fixture.workspace.readReceiptTask)
  }

  func testAcceptedReceiptNeverClearsNewerReplyOrDifferentConversation() async throws {
    let fixture = try await makeFixture()
    await fixture.gate.pauseNextRead()
    try await present(fixture)
    fixture.workspace.requestVisibleReadReceipt()
    await fixture.gate.waitUntilPaused()
    fixture.workspace.selectedID = fixture.secondID
    _ = try await reply(
      fixture.base, conversationID: fixture.firstID,
      botID: fixture.firstBotID, text: "Arrived after the captured viewport")
    await fixture.gate.releaseRead()
    await settleReadReceipts(fixture.workspace)
    let savedMarker7 = try await marker(fixture)
    XCTAssertEqual(savedMarker7, 2)
    XCTAssertEqual(fixture.workspace.conversationActivity[fixture.firstID]?.unreadAssistantCount, 1)
    XCTAssertEqual(fixture.workspace.lastReadSequences[fixture.secondID], 0)
    XCTAssertEqual(fixture.workspace.selectedID, fixture.secondID)
  }

  func testOlderSnapshotCannotUndoAcknowledgedActivityAndOldContextIsRejected() async throws {
    let fixture = try await makeFixture()
    let old = try await fixture.base.snapshot()
    try await present(fixture)
    let context = fixture.workspace.replyContextGeneration
    fixture.workspace.requestVisibleReadReceipt()
    await settleReadReceipts(fixture.workspace)
    fixture.workspace.projectConversationActivity(old, context: context)
    XCTAssertEqual(fixture.workspace.lastReadSequences[fixture.firstID], 2)
    fixture.workspace.replyContextGeneration += 1
    fixture.workspace.resetConversationActivity()
    fixture.workspace.projectConversationActivity(old, context: context)
    XCTAssertTrue(fixture.workspace.conversationActivity.isEmpty)
  }

  func testCloseJoinsAcceptedReadBeforeReturning() async throws {
    let fixture = try await makeFixture()
    await fixture.gate.pauseNextRead()
    try await present(fixture)
    fixture.workspace.requestVisibleReadReceipt()
    await fixture.gate.waitUntilPaused()
    let close = Task { try await fixture.workspace.prepareForClose() }
    await Task.yield()
    XCTAssertNotNil(fixture.workspace.readReceiptTask)
    await fixture.gate.releaseRead()
    try await close.value
    XCTAssertNil(fixture.workspace.readReceiptTask)
    let savedMarker8 = try await marker(fixture)
    XCTAssertEqual(savedMarker8, 2)
    XCTAssertNil(fixture.workspace.visibleReadReceipt)
  }

  private struct Fixture {
    let workspace: PreviewWorkspace
    let base: CoreDataWorkspaceRepository
    let gate: ReadGateRepository
    let url: URL
    let firstID: UUID
    let secondID: UUID
    let firstBotID: UUID
  }

  private func makeFixture() async throws -> Fixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "UnreadTests-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("workspace.sqlite")
    let base = try await CoreDataWorkspaceRepository.open(at: url)
    addTeardownBlock { try await base.close() }
    let first = Bot(name: "First", createdAt: Date(timeIntervalSince1970: 100))
    let second = Bot(name: "Second", createdAt: Date(timeIntervalSince1970: 200))
    let firstID = UUID()
    let secondID = UUID()
    try await base.apply(.createBot(first, conversationID: firstID))
    try await base.apply(.createBot(second, conversationID: secondID))
    _ = try await reply(base, conversationID: firstID, botID: first.id, text: "First reply สวัสดี")
    _ = try await reply(base, conversationID: secondID, botID: second.id, text: "Second reply")
    let gate = ReadGateRepository(base: base)
    let workspace = PreviewWorkspace(seed: false)
    workspace.routinePollingEnabled = false
    try await workspace.connect(gate, displayName: "Read fixture")
    return Fixture(
      workspace: workspace, base: base, gate: gate, url: url,
      firstID: firstID, secondID: secondID, firstBotID: first.id)
  }

  private func present(_ fixture: Fixture, atBottom: Bool = true, foreground: Bool = true)
    async throws
  {
    fixture.workspace.selectedID = fixture.firstID
    try await fixture.workspace.loadMessages(fixture.firstID)
    fixture.workspace.workspaceIsForeground = foreground
    recordViewport(fixture.workspace, atBottom: atBottom)
  }

  private func recordViewport(_ workspace: PreviewWorkspace, atBottom: Bool = true) {
    guard let id = workspace.selectedID, let message = workspace.currentMessages.last else {
      return
    }
    workspace.recordReadViewport(
      ConversationReadViewport(
        conversationID: id, latestSequence: message.sequence ?? 0,
        latestMessageID: message.id, latestMessageTextByteCount: message.text.utf8.count,
        isAtLatest: atBottom))
  }

  private func marker(_ fixture: Fixture) async throws -> Int64? {
    try await fixture.base.snapshot().conversations.first { $0.id == fixture.firstID }?
      .lastReadSequence
  }

  private func settleReadReceipts(_ workspace: PreviewWorkspace) async {
    while let task = workspace.readReceiptTask { await task.value }
  }

  @discardableResult private func reply(
    _ repository: CoreDataWorkspaceRepository,
    conversationID: UUID, botID: UUID, text: String, completed: Bool = true
  ) async throws -> SendCommand {
    let command = SendCommand(conversationID: conversationID, targetBotID: botID, text: "Question")
    try await repository.apply(.beginGeneration(command))
    try await repository.apply(
      .applyGenerationEvent(
        GenerationEvent(
          generationID: command.generationID, attemptID: command.attemptID, sequence: 1,
          kind: .started)))
    try await repository.apply(
      .applyGenerationEvent(
        GenerationEvent(
          generationID: command.generationID, attemptID: command.attemptID, sequence: 2,
          kind: .delta(text))))
    if completed {
      try await repository.apply(
        .applyGenerationEvent(
          GenerationEvent(
            generationID: command.generationID, attemptID: command.attemptID, sequence: 3,
            kind: .completed)))
    }
    return command
  }
}

private actor ReadGateRepository: WorkspaceRepository {
  let base: CoreDataWorkspaceRepository
  private var fail = false
  private var failFollowingSnapshot = false
  private var snapshotFailureArmed = false
  private var pause = false
  private var paused = false
  private var observer: CheckedContinuation<Void, Never>?
  private var release: CheckedContinuation<Void, Never>?
  init(base: CoreDataWorkspaceRepository) { self.base = base }
  func failNextRead() { fail = true }
  func failSnapshotAfterNextRead() { failFollowingSnapshot = true }
  func pauseNextRead() { pause = true }
  func waitUntilPaused() async {
    if paused { return }
    await withCheckedContinuation { observer = $0 }
  }
  func releaseRead() {
    release?.resume()
    release = nil
  }
  func snapshot() async throws -> WorkspaceSnapshot {
    if snapshotFailureArmed {
      snapshotFailureArmed = false
      throw WorkspaceError.storeUnavailable
    }
    return try await base.snapshot()
  }
  func apply(_ mutation: WorkspaceMutation, expectedRevision: Int64?) async throws -> Int64 {
    if case .markRead = mutation {
      if fail {
        fail = false
        throw WorkspaceError.storeUnavailable
      }
      if pause {
        pause = false
        await withCheckedContinuation {
          release = $0
          paused = true
          observer?.resume()
          observer = nil
        }
      }
    }
    let revision = try await base.apply(mutation, expectedRevision: expectedRevision)
    if case .markRead = mutation, failFollowingSnapshot {
      failFollowingSnapshot = false
      snapshotFailureArmed = true
    }
    return revision
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
