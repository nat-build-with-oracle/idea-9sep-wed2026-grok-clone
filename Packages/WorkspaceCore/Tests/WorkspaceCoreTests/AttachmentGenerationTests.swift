import Foundation
import XCTest

@testable import WorkspaceCore

/// The storage milestone must not silently drop files or widen existing routine consent.
@MainActor final class AttachmentGenerationTests: XCTestCase {
  private struct Fixture {
    let repository: CoreDataWorkspaceRepository
    let bot: Bot
    let conversationID: UUID
    let configuration: ProviderConfig
    let credentials: AttachmentTestCredentials
    let provider: AttachmentTestProvider
    let coordinator: GenerationCoordinator
  }

  private func fixture() async throws -> Fixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "AttachmentGenerationTests-\(UUID())")
    let repository = try await CoreDataWorkspaceRepository.open(
      at: directory.appendingPathComponent("workspace.sqlite"))
    let bot = Bot(name: "Attachment fixture")
    let conversationID = UUID()
    let configuration = ProviderConfig(
      name: "Offline fixture", apiRoot: URL(string: "https://fixture.invalid/v1")!,
      modelID: "fixture-model", credentialReference: "fixture-reference")
    try await repository.apply(.createBot(bot, conversationID: conversationID))
    try await repository.apply(.saveProvider(configuration))
    let credentials = AttachmentTestCredentials()
    let provider = AttachmentTestProvider()
    let coordinator = GenerationCoordinator(
      repository: repository, credentials: credentials, provider: provider)
    addTeardownBlock {
      try? await coordinator.shutdown()
      try await repository.close()
      try? FileManager.default.removeItem(at: directory)
    }
    return Fixture(
      repository: repository, bot: bot, conversationID: conversationID,
      configuration: configuration, credentials: credentials, provider: provider,
      coordinator: coordinator)
  }

  private func stage(_ f: Fixture, text: String = "") async throws -> AttachmentContent {
    let content = try AttachmentContent(
      conversationID: f.conversationID, originalName: "fixture.txt",
      data: Data("Untrusted synthetic attachment content\n".utf8))
    try await f.repository.apply(
      .saveDraftWithAttachments(
        Draft(conversationID: f.conversationID, text: text, attachmentIDs: [content.attachment.id]),
        attachments: [content]))
    return content
  }

  private func storedMessage(_ f: Fixture, text: String = "") async throws -> SendCommand {
    let file = try await stage(f, text: text)
    let command = SendCommand(
      conversationID: f.conversationID, targetBotID: f.bot.id, text: text,
      attachmentIDs: [file.attachment.id])
    try await f.repository.apply(.beginGeneration(command))
    try await f.repository.apply(
      .cancelGeneration(id: command.generationID, attemptID: command.attemptID))
    return command
  }

  private func assertNoEffects(_ f: Fixture, before: WorkspaceSnapshot) async throws {
    await f.coordinator.waitForIdle()
    let after = try await f.repository.snapshot()
    XCTAssertEqual(after, before)
    XCTAssertEqual(f.credentials.readCount, 0)
    XCTAssertEqual(f.provider.callCount, 0)
  }

  func testNewAttachmentAndAttachmentOnlySendFailBeforeCredentialsAndPreserveDraft() async throws {
    for text in ["", "Describe this file"] {
      let f = try await fixture()
      let file = try await stage(f, text: text)
      let before = try await f.repository.snapshot()
      do {
        _ = try await f.coordinator.submit(
          SendCommand(
            conversationID: f.conversationID, targetBotID: f.bot.id, text: text,
            attachmentIDs: [file.attachment.id]), configuration: f.configuration)
        XCTFail("Attachment transmission requires the separate disclosure implementation")
      } catch {
        XCTAssertEqual(error as? ProviderError, .attachmentTransmissionUnavailable)
      }
      try await assertNoEffects(f, before: before)
      let retained = try await f.repository.attachmentContent(id: file.attachment.id)
      XCTAssertEqual(retained, file)
    }
  }

  func testUnknownSelectedAttachmentFailsClosedWithoutCredentials() async throws {
    let f = try await fixture()
    let before = try await f.repository.snapshot()
    do {
      _ = try await f.coordinator.submit(
        SendCommand(
          conversationID: f.conversationID, targetBotID: f.bot.id, text: "Unknown file",
          attachmentIDs: [UUID()]), configuration: f.configuration)
      XCTFail("Unknown files must not be ignored")
    } catch { XCTAssertEqual(error as? ProviderError, .attachmentTransmissionUnavailable) }
    try await assertNoEffects(f, before: before)
  }

  func testRecentAttachmentContextCannotBeSilentlyOmittedIncludingEmptyMessageText() async throws {
    for text in ["", "Context with attachment"] {
      let f = try await fixture()
      _ = try await storedMessage(f, text: text)
      let before = try await f.repository.snapshot()
      do {
        _ = try await f.coordinator.submit(
          SendCommand(
            conversationID: f.conversationID, targetBotID: f.bot.id, text: "Follow up"),
          configuration: f.configuration)
        XCTFail("Stored context files require disclosure too")
      } catch { XCTAssertEqual(error as? ProviderError, .attachmentTransmissionUnavailable) }
      try await assertNoEffects(f, before: before)
    }
  }

  func testOldExplicitAttachmentOnlyReplyOutsideRecentPageFailsBeforeCredentials() async throws {
    let f = try await fixture()
    let original = try await storedMessage(f)
    for index in 0..<101 {
      try await f.repository.apply(
        .beginGeneration(
          SendCommand(
            conversationID: f.conversationID, targetBotID: f.bot.id, text: "Later \(index)")))
    }
    let page = try await f.repository.messages(conversationID: f.conversationID)
    XCTAssertFalse(page.messages.contains { $0.id == original.userMessageID })
    let before = try await f.repository.snapshot()
    do {
      _ = try await f.coordinator.submit(
        SendCommand(
          conversationID: f.conversationID, targetBotID: f.bot.id, text: "Reply to old file",
          replyToID: original.userMessageID), configuration: f.configuration)
      XCTFail("Old explicit file replies must not bypass the disclosure boundary")
    } catch { XCTAssertEqual(error as? ProviderError, .attachmentTransmissionUnavailable) }
    try await assertNoEffects(f, before: before)
  }

  func testRetryOriginalAttachmentMessageFailsWithoutNewAttemptOrCredentialRead() async throws {
    let f = try await fixture()
    let original = try await storedMessage(f)
    let before = try await f.repository.snapshot()
    do {
      try await f.coordinator.retry(original.generationID, configuration: f.configuration)
      XCTFail("Retry must not omit original attachments")
    } catch { XCTAssertEqual(error as? ProviderError, .attachmentTransmissionUnavailable) }
    try await assertNoEffects(f, before: before)
  }

  func testRoutineWithAttachmentContextRecordsBlockedWithoutSendingOrReadingCredential()
    async throws
  {
    let f = try await fixture()
    _ = try await storedMessage(f)
    let routine = Routine(
      ownerBotID: f.bot.id, name: "Existing consent", prompt: "Summarize context",
      trigger: .interval(minutes: 5), timezoneID: "UTC", enabled: false,
      providerBinding: RoutineProviderBinding(f.configuration), scheduleID: UUID())
    try await f.repository.apply(.createRoutine(routine))
    let scheduler = RoutineScheduler(repository: f.repository, coordinator: f.coordinator)
    let id = try await scheduler.runNow(routineID: routine.id, expected: routine)
    let run = try await f.repository.routineRun(id: id)
    XCTAssertEqual(run.status, .blocked)
    XCTAssertEqual(run.error, .attachmentTransmissionUnavailable)
    XCTAssertEqual(f.credentials.readCount, 0)
    XCTAssertEqual(f.provider.callCount, 0)
    let snapshot = try await f.repository.snapshot()
    XCTAssertEqual(snapshot.generations.count, 1)
    let messages = try await f.repository.messages(conversationID: f.conversationID)
    XCTAssertEqual(messages.messages.count, 1)
    await scheduler.shutdown()
  }

  func testOrdinaryTextSendStillWorksWithoutTransmittingUnselectedDraftAttachment() async throws {
    let f = try await fixture()
    let file = try await stage(f, text: "Keep staged file")
    _ = try await f.coordinator.submit(
      SendCommand(conversationID: f.conversationID, targetBotID: f.bot.id, text: "Unrelated text"),
      configuration: f.configuration)
    await f.coordinator.waitForIdle()
    XCTAssertEqual(f.credentials.readCount, 1)
    XCTAssertEqual(f.provider.callCount, 1)
    let snapshot = try await f.repository.snapshot()
    XCTAssertEqual(snapshot.drafts.first?.attachmentIDs, [file.attachment.id])
    XCTAssertEqual(snapshot.drafts.first?.text, "Keep staged file")
  }
}

private final class AttachmentTestCredentials: CredentialStore, @unchecked Sendable {
  private let lock = NSLock()
  private var reads = 0
  var readCount: Int { lock.withLock { reads } }
  func read(_ reference: String) -> Data {
    lock.withLock { reads += 1 }
    return Data("fixture-only-key".utf8)
  }
  func write(_ secret: Data, for reference: String) {}
  func remove(_ reference: String) {}
}

private final class AttachmentTestProvider: ChatProvider, @unchecked Sendable {
  private let lock = NSLock()
  private var calls = 0
  var callCount: Int { lock.withLock { calls } }
  func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
    lock.withLock { calls += 1 }
    return AsyncThrowingStream { continuation in
      continuation.yield(.finished)
      continuation.finish()
    }
  }
}
