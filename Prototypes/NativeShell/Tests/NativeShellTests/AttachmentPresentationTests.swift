import Foundation
import WorkspaceCore
import XCTest

@testable import NativeShell

@MainActor
final class AttachmentPresentationTests: XCTestCase {
  func testTextEditFlushAndReopenPreservesAttachmentIdentityAndBytes() async throws {
    let fixture = try await makeFixture(text: "Before")
    let workspace = PreviewWorkspace(seed: false)
    try await workspace.connect(fixture.repository, displayName: "Attachment fixture")

    XCTAssertEqual(workspace.currentDraftAttachmentIDs, [fixture.content.attachment.id])
    workspace.draft = "After"
    try await workspace.flushDrafts()
    workspace.draftSaveTask?.cancel()
    try await fixture.repository.close()

    let reopened = try await CoreDataWorkspaceRepository.open(at: fixture.storeURL)
    addTeardownBlock { try await reopened.close() }
    let restored = PreviewWorkspace(seed: false)
    try await restored.connect(reopened, displayName: "Attachment fixture")

    XCTAssertEqual(restored.draft, "After")
    XCTAssertEqual(restored.currentDraftAttachmentIDs, [fixture.content.attachment.id])
    let reopenedContent = try await reopened.attachmentContent(id: fixture.content.attachment.id)
    XCTAssertEqual(reopenedContent, fixture.content)
  }

  func testAttachmentSendFailureKeepsDraftReferenceAndManagedBytes() async throws {
    let fixture = try await makeFixture(text: "Do not send")
    let credentials = AttachmentCredentialSpy()
    let workspace = PreviewWorkspace(seed: false)
    try await workspace.connect(
      fixture.repository, credentials: credentials, provider: AttachmentFailIfCalledProvider(),
      displayName: "Attachment fixture")

    do {
      _ = try await workspace.submitDraft()
      XCTFail("Expected explicit attachment consent before transmission")
    } catch {
      XCTAssertEqual(error as? ProviderError, .attachmentConsentRequired)
    }

    let credentialReadCount = await credentials.currentReadCount()
    XCTAssertEqual(credentialReadCount, 0)
    XCTAssertEqual(workspace.draft, "Do not send")
    XCTAssertEqual(workspace.currentDraftAttachmentIDs, [fixture.content.attachment.id])
    let saved = try await fixture.repository.snapshot().drafts.first
    XCTAssertEqual(saved?.attachmentIDs, [fixture.content.attachment.id])
    let storedContent = try await fixture.repository.attachmentContent(
      id: fixture.content.attachment.id)
    XCTAssertEqual(storedContent, fixture.content)
  }

  func testTranscriptProjectionAndDisclosureRepresentStoredReferences() async throws {
    let fixture = try await makeFixture(text: "")
    try await fixture.repository.apply(
      .beginGeneration(
        SendCommand(
          conversationID: fixture.conversationID, targetBotID: fixture.botID, text: "",
          attachmentIDs: [fixture.content.attachment.id])))
    let workspace = PreviewWorkspace(seed: false)
    try await workspace.connect(fixture.repository, displayName: "Attachment fixture")
    let message = try XCTUnwrap(workspace.currentMessages.first)

    XCTAssertEqual(message.attachmentIDs, [fixture.content.attachment.id])
    await workspace.beginReply(to: message.id, in: fixture.conversationID)
    XCTAssertEqual(workspace.currentReply?.id, message.id)
    XCTAssertEqual(workspace.currentReply?.excerpt, "1 stored text attachment")
    XCTAssertTrue(workspace.currentReply?.isAvailable == true)
    try await workspace.flushDrafts()
    workspace.draftSaveTask?.cancel()
    try await fixture.repository.close()

    let reopened = try await CoreDataWorkspaceRepository.open(at: fixture.storeURL)
    addTeardownBlock { try await reopened.close() }
    let credentials = AttachmentCredentialSpy()
    let restored = PreviewWorkspace(seed: false)
    try await restored.connect(
      reopened, credentials: credentials, provider: AttachmentFailIfCalledProvider(),
      displayName: "Attachment fixture")
    XCTAssertEqual(restored.currentReply?.id, message.id)
    XCTAssertTrue(restored.currentReply?.isAvailable == true)
    await restored.jumpToReply(messageID: message.id, in: fixture.conversationID)
    XCTAssertEqual(restored.transcriptJumpRequest?.messageID, message.id)

    restored.draft = "Follow up"
    do {
      _ = try await restored.submitDraft()
      XCTFail("Expected explicit consent for attachment-bearing reply context")
    } catch {
      XCTAssertEqual(error as? ProviderError, .attachmentConsentRequired)
    }
    let credentialReadCount = await credentials.currentReadCount()
    XCTAssertEqual(credentialReadCount, 0)
    XCTAssertEqual(restored.draft, "Follow up")
    XCTAssertEqual(restored.currentReply?.id, message.id)
    XCTAssertEqual(AttachmentPresentation.storedCount(1), "1 stored text attachment")
    XCTAssertEqual(AttachmentPresentation.storedCount(2), "2 stored text attachments")
  }

