import Foundation
import XCTest

@testable import WorkspaceCore

@MainActor final class ReplyGenerationTests: XCTestCase {
  private struct Fixture {
    let repository: CoreDataWorkspaceRepository
    let bot: Bot
    let conversationID: UUID
    let configuration: ProviderConfig
  }

  private func fixture() async throws -> Fixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ReplyGenerationTests-\(UUID())")
    let repository = try await CoreDataWorkspaceRepository.open(
      at: directory.appendingPathComponent("workspace.sqlite"))
    addTeardownBlock {
      try await repository.close()
      try? FileManager.default.removeItem(at: directory)
    }
    let bot = Bot(name: "Research Partner", description: "Use the supplied conversation only.")
    let conversationID = UUID()
    let configuration = ProviderConfig(
      name: "Fixture", apiRoot: URL(string: "https://fixture.invalid/v1")!,
      modelID: "fixture-model", credentialReference: "fixture-reference")
    try await repository.apply(.createBot(bot, conversationID: conversationID))
    try await repository.apply(.saveProvider(configuration))
    return Fixture(
      repository: repository, bot: bot, conversationID: conversationID,
      configuration: configuration)
  }

  private func addUserMessage(
    _ text: String, to fixture: Fixture, replyToID: UUID? = nil
  ) async throws -> SendCommand {
    let command = SendCommand(
      conversationID: fixture.conversationID, targetBotID: fixture.bot.id, text: text,
      replyToID: replyToID)
    try await fixture.repository.apply(.beginGeneration(command))
    return command
  }

  private func addAssistantReply(
    _ text: String, to command: SendCommand, repository: CoreDataWorkspaceRepository
  ) async throws -> Message {
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
    try await repository.apply(
      .applyGenerationEvent(
        GenerationEvent(
          generationID: command.generationID, attemptID: command.attemptID, sequence: 3,
          kind: .completed)))
    let page = try await repository.messages(conversationID: command.conversationID)
    return try XCTUnwrap(page.messages.last)
  }

  func testSubmitMarksRecentReplyTargetWithoutDuplicatingItsBody() async throws {
    let fixture = try await fixture()
    let first = try await addUserMessage("Initial question", to: fixture)
    let parent = try await addAssistantReply(
      "Earlier assistant answer", to: first, repository: fixture.repository)
    _ = try await addUserMessage("Intervening message", to: fixture)
    let credentials = CountingCredentials()
    let provider = RecordingProvider()
    let coordinator = GenerationCoordinator(
      repository: fixture.repository, credentials: credentials, provider: provider)

    _ = try await coordinator.submit(
      SendCommand(
        conversationID: fixture.conversationID, targetBotID: fixture.bot.id,
        text: "Follow up on that answer", replyToID: parent.id),
      configuration: fixture.configuration)
    await coordinator.waitForIdle()

    let request = try XCTUnwrap(provider.requests.first)
    XCTAssertEqual(credentials.readCount, 1)
    XCTAssertEqual(
      request.turns.filter { $0.content == parent.text },
      [ChatTurn(role: "assistant", content: parent.text)])
    XCTAssertTrue(
      request.turns[0].content.contains(
        "final user message explicitly replies to conversation context turn 2 (assistant)"))
    XCTAssertEqual(request.turns.last, ChatTurn(role: "user", content: "Follow up on that answer"))
  }

  func testCodexWirePreservesExplicitReplyMarkerRoleAndTextAfterInstructionsMapping()
    async throws
  {
    let fixture = try await fixture()
    let first = try await addUserMessage("Initial question", to: fixture)
    let parent = try await addAssistantReply(
      "Earlier assistant answer", to: first, repository: fixture.repository)
    let provider = RecordingProvider()
    let coordinator = GenerationCoordinator(
      repository: fixture.repository, credentials: CountingCredentials(), provider: provider)
    _ = try await coordinator.submit(
      SendCommand(
        conversationID: fixture.conversationID, targetBotID: fixture.bot.id,
        text: "Follow up on that answer", replyToID: parent.id),
      configuration: fixture.configuration)
    await coordinator.waitForIdle()
    let prepared = try XCTUnwrap(provider.requests.first)
    let auth = try JSONSerialization.data(
      withJSONObject: [
        "auth_mode": "chatgpt",
        "tokens": ["access_token": "synthetic-access", "account_id": "fixture-account"],
      ])
    let codex = ProviderConfig(
      name: "Codex fixture", apiRoot: CodexResponsesProvider.apiRoot,
      modelID: "fixture-model", credentialReference: CodexSessionCredential.makeReference(),
      kind: .codexResponses)
    let mapped = try CodexResponsesProvider.makeRequest(
      ChatRequest(
        provider: codex, turns: prepared.turns,
        credential: try CodexSessionCredential(authFileData: auth).sessionData()))
    let body = try XCTUnwrap(
      JSONSerialization.jsonObject(with: try XCTUnwrap(mapped.httpBody)) as? [String: Any])
    let instructions = try XCTUnwrap(body["instructions"] as? String)
    XCTAssertTrue(
      instructions.contains(
        "final user message explicitly replies to conversation context turn 2 (assistant)"))
    let input = try XCTUnwrap(body["input"] as? [[String: Any]])
    let parentTurns = input.filter { item in
      guard item["role"] as? String == "assistant",
        let content = item["content"] as? [[String: Any]]
      else { return false }
      return content.contains {
        $0["type"] as? String == "output_text" && $0["text"] as? String == parent.text
      }
    }
    XCTAssertEqual(parentTurns.count, 1)
  }

  func testSubmitIncludesAnOldReplyTargetOutsideRecentPageExactlyOnce() async throws {
    let fixture = try await fixture()
    let first = try await addUserMessage("Initial question", to: fixture)
    let parent = try await addAssistantReply(
      "Old assistant answer", to: first, repository: fixture.repository)
    for index in 1...101 { _ = try await addUserMessage("Later \(index)", to: fixture) }
    let provider = RecordingProvider()
    let coordinator = GenerationCoordinator(
      repository: fixture.repository, credentials: CountingCredentials(), provider: provider)

    _ = try await coordinator.submit(
      SendCommand(
        conversationID: fixture.conversationID, targetBotID: fixture.bot.id,
        text: "Reply to the old answer", replyToID: parent.id),
      configuration: fixture.configuration)
    await coordinator.waitForIdle()

    let request = try XCTUnwrap(provider.requests.first)
    XCTAssertEqual(
      request.turns.filter { $0.content == parent.text },
      [ChatTurn(role: "assistant", content: parent.text)])
    XCTAssertEqual(request.turns[1], ChatTurn(role: "assistant", content: parent.text))
    XCTAssertTrue(
      request.turns[0].content.contains(
        "final user message explicitly replies to conversation context turn 1 (assistant)"))
  }

  func testMissingAndCrossConversationRepliesStopBeforeCredentialsAndPersistence() async throws {
    let workspace = try await fixture()
    let otherBot = Bot(name: "Other bot")
    let otherConversationID = UUID()
    try await workspace.repository.apply(
      .createBot(otherBot, conversationID: otherConversationID))
    let crossParent = SendCommand(
      conversationID: otherConversationID, targetBotID: otherBot.id, text: "Other conversation")
    try await workspace.repository.apply(.beginGeneration(crossParent))
    try await workspace.repository.apply(
      .saveDraft(
        Draft(conversationID: workspace.conversationID, text: "Keep this draft")))
    let before = try await workspace.repository.snapshot()
    let credentials = CountingCredentials()
    let provider = RecordingProvider()
    let coordinator = GenerationCoordinator(
      repository: workspace.repository, credentials: credentials, provider: provider)

    for replyToID in [UUID(), crossParent.userMessageID] {
      do {
        _ = try await coordinator.submit(
          SendCommand(
            conversationID: workspace.conversationID, targetBotID: workspace.bot.id,
            text: "Invalid reply", replyToID: replyToID),
          configuration: workspace.configuration)
        XCTFail("Expected invalid reply")
      } catch {
        XCTAssertEqual(error as? WorkspaceError, .invalidDraft)
      }
    }

    XCTAssertEqual(credentials.readCount, 0)
    XCTAssertTrue(provider.requests.isEmpty)
    let after = try await workspace.repository.snapshot()
    XCTAssertEqual(after, before)
  }

  func testBeginGenerationKeepsSameTextDraftWhenReplyChoiceChanged() async throws {
    let fixture = try await fixture()
    let first = try await addUserMessage("First parent", to: fixture)
    let second = try await addUserMessage("Second parent", to: fixture)
    try await fixture.repository.apply(
      .saveDraft(
        Draft(
          conversationID: fixture.conversationID, text: "Same text",
          replyToID: second.userMessageID)))

    try await fixture.repository.apply(
      .beginGeneration(
        SendCommand(
          conversationID: fixture.conversationID, targetBotID: fixture.bot.id,
          text: "Same text", replyToID: first.userMessageID)))

    let snapshot = try await fixture.repository.snapshot()
    let draft = try XCTUnwrap(snapshot.drafts.first)
    XCTAssertEqual(draft.text, "Same text")
    XCTAssertEqual(draft.replyToID, second.userMessageID)
  }

  func testBeginGenerationClearsDraftOnlyWhenTextAndReplyChoiceBothMatch() async throws {
    let fixture = try await fixture()
    let parent = try await addUserMessage("Parent", to: fixture)
    try await fixture.repository.apply(
      .saveDraft(
        Draft(
          conversationID: fixture.conversationID, text: "Matching reply",
          replyToID: parent.userMessageID)))

    try await fixture.repository.apply(
      .beginGeneration(
        SendCommand(
          conversationID: fixture.conversationID, targetBotID: fixture.bot.id,
          text: " Matching reply ", replyToID: parent.userMessageID)))

    let snapshot = try await fixture.repository.snapshot()
    XCTAssertTrue(snapshot.drafts.isEmpty)
  }

  func testEventMessagesCannotBecomeReplyTargets() async throws {
    let fixture = try await fixture()
    let original = try await addUserMessage("Will fail", to: fixture)
    try await fixture.repository.apply(
      .applyGenerationEvent(
        GenerationEvent(
          generationID: original.generationID, attemptID: original.attemptID, sequence: 1,
          kind: .started)))
    try await fixture.repository.apply(
      .applyGenerationEvent(
        GenerationEvent(
          generationID: original.generationID, attemptID: original.attemptID, sequence: 2,
          kind: .failed(.offline))))
    try await fixture.repository.apply(
      .retryGeneration(id: original.generationID, attemptID: UUID()))
    let page = try await fixture.repository.messages(conversationID: fixture.conversationID)
    let event = try XCTUnwrap(page.messages.first(where: { $0.role == .event }))

    do {
      try await fixture.repository.apply(
        .saveDraft(
          Draft(
            conversationID: fixture.conversationID, text: "No event reply",
            replyToID: event.id)))
      XCTFail("Expected invalid event reply")
    } catch {
      XCTAssertEqual(error as? WorkspaceError, .invalidDraft)
    }
    do {
      try await fixture.repository.apply(
        .beginGeneration(
          SendCommand(
            conversationID: fixture.conversationID, targetBotID: fixture.bot.id,
            text: "No event reply", replyToID: event.id)))
      XCTFail("Expected invalid event reply")
    } catch {
      XCTAssertEqual(error as? WorkspaceError, .invalidDraft)
    }
  }

  func testRetryUsesOriginalReplyReferenceEvenWhenParentIsNowOutsideRecentPage() async throws {
    let fixture = try await fixture()
    let parentCommand = try await addUserMessage("Original parent", to: fixture)
    let parent = try await addAssistantReply(
      "Original answer", to: parentCommand, repository: fixture.repository)
    for index in 1...101 { _ = try await addUserMessage("Intervening \(index)", to: fixture) }
    let reply = try await addUserMessage(
      "Question about original answer", to: fixture, replyToID: parent.id)
    try await fixture.repository.apply(
      .applyGenerationEvent(
        GenerationEvent(
          generationID: reply.generationID, attemptID: reply.attemptID, sequence: 1,
          kind: .started)))
    try await fixture.repository.apply(
      .applyGenerationEvent(
        GenerationEvent(
          generationID: reply.generationID, attemptID: reply.attemptID, sequence: 2,
          kind: .failed(.offline))))
    let provider = RecordingProvider()
    let coordinator = GenerationCoordinator(
      repository: fixture.repository, credentials: CountingCredentials(), provider: provider)

    try await coordinator.retry(reply.generationID, configuration: fixture.configuration)
    await coordinator.waitForIdle()

    let request = try XCTUnwrap(provider.requests.first)
    XCTAssertEqual(
      request.turns.filter { $0.content == parent.text },
      [ChatTurn(role: "assistant", content: parent.text)])
    XCTAssertTrue(
      request.turns[0].content.contains(
        "final user message explicitly replies to conversation context turn 1 (assistant)"))
    let persisted = try await fixture.repository.message(id: reply.userMessageID)
    XCTAssertEqual(persisted.replyToID, parent.id)
  }
}

private final class CountingCredentials: CredentialStore, @unchecked Sendable {
  private let lock = NSLock()
  private var reads = 0
  var readCount: Int { lock.withLock { reads } }

  func read(_ reference: String) -> Data {
    lock.withLock { reads += 1 }
    return Data("test-only-sentinel".utf8)
  }
  func write(_ secret: Data, for reference: String) {}
  func remove(_ reference: String) {}
}

private final class RecordingProvider: ChatProvider, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [ChatRequest] = []
  var requests: [ChatRequest] { lock.withLock { recorded } }

  func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
    lock.withLock { recorded.append(request) }
    return AsyncThrowingStream { continuation in
      continuation.yield(.finished)
      continuation.finish()
    }
  }
}
