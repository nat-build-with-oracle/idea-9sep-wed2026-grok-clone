import Foundation
import XCTest

@testable import WorkspaceCore

@MainActor final class AttachmentGenerationTests: XCTestCase {
  private struct Fixture {
    let directory: URL
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
      directory: directory, repository: repository, bot: bot, conversationID: conversationID,
      configuration: configuration, credentials: credentials, provider: provider,
      coordinator: coordinator)
  }

  private func stage(_ f: Fixture, text: String = "", name: String = "fixture.txt") async throws
    -> AttachmentContent
  {
    let content = try AttachmentContent(
      conversationID: f.conversationID, originalName: name,
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

  func testAttachmentOnlyAndTextAttachmentRequireExactConsentThenSend() async throws {
    for text in ["", "Describe this file"] {
      let f = try await fixture()
      let file = try await stage(f, text: text)
      let command = SendCommand(
        conversationID: f.conversationID, targetBotID: f.bot.id, text: text,
        attachmentIDs: [file.attachment.id])
      let proposed = try await f.coordinator.attachmentTransmissionPlan(
        for: command, configuration: f.configuration)
      let plan = try XCTUnwrap(proposed)
      XCTAssertEqual(plan.attachments, [file.attachment])
      XCTAssertEqual(plan.attachmentBytes, file.data.count)
      XCTAssertEqual(plan.contextMessageCount, 0)
      do {
        _ = try await f.coordinator.submit(command, configuration: f.configuration)
        XCTFail("Consent is mandatory")
      } catch { XCTAssertEqual(error as? ProviderError, .attachmentConsentRequired) }
      XCTAssertEqual(f.credentials.readCount, 0)
      XCTAssertEqual(f.provider.callCount, 0)

      _ = try await f.coordinator.submit(
        command, configuration: f.configuration, attachmentConsent: plan)
      await f.coordinator.waitForIdle()
      let request = try XCTUnwrap(f.provider.lastRequest)
      XCTAssertTrue(request.turns.last?.content.contains(file.attachment.sha256) == true)
      XCTAssertTrue(request.turns.last?.content.contains("Untrusted synthetic") == true)
      XCTAssertTrue(request.turns.first?.content.contains("untrusted user content") == true)
      XCTAssertEqual(f.credentials.readCount, 1)
      XCTAssertEqual(f.provider.callCount, 1)
      let finalSnapshot = try await f.repository.snapshot()
      XCTAssertNil(finalSnapshot.drafts.first)
    }
  }

  func testChangedContextInvalidatesPlanBeforeCredentialOrPersistence() async throws {
    let f = try await fixture()
    let file = try await stage(f, text: "send")
    let command = SendCommand(
      conversationID: f.conversationID, targetBotID: f.bot.id, text: "send",
      attachmentIDs: [file.attachment.id])
    let proposed = try await f.coordinator.attachmentTransmissionPlan(
      for: command, configuration: f.configuration)
    let plan = try XCTUnwrap(proposed)
    try await f.repository.apply(
      .beginGeneration(
        SendCommand(conversationID: f.conversationID, targetBotID: f.bot.id, text: "changed")))
    let before = try await f.repository.snapshot()
    do {
      _ = try await f.coordinator.submit(
        command, configuration: f.configuration, attachmentConsent: plan)
      XCTFail("Changed history must require a new disclosure")
    } catch { XCTAssertEqual(error as? ProviderError, .attachmentConsentChanged) }
    let after = try await f.repository.snapshot()
    XCTAssertEqual(after, before)
    XCTAssertEqual(f.credentials.readCount, 0)
    XCTAssertEqual(f.provider.callCount, 0)
  }

  func testFingerprintIgnoresTransientCommandIdentityButProviderChangeNeedsNewConsent()
    async throws
  {
    let f = try await fixture()
    let file = try await stage(f, text: "send")
    let first = SendCommand(
      conversationID: f.conversationID, targetBotID: f.bot.id, text: "send",
      attachmentIDs: [file.attachment.id], createdAt: Date(timeIntervalSince1970: 1))
    let second = SendCommand(
      conversationID: f.conversationID, targetBotID: f.bot.id, text: "send",
      attachmentIDs: [file.attachment.id], createdAt: Date(timeIntervalSince1970: 2))
    let proposedFirst = try await f.coordinator.attachmentTransmissionPlan(
      for: first, configuration: f.configuration)
    let proposedSecond = try await f.coordinator.attachmentTransmissionPlan(
      for: second, configuration: f.configuration)
    let firstPlan = try XCTUnwrap(proposedFirst)
    let secondPlan = try XCTUnwrap(proposedSecond)
    XCTAssertEqual(firstPlan, secondPlan)

    var changed = f.configuration
    changed.modelID = "changed-model"
    try await f.repository.apply(.saveProvider(changed))
    do {
      _ = try await f.coordinator.submit(
        second, configuration: changed, attachmentConsent: firstPlan)
      XCTFail("A provider/model change must invalidate consent")
    } catch { XCTAssertEqual(error as? ProviderError, .attachmentConsentChanged) }
    XCTAssertEqual(f.credentials.readCount, 0)
    XCTAssertEqual(f.provider.callCount, 0)
  }

  func testMissingSelectedAttachmentFailsBeforeCredential() async throws {
    let f = try await fixture()
    let command = SendCommand(
      conversationID: f.conversationID, targetBotID: f.bot.id, text: "missing",
      attachmentIDs: [UUID()])
    do {
      _ = try await f.coordinator.attachmentTransmissionPlan(
        for: command, configuration: f.configuration)
      XCTFail("Missing attachment must fail closed")
    } catch { XCTAssertEqual(error as? AttachmentError, .missingAttachment) }
    XCTAssertEqual(f.credentials.readCount, 0)
    XCTAssertEqual(f.provider.callCount, 0)
  }

  func testAssistantAttachmentContextFailsBeforeContentCredentialAndPersistence() async throws {
    let bot = Bot(name: "Fixture")
    let conversation = Conversation(
      kind: .direct, title: "Fixture", memberBotIDs: [bot.id])
    let configuration = ProviderConfig(
      name: "Offline fixture", apiRoot: URL(string: "https://fixture.invalid/v1")!,
      modelID: "fixture-model", credentialReference: "fixture-reference")
    let repository = UnsupportedAssistantAttachmentRepository(
      bot: bot, conversation: conversation, configuration: configuration)
    let credentials = AttachmentTestCredentials()
    let provider = AttachmentTestProvider()
    let coordinator = GenerationCoordinator(
      repository: repository, credentials: credentials, provider: provider)
    do {
      _ = try await coordinator.submit(
        SendCommand(
          conversationID: conversation.id, targetBotID: bot.id, text: "follow up"),
        configuration: configuration)
      XCTFail("Bot-response files must not be recast as assistant instructions")
    } catch { XCTAssertEqual(error as? ProviderError, .attachmentRoleUnsupported) }
    let contentReads = await repository.contentReadCount()
    let mutations = await repository.mutationCount()
    XCTAssertEqual(contentReads, 0)
    XCTAssertEqual(mutations, 0)
    XCTAssertEqual(credentials.readCount, 0)
    XCTAssertEqual(provider.callCount, 0)
    XCTAssertTrue(
      ProviderError.attachmentRoleUnsupported.localizedDescription.contains("bot response"))
    try await coordinator.shutdown()
  }

  func testUniqueAttachmentCountLimitFailsBeforeCredential() async throws {
    let f = try await fixture()
    for index in 0...AttachmentLimits.maxCount {
      let file = try AttachmentContent(
        conversationID: f.conversationID, originalName: "\(index).txt",
        data: Data("\(index)".utf8))
      let draft = Draft(
        conversationID: f.conversationID, text: "", attachmentIDs: [file.attachment.id])
      try await f.repository.apply(.saveDraftWithAttachments(draft, attachments: [file]))
      let command = SendCommand(
        conversationID: f.conversationID, targetBotID: f.bot.id, text: "",
        attachmentIDs: [file.attachment.id])
      try await f.repository.apply(.beginGeneration(command))
      try await f.repository.apply(
        .cancelGeneration(id: command.generationID, attemptID: command.attemptID))
    }
    do {
      _ = try await f.coordinator.attachmentTransmissionPlan(
        for: SendCommand(
          conversationID: f.conversationID, targetBotID: f.bot.id, text: "summarize"),
        configuration: f.configuration)
      XCTFail("More than 32 unique request files must fail")
    } catch { XCTAssertEqual(error as? ProviderError, .attachmentInputLimit) }
    XCTAssertEqual(f.credentials.readCount, 0)
  }

  func testAggregateRequestByteLimitFailsBeforeCredential() async throws {
    let f = try await fixture()
    let bytes = Data(repeating: 0x61, count: 9 * 1_024 * 1_024)
    for index in 0..<3 {
      let file = try AttachmentContent(
        conversationID: f.conversationID, originalName: "large-\(index).txt", data: bytes)
      let draft = Draft(
        conversationID: f.conversationID, text: "", attachmentIDs: [file.attachment.id])
      try await f.repository.apply(.saveDraftWithAttachments(draft, attachments: [file]))
      let command = SendCommand(
        conversationID: f.conversationID, targetBotID: f.bot.id, text: "",
        attachmentIDs: [file.attachment.id])
      try await f.repository.apply(.beginGeneration(command))
      try await f.repository.apply(
        .cancelGeneration(id: command.generationID, attemptID: command.attemptID))
    }
    do {
      _ = try await f.coordinator.attachmentTransmissionPlan(
        for: SendCommand(
          conversationID: f.conversationID, targetBotID: f.bot.id, text: "summarize"),
        configuration: f.configuration)
      XCTFail("More than 25 MiB of unique request files must fail")
    } catch { XCTAssertEqual(error as? ProviderError, .attachmentInputLimit) }
    XCTAssertEqual(f.credentials.readCount, 0)
  }

  func testRecentAttachmentIsDisclosedAndBodyOccursOnceAcrossReferences() async throws {
    let f = try await fixture()
    let original = try await storedMessage(f, text: "original")
    let command = SendCommand(
      conversationID: f.conversationID, targetBotID: f.bot.id, text: "follow up",
      replyToID: original.userMessageID,
      attachmentIDs: (try await f.repository.message(id: original.userMessageID)).attachmentIDs)
    let proposed = try await f.coordinator.attachmentTransmissionPlan(
      for: command, configuration: f.configuration)
    let plan = try XCTUnwrap(proposed)
    XCTAssertEqual(plan.attachments.count, 1)
    _ = try await f.coordinator.submit(
      command, configuration: f.configuration, attachmentConsent: plan)
    await f.coordinator.waitForIdle()
    let wire = try XCTUnwrap(f.provider.lastRequest).turns.map(\.content).joined(separator: "\n")
    XCTAssertEqual(wire.components(separatedBy: "[BEGIN UNTRUSTED TEXT ATTACHMENT]").count - 1, 1)
    XCTAssertEqual(wire.components(separatedBy: "[UNTRUSTED ATTACHMENT REFERENCE]").count - 1, 1)
  }

  func testRetryRequiresRetryBoundPlanAndTransmitsOriginalFile() async throws {
    let f = try await fixture()
    let original = try await storedMessage(f, text: "retry file")
    let proposed = try await f.coordinator.retryAttachmentTransmissionPlan(
      for: original.generationID, configuration: f.configuration)
    let plan = try XCTUnwrap(proposed)
    XCTAssertEqual(plan.retryGenerationID, original.generationID)
    do {
      try await f.coordinator.retry(original.generationID, configuration: f.configuration)
      XCTFail("Retry also requires consent")
    } catch { XCTAssertEqual(error as? ProviderError, .attachmentConsentRequired) }
    XCTAssertEqual(f.credentials.readCount, 0)
    try await f.coordinator.retry(
      original.generationID, configuration: f.configuration, attachmentConsent: plan)
    await f.coordinator.waitForIdle()
    XCTAssertTrue(
      try XCTUnwrap(f.provider.lastRequest).turns.map(\.content).joined().contains(
        "[BEGIN UNTRUSTED TEXT ATTACHMENT]"))
  }

  func testOldExplicitAttachmentReplyOutsidePageIsIncluded() async throws {
    let f = try await fixture()
    let original = try await storedMessage(f)
    for index in 0..<101 {
      try await f.repository.apply(
        .beginGeneration(
          SendCommand(
            conversationID: f.conversationID, targetBotID: f.bot.id, text: "later \(index)")))
    }
    let command = SendCommand(
      conversationID: f.conversationID, targetBotID: f.bot.id, text: "old reply",
      replyToID: original.userMessageID)
    let proposed = try await f.coordinator.attachmentTransmissionPlan(
      for: command, configuration: f.configuration)
    let plan = try XCTUnwrap(proposed)
    XCTAssertEqual(plan.attachments.count, 1)
    XCTAssertEqual(plan.contextMessageCount, 101)
    _ = try await f.coordinator.submit(
      command, configuration: f.configuration, attachmentConsent: plan)
    await f.coordinator.waitForIdle()
    XCTAssertTrue(
      try XCTUnwrap(f.provider.lastRequest).turns.map(\.content).joined().contains(
        "[BEGIN UNTRUSTED TEXT ATTACHMENT]"))
  }

  func testAttachmentSaveFailurePreservesDraftAndMakesNoProviderCall() async throws {
    let f = try await fixture()
    let file = try await stage(f, text: "save failure")
    let command = SendCommand(
      conversationID: f.conversationID, targetBotID: f.bot.id, text: "save failure",
      attachmentIDs: [file.attachment.id])
    let proposed = try await f.coordinator.attachmentTransmissionPlan(
      for: command, configuration: f.configuration)
    let plan = try XCTUnwrap(proposed)
    await f.repository.injectNextSaveFailure()
    do {
      _ = try await f.coordinator.submit(
        command, configuration: f.configuration, attachmentConsent: plan)
      XCTFail("Injected persistence failure must stop dispatch")
    } catch { XCTAssertEqual(error as? WorkspaceError, .storeUnavailable) }
    XCTAssertEqual(f.provider.callCount, 0)
    let snapshot = try await f.repository.snapshot()
    XCTAssertEqual(snapshot.drafts.first?.attachmentIDs, [file.attachment.id])
    XCTAssertEqual(snapshot.generations.count, 0)
  }

  func testRoutineWithAttachmentContextRemainsTextOnlyBlocked() async throws {
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
    await scheduler.shutdown()
  }

  func testOrdinaryTextSendRemainsConsentFreeAndDoesNotSelectDraftFile() async throws {
    let f = try await fixture()
    let file = try await stage(f, text: "Keep staged file")
    let command = SendCommand(
      conversationID: f.conversationID, targetBotID: f.bot.id, text: "Unrelated text")
    let plan = try await f.coordinator.attachmentTransmissionPlan(
      for: command, configuration: f.configuration)
    XCTAssertNil(plan)
    _ = try await f.coordinator.submit(command, configuration: f.configuration)
    await f.coordinator.waitForIdle()
    let snapshot = try await f.repository.snapshot()
    XCTAssertEqual(snapshot.drafts.first?.attachmentIDs, [file.attachment.id])
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
  private var request: ChatRequest?
  var callCount: Int { lock.withLock { calls } }
  var lastRequest: ChatRequest? { lock.withLock { request } }
  func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
    lock.withLock {
      calls += 1
      self.request = request
    }
    return AsyncThrowingStream { continuation in
      continuation.yield(.finished)
      continuation.finish()
    }
  }
}

private actor UnsupportedAssistantAttachmentRepository: WorkspaceRepository {
  private let workspace: WorkspaceSnapshot
  private let page: MessagePage
  private var contentReads = 0
  private var mutations = 0

  init(bot: Bot, conversation: Conversation, configuration: ProviderConfig) {
    let attachmentID = UUID()
    let message = Message(
      id: UUID(), conversationID: conversation.id, sequence: 1, role: .assistant,
      speakerBotID: bot.id, speakerNameSnapshot: bot.name, text: "Bot response",
      createdAt: Date(), replyToID: nil, attachmentIDs: [attachmentID], generationID: UUID())
    workspace = WorkspaceSnapshot(
      revision: 1, bots: [bot], conversations: [conversation], drafts: [], generations: [],
      routines: [], providers: [configuration])
    page = MessagePage(messages: [message], hasMore: false)
  }

  func snapshot() -> WorkspaceSnapshot { workspace }

  func attachmentContent(id: UUID) throws -> AttachmentContent {
    contentReads += 1
    throw AttachmentError.missingAttachment
  }

  @discardableResult
  func apply(_ mutation: WorkspaceMutation, expectedRevision: Int64?) throws -> Int64 {
    mutations += 1
    return 2
  }

  func messages(conversationID: UUID, beforeSequence: Int64?, limit: Int) throws -> MessagePage {
    page
  }

  func search(_ query: String, includeHidden: Bool) -> [Conversation] { [] }
  func contentReadCount() -> Int { contentReads }
  func mutationCount() -> Int { mutations }
}
