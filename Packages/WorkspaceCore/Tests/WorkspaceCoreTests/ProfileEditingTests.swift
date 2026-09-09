import XCTest

@testable import WorkspaceCore

@MainActor final class ProfileEditingTests: XCTestCase {
  private let date = Date(timeIntervalSince1970: 1_789_000_000)

  private func temporaryURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "WorkspaceCoreProfileTests-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return directory.appendingPathComponent("workspace.sqlite")
  }

  private func open(_ url: URL? = nil) async throws -> CoreDataWorkspaceRepository {
    let repository = try await CoreDataWorkspaceRepository.open(at: url ?? temporaryURL())
    addTeardownBlock { try await repository.close() }
    return repository
  }

  private func createBot(
    _ repository: CoreDataWorkspaceRepository, name: String,
    providerConfigID: UUID? = nil
  ) async throws -> (bot: Bot, conversationID: UUID) {
    let bot = Bot(name: name, createdAt: date, providerConfigID: providerConfigID)
    let conversationID = UUID()
    try await repository.apply(.createBot(bot, conversationID: conversationID))
    return (bot, conversationID)
  }

  private func assertError(
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

  func testBotProfileValidationUsesCreationRulesAndNormalizesName() throws {
    let profile = try BotProfile(
      name: "  Helper  ", description: "Useful", color: "blue", shape: .drop
    ).validated()
    XCTAssertEqual(profile.name, "Helper")

    for invalid in ["", String(repeating: "x", count: 81)] {
      XCTAssertThrowsError(
        try BotProfile(name: invalid, description: "", color: "green", shape: .circle)
          .validated()
      ) { XCTAssertEqual($0 as? WorkspaceError, .invalidName) }
    }
    XCTAssertThrowsError(
      try BotProfile(
        name: "Helper", description: String(repeating: "x", count: 8_001), color: "green",
        shape: .circle
      ).validated()
    ) { XCTAssertEqual($0 as? WorkspaceError, .invalidDescription) }
    XCTAssertThrowsError(
      try BotProfile(name: "Helper", description: "", color: "chartreuse", shape: .circle)
        .validated()
    ) { XCTAssertEqual($0 as? WorkspaceError, .invalidAvatar) }
  }

  func testGroupProfileValidationNormalizesTitleAndRejectsInvalidMembership() throws {
    let first = UUID()
    let second = UUID()
    let profile = try GroupProfile(title: "  Team  ", memberBotIDs: [second, first]).validated()
    XCTAssertEqual(profile.title, "Team")
    XCTAssertEqual(profile.memberBotIDs, [second, first])

    for members in [[first], [first, first], Array(repeating: UUID(), count: 7)] {
      XCTAssertThrowsError(try GroupProfile(title: "Team", memberBotIDs: members).validated()) {
        XCTAssertEqual($0 as? WorkspaceError, .invalidMembers)
      }
    }
  }

  func testStaleBotProfileIsRejectedWithoutOverwritingWinner() async throws {
    let repository = try await open()
    let (bot, _) = try await createBot(repository, name: "Original")
    let original = BotProfile(bot)
    let winner = BotProfile(name: "Winner", description: "A", color: "blue", shape: .square)
    try await repository.apply(.editBot(id: bot.id, expected: original, replacement: winner))
    let revisionAfterWinner = try await repository.snapshot().revision

    await assertError(.editConflict) {
      try await repository.apply(
        .editBot(
          id: bot.id, expected: original,
          replacement: BotProfile(
            name: "Loser", description: "B", color: "orange", shape: .capsule)))
    }
    let snapshot = try await repository.snapshot()
    XCTAssertEqual(BotProfile(try XCTUnwrap(snapshot.bots.first)), winner)
    XCTAssertEqual(snapshot.revision, revisionAfterWinner)
  }

  func testBotEditPreservesConcurrentVisibilityProviderIdentityAndTranscript() async throws {
    let repository = try await open()
    let provider = ProviderConfig(
      name: "Provider", apiRoot: URL(string: "https://example.com/v1")!, modelID: "model",
      credentialReference: "provider-test")
    try await repository.apply(.saveProvider(provider))
    var (bot, conversationID) = try await createBot(repository, name: "Original")
    let expected = BotProfile(bot)
    try await repository.apply(.setHidden(botID: bot.id, at: date))
    bot.providerConfigID = provider.id
    try await repository.apply(.updateBot(bot))
    let command = SendCommand(
      conversationID: conversationID, targetBotID: bot.id, text: "History", createdAt: date)
    try await repository.apply(.beginGeneration(command))

    let replacement = BotProfile(
      name: "Renamed", description: "New description", color: "violet", shape: .drop)
    try await repository.apply(.editBot(id: bot.id, expected: expected, replacement: replacement))

    let snapshot = try await repository.snapshot()
    let saved = try XCTUnwrap(snapshot.bots.first { $0.id == bot.id })
    XCTAssertEqual(BotProfile(saved), replacement)
    XCTAssertEqual(saved.id, bot.id)
    XCTAssertEqual(saved.createdAt, bot.createdAt)
    XCTAssertEqual(saved.hiddenAt, date)
    XCTAssertEqual(saved.providerConfigID, provider.id)
    XCTAssertEqual(
      snapshot.conversations.first { $0.id == conversationID }?.title, replacement.name)
    let messages = try await repository.messages(conversationID: conversationID)
    XCTAssertEqual(messages.messages.map(\.text), ["History"])
  }

  func testBotEditSaveFailureRollsBackProfileAndDirectTitle() async throws {
    let repository = try await open()
    let (bot, _) = try await createBot(repository, name: "Original")
    let before = try await repository.snapshot()
    await repository.injectNextSaveFailure()

    await assertError(.storeUnavailable) {
      try await repository.apply(
        .editBot(
          id: bot.id, expected: BotProfile(bot),
          replacement: BotProfile(
            name: "Changed", description: "", color: "orange", shape: .capsule)))
    }
    let after = try await repository.snapshot()
    XCTAssertEqual(after, before)
  }

  func testEditedProfilesPreserveIdentitiesAndSequenceAcrossRestart() async throws {
    let url = try temporaryURL()
    let repository = try await open(url)
    let (first, _) = try await createBot(repository, name: "First")
    let (second, _) = try await createBot(repository, name: "Second")
    let group = Conversation(
      kind: .group, title: "Original team", memberBotIDs: [first.id, second.id],
      createdAt: date)
    try await repository.apply(.createGroup(group))
    try await repository.apply(
      .beginGeneration(
        SendCommand(conversationID: group.id, targetBotID: first.id, text: "History")))
    try await repository.apply(.markRead(conversationID: group.id, throughSequence: 1))
    let replacement = GroupProfile(title: "Renamed team", memberBotIDs: [second.id, first.id])
    try await repository.apply(
      .editGroup(id: group.id, expected: GroupProfile(group), replacement: replacement))
    try await repository.close()

    let reopened = try await open(url)
    let reopenedSnapshot = try await reopened.snapshot()
    let saved = try XCTUnwrap(reopenedSnapshot.conversations.first { $0.id == group.id })
    XCTAssertEqual(saved.id, group.id)
    XCTAssertEqual(saved.createdAt, group.createdAt)
    XCTAssertEqual(saved.lastReadSequence, 1)
    XCTAssertEqual(saved.nextSequence, 2)
    XCTAssertEqual(GroupProfile(saved), replacement)
  }

  func testGroupEditRetainsExistingHiddenMembersButCannotAddHiddenOrMissingMembers() async throws {
    let repository = try await open()
    let (first, _) = try await createBot(repository, name: "First")
    let (second, _) = try await createBot(repository, name: "Second")
    let (hiddenNew, _) = try await createBot(repository, name: "Hidden")
    let group = Conversation(
      kind: .group, title: "Team", memberBotIDs: [first.id, second.id], createdAt: date)
    try await repository.apply(.createGroup(group))
    try await repository.apply(.setHidden(botID: second.id, at: date))
    try await repository.apply(.setHidden(botID: hiddenNew.id, at: date))

    let retained = GroupProfile(title: "Still together", memberBotIDs: [second.id, first.id])
    try await repository.apply(
      .editGroup(id: group.id, expected: GroupProfile(group), replacement: retained))

    for members in [[first.id, hiddenNew.id], [first.id, UUID()]] {
      await assertError(.invalidMembers) {
        try await repository.apply(
          .editGroup(
            id: group.id, expected: retained,
            replacement: GroupProfile(title: "Invalid", memberBotIDs: members)))
      }
    }
    let snapshot = try await repository.snapshot()
    XCTAssertEqual(
      GroupProfile(try XCTUnwrap(snapshot.conversations.first { $0.id == group.id })), retained)
  }

  func testStaleGroupProfileAndSaveFailureLeaveTheWinningEditIntact() async throws {
    let repository = try await open()
    let (first, _) = try await createBot(repository, name: "First")
    let (second, _) = try await createBot(repository, name: "Second")
    let (third, _) = try await createBot(repository, name: "Third")
    let group = Conversation(
      kind: .group, title: "Original", memberBotIDs: [first.id, second.id], createdAt: date)
    try await repository.apply(.createGroup(group))
    let original = GroupProfile(group)
    let winner = GroupProfile(title: "Winner", memberBotIDs: [second.id, third.id])
    try await repository.apply(
      .editGroup(id: group.id, expected: original, replacement: winner))

    await assertError(.editConflict) {
      try await repository.apply(
        .editGroup(
          id: group.id, expected: original,
          replacement: GroupProfile(title: "Stale", memberBotIDs: [first.id, third.id])))
    }
    let beforeFailedSave = try await repository.snapshot()
    await repository.injectNextSaveFailure()
    await assertError(.storeUnavailable) {
      try await repository.apply(
        .editGroup(
          id: group.id, expected: winner,
          replacement: GroupProfile(title: "Unsaved", memberBotIDs: [first.id, third.id])))
    }
    let afterFailedSave = try await repository.snapshot()
    XCTAssertEqual(afterFailedSave, beforeFailedSave)
    XCTAssertEqual(
      GroupProfile(
        try XCTUnwrap(afterFailedSave.conversations.first { $0.id == group.id })), winner)
  }

  func testGroupEditAffectsFutureTargetsButNotActiveGenerationOrAttribution() async throws {
    let repository = try await open()
    let (first, _) = try await createBot(repository, name: "First")
    let (second, _) = try await createBot(repository, name: "Second")
    let (third, _) = try await createBot(repository, name: "Third")
    let group = Conversation(
      kind: .group, title: "Team", memberBotIDs: [first.id, second.id, third.id],
      createdAt: date)
    try await repository.apply(.createGroup(group))
    let command = SendCommand(
      conversationID: group.id, targetBotID: first.id, text: "Question", createdAt: date)
    try await repository.apply(.beginGeneration(command))
    try await repository.apply(
      .applyGenerationEvent(
        GenerationEvent(
          generationID: command.generationID, attemptID: command.attemptID, sequence: 1,
          kind: .started, createdAt: date)))
    try await repository.apply(
      .applyGenerationEvent(
        GenerationEvent(
          generationID: command.generationID, attemptID: command.attemptID, sequence: 2,
          kind: .delta("Partial"), createdAt: date)))

    let replacement = GroupProfile(title: "New team", memberBotIDs: [second.id, third.id])
    try await repository.apply(
      .editGroup(id: group.id, expected: GroupProfile(group), replacement: replacement))
    try await repository.apply(
      .applyGenerationEvent(
        GenerationEvent(
          generationID: command.generationID, attemptID: command.attemptID, sequence: 3,
          kind: .completed, createdAt: date)))

    let page = try await repository.messages(conversationID: group.id)
    let assistant = try XCTUnwrap(page.messages.first { $0.role == .assistant })
    XCTAssertEqual(assistant.text, "Partial")
    XCTAssertEqual(assistant.speakerBotID, first.id)
    XCTAssertEqual(assistant.speakerNameSnapshot, "First")
    let snapshot = try await repository.snapshot()
    XCTAssertEqual(
      snapshot.generations.first { $0.id == command.generationID }?.state, .completed)
    await assertError(.invalidMembers) {
      try await repository.apply(
        .beginGeneration(
          SendCommand(conversationID: group.id, targetBotID: first.id, text: "Later")))
    }
  }
}
