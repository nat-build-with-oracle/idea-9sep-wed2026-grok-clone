import CoreData
import XCTest

@testable import WorkspaceCore

@MainActor final class RepositoryTests: XCTestCase {
  private let date = Date(timeIntervalSince1970: 1_789_000_000)

  private func temporaryURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "WorkspaceCoreTests-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return directory.appendingPathComponent("workspace.sqlite")
  }
  private func open(_ url: URL? = nil) async throws -> CoreDataWorkspaceRepository {
    let storeURL = try url ?? temporaryURL()
    let repository = try await CoreDataWorkspaceRepository.open(at: storeURL)
    addTeardownBlock { try await repository.close() }
    return repository
  }
  private func createBot(_ repository: CoreDataWorkspaceRepository, name: String = "Helper")
    async throws -> (Bot, UUID)
  {
    let bot = Bot(name: name, createdAt: date)
    let conversation = UUID()
    try await repository.apply(.createBot(bot, conversationID: conversation))
    return (bot, conversation)
  }
  private func assertError(
    _ expected: WorkspaceError, operation: () async throws -> Void,
    file: StaticString = #filePath, line: UInt = #line
  ) async {
    do {
      try await operation()
      XCTFail("Expected \(expected)", file: file, line: line)
    } catch { XCTAssertEqual(error as? WorkspaceError, expected, file: file, line: line) }
  }

  func testNewStoreIsEmptyAndRevisionZero() async throws {
    let repository = try await open()
    let snapshot = try await repository.snapshot()
    XCTAssertEqual(snapshot.revision, 0)
    XCTAssertTrue(snapshot.bots.isEmpty)
    XCTAssertTrue(snapshot.conversations.isEmpty)
    XCTAssertTrue(snapshot.generations.isEmpty)
  }

  func testBotAndDirectConversationSurviveCloseAndReopen() async throws {
    let url = try temporaryURL()
    let repository = try await open(url)
    let (bot, conversationID) = try await createBot(repository)
    try await repository.close()
    let reopened = try await open(url)
    let snapshot = try await reopened.snapshot()
    XCTAssertEqual(snapshot.bots, [bot])
    XCTAssertEqual(snapshot.conversations.first?.id, conversationID)
    XCTAssertEqual(snapshot.conversations.first?.memberBotIDs, [bot.id])
    XCTAssertNotEqual(bot.id, conversationID)
    XCTAssertEqual(snapshot.revision, 1)
  }

  func testDuplicateCreationCannotCreateAnotherConversation() async throws {
    let repository = try await open()
    let (bot, _) = try await createBot(repository)
    await assertError(.identityConflict) {
      try await repository.apply(.createBot(bot, conversationID: UUID()))
    }
    let snapshot = try await repository.snapshot()
    XCTAssertEqual(snapshot.bots.count, 1)
    XCTAssertEqual(snapshot.conversations.count, 1)
    XCTAssertEqual(snapshot.revision, 1)
  }

  func testBotCannotReuseItsConversationIdentity() async throws {
    let repository = try await open()
    let bot = Bot(name: "Helper")
    await assertError(.identityConflict) {
      try await repository.apply(.createBot(bot, conversationID: bot.id))
    }
    let snapshot = try await repository.snapshot()
    XCTAssertTrue(snapshot.bots.isEmpty)
  }

  func testInvalidBotDescriptionDoesNotCreateGhostRecords() async throws {
    let repository = try await open()
    let bot = Bot(name: "Helper", description: String(repeating: "a", count: 8_001))
    await assertError(.invalidDescription) {
      try await repository.apply(.createBot(bot, conversationID: UUID()))
    }
    let snapshot = try await repository.snapshot()
    XCTAssertEqual(snapshot.revision, 0)
    XCTAssertTrue(snapshot.conversations.isEmpty)
  }

  func testBotEditPersistsNameAndDescriptionAndUpdatesDirectTitle() async throws {
    let url = try temporaryURL()
    let repository = try await open(url)
    var (bot, _) = try await createBot(repository)
    bot.name = "  Renamed  "
    bot.description = "A real description"
    bot.color = "blue"
    try await repository.apply(.updateBot(bot))
    try await repository.close()
    let reopened = try await open(url)
    let snapshot = try await reopened.snapshot()
    XCTAssertEqual(snapshot.bots.first?.name, "Renamed")
    XCTAssertEqual(snapshot.bots.first?.description, "A real description")
    XCTAssertEqual(snapshot.bots.first?.color, "blue")
    XCTAssertEqual(snapshot.conversations.first?.title, "Renamed")
  }

  func testHidingBotKeepsRoutineAndCanBeReversedAfterRestart() async throws {
    let url = try temporaryURL()
    let repository = try await open(url)
    let (bot, _) = try await createBot(repository)
    let routine = Routine(
      ownerBotID: bot.id, name: "Check", prompt: "Summarize updates",
      trigger: .interval(minutes: 180), timezoneID: "Asia/Bangkok")
    try await repository.apply(.saveRoutine(routine))
    try await repository.apply(.setHidden(botID: bot.id, at: date))
    try await repository.close()
    let reopened = try await open(url)
    let hidden = try await reopened.search("", includeHidden: false)
    XCTAssertTrue(hidden.isEmpty)
    let snapshot = try await reopened.snapshot()
    XCTAssertEqual(snapshot.routines, [routine])
    XCTAssertEqual(snapshot.bots.first?.hiddenAt, date)
    try await reopened.apply(.setHidden(botID: bot.id, at: nil))
    let visible = try await reopened.search("", includeHidden: false)
    XCTAssertEqual(visible.count, 1)
  }

  func testGroupRejectsDuplicateAndUnknownMembersAtomically() async throws {
    let repository = try await open()
    let (bot, _) = try await createBot(repository)
    for members in [[bot.id, bot.id], [bot.id, UUID()], [], [bot.id]] {
      let group = Conversation(kind: .group, title: "Team", memberBotIDs: members)
      await assertError(.invalidMembers) { try await repository.apply(.createGroup(group)) }
    }
    let snapshot = try await repository.snapshot()
    XCTAssertEqual(snapshot.conversations.count, 1)
    XCTAssertEqual(snapshot.revision, 1)
  }

  func testGroupCreationAndMemberOrderPersist() async throws {
    let url = try temporaryURL()
    let repository = try await open(url)
    let (first, _) = try await createBot(repository, name: "First")
    let (second, _) = try await createBot(repository, name: "Second")
    let group = Conversation(
      kind: .group, title: "Together", memberBotIDs: [second.id, first.id], createdAt: date)
    try await repository.apply(.createGroup(group))
    try await repository.close()
    let reopened = try await open(url)
    let snapshot = try await reopened.snapshot()
    XCTAssertEqual(snapshot.conversations.first { $0.id == group.id }, group)
  }

  func testHiddenMemberCannotBeAddedToNewGroup() async throws {
    let repository = try await open()
    let (first, _) = try await createBot(repository)
    let (second, _) = try await createBot(repository)
    try await repository.apply(.setHidden(botID: second.id, at: date))
    await assertError(.invalidMembers) {
      try await repository.apply(
        .createGroup(
          Conversation(kind: .group, title: "Team", memberBotIDs: [first.id, second.id])))
    }
  }

  func testDraftsPreserveUnicodeAndRemainConversationScopedAfterRestart() async throws {
    let url = try temporaryURL()
    let repository = try await open(url)
    let (_, first) = try await createBot(repository)
    let (_, second) = try await createBot(repository)
    let draft = Draft(conversationID: first, text: "สวัสดี\n日本語 👩🏽‍💻", updatedAt: date)
    try await repository.apply(.saveDraft(draft))
    try await repository.apply(
      .saveDraft(Draft(conversationID: second, text: "Other", updatedAt: date)))
    try await repository.close()
    let reopened = try await open(url)
    let snapshot = try await reopened.snapshot()
    XCTAssertEqual(snapshot.drafts.first { $0.conversationID == first }, draft)
    XCTAssertEqual(snapshot.drafts.first { $0.conversationID == second }?.text, "Other")
  }

  func testSendAtomicallyPersistsUserGenerationSequenceAndDraftClear() async throws {
    let repository = try await open()
    let (bot, id) = try await createBot(repository)
    try await repository.apply(.saveDraft(Draft(conversationID: id, text: "Question")))
    let command = SendCommand(
      conversationID: id, targetBotID: bot.id, text: "Question", createdAt: date)
    try await repository.apply(.beginGeneration(command))
    let snapshot = try await repository.snapshot()
    let page = try await repository.messages(conversationID: id)
    XCTAssertTrue(snapshot.drafts.isEmpty)
    XCTAssertEqual(snapshot.generations.count, 1)
    XCTAssertEqual(snapshot.generations.first?.state, .queued)
    XCTAssertEqual(snapshot.generations.first?.attemptID, command.attemptID)
    XCTAssertEqual(page.messages.count, 1)
    XCTAssertEqual(page.messages.first?.role, .user)
    XCTAssertEqual(page.messages.first?.id, command.userMessageID)
    XCTAssertEqual(page.messages.first?.sequence, 1)
    XCTAssertEqual(snapshot.conversations.first?.nextSequence, 2)
  }

  func testSaveFailureRollsBackWholeSendAndAllowsSameIDsToRetry() async throws {
    let url = try temporaryURL()
    let repository = try await open(url)
    let (bot, id) = try await createBot(repository)
    try await repository.apply(
      .saveDraft(Draft(conversationID: id, text: "Question", updatedAt: date)))
    let command = SendCommand(conversationID: id, targetBotID: bot.id, text: "Question")
    let before = try await repository.snapshot()
    await repository.injectNextSaveFailure()
    await assertError(.storeUnavailable) { try await repository.apply(.beginGeneration(command)) }
    let after = try await repository.snapshot()
    XCTAssertEqual(after, before)
    try await repository.close()
    let reopened = try await open(url)
    let page = try await reopened.messages(conversationID: id)
    XCTAssertTrue(page.messages.isEmpty)
    try await reopened.apply(.beginGeneration(command))
    let retryPage = try await reopened.messages(conversationID: id)
    XCTAssertEqual(retryPage.messages.map(\.id), [command.userMessageID])
    XCTAssertEqual(retryPage.messages.map(\.sequence), [1])
  }

  func testDuplicateSendCommandDoesNotDuplicateUserMessage() async throws {
    let repository = try await open()
    let (bot, id) = try await createBot(repository)
    let command = SendCommand(conversationID: id, targetBotID: bot.id, text: "Question")
    try await repository.apply(.beginGeneration(command))
    await assertError(.identityConflict) { try await repository.apply(.beginGeneration(command)) }
    let page = try await repository.messages(conversationID: id)
    XCTAssertEqual(page.messages.count, 1)
  }

  func testSendingCapturedTextPreservesANewerDraft() async throws {
    let repository = try await open()
    let (bot, id) = try await createBot(repository)
    let captured = SendCommand(conversationID: id, targetBotID: bot.id, text: "Send this")
    try await repository.apply(
      .saveDraft(Draft(conversationID: id, text: "Next message I started typing")))
    try await repository.apply(.beginGeneration(captured))
    let snapshot = try await repository.snapshot()
    XCTAssertEqual(snapshot.drafts.first?.text, "Next message I started typing")
  }

  func testCrossConversationReplyIsRejectedWithoutClearingDraft() async throws {
    let repository = try await open()
    let (firstBot, first) = try await createBot(repository)
    let (secondBot, second) = try await createBot(repository)
    let original = SendCommand(conversationID: first, targetBotID: firstBot.id, text: "First")
    try await repository.apply(.beginGeneration(original))
    try await repository.apply(.saveDraft(Draft(conversationID: second, text: "Keep")))
    let invalid = SendCommand(
      conversationID: second, targetBotID: secondBot.id, text: "Second",
      replyToID: original.userMessageID)
    await assertError(.invalidDraft) { try await repository.apply(.beginGeneration(invalid)) }
    let snapshot = try await repository.snapshot()
    XCTAssertEqual(snapshot.drafts.first?.text, "Keep")
  }

  func testKeysetPaginationHasNoGapsOrDuplicatesAfterNewMessagesArrive() async throws {
    let repository = try await open()
    let (bot, id) = try await createBot(repository)
    for index in 1...205 {
      try await repository.apply(
        .beginGeneration(
          SendCommand(conversationID: id, targetBotID: bot.id, text: "Message \(index)")))
    }
    let first = try await repository.messages(conversationID: id)
    XCTAssertEqual(first.messages.map(\.sequence), Array(Int64(106)...205))
    XCTAssertTrue(first.hasMore)
    try await repository.apply(
      .beginGeneration(SendCommand(conversationID: id, targetBotID: bot.id, text: "New message")))
    let second = try await repository.messages(
      conversationID: id, beforeSequence: first.beforeSequence, limit: 100)
    let third = try await repository.messages(
      conversationID: id, beforeSequence: second.beforeSequence, limit: 100)
    XCTAssertEqual(second.messages.map(\.sequence), Array(Int64(6)...105))
    XCTAssertEqual(third.messages.map(\.sequence), Array(Int64(1)...5))
    XCTAssertFalse(third.hasMore)
    XCTAssertNil(third.beforeSequence)
  }

  func testConcurrentSendsReceiveUniqueMonotonicSequences() async throws {
    let repository = try await open()
    let (bot, id) = try await createBot(repository)
    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 1...20 {
        group.addTask {
          try await repository.apply(
            .beginGeneration(
              SendCommand(conversationID: id, targetBotID: bot.id, text: "Concurrent \(index)")))
        }
      }
      try await group.waitForAll()
    }
    let page = try await repository.messages(conversationID: id)
    XCTAssertEqual(page.messages.map(\.sequence), Array(Int64(1)...20))
    XCTAssertEqual(Set(page.messages.map(\.id)).count, 20)
  }

  func testStaleRevisionCannotOverwriteNewerEdits() async throws {
    let repository = try await open()
    var (bot, _) = try await createBot(repository)
    bot.name = "Newer"
    try await repository.apply(.updateBot(bot), expectedRevision: 1)
    bot.name = "Stale"
    await assertError(.staleRevision) {
      try await repository.apply(.updateBot(bot), expectedRevision: 1)
    }
    let snapshot = try await repository.snapshot()
    XCTAssertEqual(snapshot.bots.first?.name, "Newer")
  }

  func testSearchMatchesMessageTextCaseAndDiacriticInsensitively() async throws {
    let repository = try await open()
    let (bot, id) = try await createBot(repository, name: "Research")
    try await repository.apply(
      .beginGeneration(SendCommand(conversationID: id, targetBotID: bot.id, text: "Café updates")))
    let result = try await repository.search("CAFE", includeHidden: false)
    XCTAssertEqual(result.map(\.id), [id])
  }

  func testRestartReconciliationInterruptsPendingButKeepsCancelledTerminal() async throws {
    let url = try temporaryURL()
    let repository = try await open(url)
    let (bot, id) = try await createBot(repository)
    let first = SendCommand(conversationID: id, targetBotID: bot.id, text: "Interrupted")
    let second = SendCommand(conversationID: id, targetBotID: bot.id, text: "Cancelled")
    try await repository.apply(.beginGeneration(first))
    try await repository.apply(.beginGeneration(second))
    try await repository.apply(
      .cancelGeneration(id: second.generationID, attemptID: second.attemptID))
    try await repository.close()
    let reopened = try await open(url)
    try await reopened.apply(.interruptPendingGenerations)
    let snapshot = try await reopened.snapshot()
    XCTAssertEqual(snapshot.generations.first { $0.id == first.generationID }?.state, .interrupted)
    XCTAssertEqual(snapshot.generations.first { $0.id == second.generationID }?.state, .cancelled)
    let page = try await reopened.messages(conversationID: id)
    XCTAssertEqual(page.messages.count, 2)
  }

  func testStaleAttemptCannotCancelCurrentGeneration() async throws {
    let repository = try await open()
    let (bot, id) = try await createBot(repository)
    let command = SendCommand(conversationID: id, targetBotID: bot.id, text: "Question")
    try await repository.apply(.beginGeneration(command))
    try await repository.apply(.cancelGeneration(id: command.generationID, attemptID: UUID()))
    let snapshot = try await repository.snapshot()
    XCTAssertEqual(snapshot.generations.first?.state, .queued)
  }

  func testInvalidRoutineTimezoneDoesNotPersist() async throws {
    let repository = try await open()
    let (bot, _) = try await createBot(repository)
    let routine = Routine(
      ownerBotID: bot.id, name: "Check", prompt: "Prompt", trigger: .daily(hour: 9, minute: 0),
      timezoneID: "Not/AZone")
    await assertError(.invalidRoutine) { try await repository.apply(.saveRoutine(routine)) }
    let snapshot = try await repository.snapshot()
    XCTAssertTrue(snapshot.routines.isEmpty)
  }

  func testProviderRejectsUnsafeURLsBeforePersistence() async throws {
    let repository = try await open()
    for url in [
      "http://example.com/v1", "https://user:password@example.com/v1",
      "https://example.com/v1?key=secret", "https://example.com/v1#secret",
    ] {
      let provider = ProviderConfig(
        name: "Provider", apiRoot: try XCTUnwrap(URL(string: url)), modelID: "model",
        credentialReference: "keychain-reference")
      await assertError(.invalidProvider) { try await repository.apply(.saveProvider(provider)) }
    }
    let snapshot = try await repository.snapshot()
    XCTAssertTrue(snapshot.providers.isEmpty)
  }

  func testLoopbackHTTPRequiresExplicitOptIn() async throws {
    let repository = try await open()
    var provider = ProviderConfig(
      name: "Local", apiRoot: try XCTUnwrap(URL(string: "http://127.0.0.1:8080/v1")),
      modelID: "local", credentialReference: "local-ref")
    await assertError(.invalidProvider) { try await repository.apply(.saveProvider(provider)) }
    provider.allowsLoopbackHTTP = true
    try await repository.apply(.saveProvider(provider))
    let snapshot = try await repository.snapshot()
    XCTAssertEqual(snapshot.providers, [provider])
  }

  func testSecondRepositoryOwnerIsRejectedUntilFirstCloses() async throws {
    let url = try temporaryURL()
    let repository = try await open(url)
    await assertError(.storeInUse) { _ = try await CoreDataWorkspaceRepository.open(at: url) }
    try await repository.close()
    let reopened = try await open(url)
    let snapshot = try await reopened.snapshot()
    XCTAssertEqual(snapshot.revision, 0)
  }

  func testCorruptStoreIsNotReplacedWithEmptyWorkspace() async throws {
    let url = try temporaryURL()
    let original = Data("not a database — preserve these bytes".utf8)
    try original.write(to: url)
    await assertError(.invalidStore) { _ = try await CoreDataWorkspaceRepository.open(at: url) }
    XCTAssertEqual(try Data(contentsOf: url), original)
  }

  func testIncompatibleCoreDataModelIsRejectedWithoutReset() async throws {
    let url = try temporaryURL()
    let model = NSManagedObjectModel()
    let entity = NSEntityDescription()
    entity.name = "FutureOnly"
    entity.managedObjectClassName = "NSManagedObject"
    let attribute = NSAttributeDescription()
    attribute.name = "future"
    attribute.attributeType = .stringAttributeType
    entity.properties = [attribute]
    model.entities = [entity]
    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
    let store = try coordinator.addPersistentStore(
      ofType: NSSQLiteStoreType, configurationName: nil, at: url)
    try coordinator.remove(store)
    let original = try Data(contentsOf: url)
    await assertError(.unsupportedSchema) {
      _ = try await CoreDataWorkspaceRepository.open(at: url)
    }
    XCTAssertEqual(try Data(contentsOf: url), original)
  }

  func testClosedStoreRejectsWrites() async throws {
    let repository = try await open()
    try await repository.close()
    await assertError(.storeClosed) {
      try await repository.apply(.createBot(Bot(name: "Too late"), conversationID: UUID()))
    }
  }
}