  func testExportStatusReportsExactAttachmentCountAndBytes() {
    let summary = WorkspaceExportSummary(
      botCount: 1, conversationCount: 2, messageCount: 3, draftCount: 1,
      generationCount: 0, routineCount: 0, routineRunCount: 4, providerCount: 1,
      attachmentCount: 2, attachmentBytes: 12_345)

    let status = PreviewWorkspace.workspaceExportStatus(summary)
    XCTAssertTrue(status.contains("2 stored text attachments (12345 bytes)"))
  }

  func testDeletionDisclosureReportsExactDeletedBytesAndPreservedReferences() {
    let plan = BotDeletionPlan(
      botID: UUID(), name: "Fixture", directConversationIDs: [], messageIDs: [],
      draftConversationIDs: [], generationIDs: [], routineIDs: [], affectedGroups: [],
      activeGenerationIDs: [], cancellationConversationIDs: [], attachmentIDs: [UUID(), UUID()],
      attachmentBytes: 99)

    let disclosure = BotDeletionPresentation.attachmentImpact(plan)
    XCTAssertTrue(disclosure.contains("2 stored text attachments (99 bytes)"))
    XCTAssertTrue(disclosure.contains("preserved group history or drafts stay"))
  }

  private func makeFixture(text: String) async throws -> AttachmentFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "AttachmentPresentationTests-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let storeURL = directory.appendingPathComponent("workspace.sqlite")
    let repository = try await CoreDataWorkspaceRepository.open(at: storeURL)
    addTeardownBlock { try? await repository.close() }
    let bot = Bot(name: "Helper")
    let conversationID = UUID()
    try await repository.apply(.createBot(bot, conversationID: conversationID))
    let provider = ProviderConfig(
      name: "Fixture", apiRoot: URL(string: "https://fixture.invalid/v1")!,
      modelID: "fixture-model", credentialReference: "session:attachment-fixture")
    try await repository.apply(.saveProvider(provider))
    let content = try AttachmentContent(
      conversationID: conversationID, originalName: "notes.txt", data: Data("exact bytes".utf8))
    try await repository.apply(
      .saveDraftWithAttachments(
        Draft(conversationID: conversationID, text: text, attachmentIDs: [content.attachment.id]),
        attachments: [content]))
    return AttachmentFixture(
      repository: repository, storeURL: storeURL, botID: bot.id,
      conversationID: conversationID, content: content)
  }
}

private struct AttachmentFixture {
  let repository: CoreDataWorkspaceRepository
  let storeURL: URL
  let botID: UUID
  let conversationID: UUID
  let content: AttachmentContent
}

private actor AttachmentCredentialSpy: CredentialStore {
  private(set) var readCount = 0

  func currentReadCount() -> Int { readCount }

  func read(_ reference: String) async throws -> Data {
    readCount += 1
    return Data("must-not-be-read".utf8)
  }

  func write(_ secret: Data, for reference: String) async throws {}
  func remove(_ reference: String) async throws {}
}

private struct AttachmentFailIfCalledProvider: ChatProvider {
  func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
    XCTFail("Provider must not be called for stored attachments")
    return AsyncThrowingStream { $0.finish() }
  }
}
