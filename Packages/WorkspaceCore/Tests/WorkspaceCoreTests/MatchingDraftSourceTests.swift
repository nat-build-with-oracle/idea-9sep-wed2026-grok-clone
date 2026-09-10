import XCTest

@testable import WorkspaceCore

@MainActor final class MatchingDraftSourceTests: XCTestCase {
  private struct Fixture {
    let repository: CoreDataWorkspaceRepository
    let firstBot: Bot
    let secondBot: Bot
    let directConversationID: UUID
    let groupConversationID: UUID
  }

  private func fixture() async throws -> Fixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "MatchingDraftSourceTests-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let repository = try await CoreDataWorkspaceRepository.open(
      at: directory.appendingPathComponent("workspace.sqlite"))
    addTeardownBlock {
      try? await repository.close()
      try? FileManager.default.removeItem(at: directory)
    }
    let firstBot = Bot(name: "Research Partner")
    let directConversationID = UUID()
    try await repository.apply(.createBot(firstBot, conversationID: directConversationID))
    let secondBot = Bot(name: "Risk Reviewer")
    try await repository.apply(.createBot(secondBot, conversationID: UUID()))
    let groupConversationID = UUID()
    try await repository.apply(
      .createGroup(
        Conversation(
          id: groupConversationID, kind: .group, title: "Review board",
          memberBotIDs: [firstBot.id, secondBot.id])))
    return Fixture(
      repository: repository, firstBot: firstBot, secondBot: secondBot,
      directConversationID: directConversationID, groupConversationID: groupConversationID)
  }

  func testSingleSendStoresSanitizedBodyAndClearsExactCanonicalMentionSource() async throws {
    let fixture = try await fixture()
    let source = "@\"Research Partner\"   Summarize this"
    try await fixture.repository.apply(
      .saveDraft(Draft(conversationID: fixture.directConversationID, text: source)))
    let command = SendCommand(
      conversationID: fixture.directConversationID, targetBotID: fixture.firstBot.id,
      text: "Summarize this", expectedDraftText: source)

    try await fixture.repository.apply(.beginGeneration(command))

    let page = try await fixture.repository.messages(
      conversationID: fixture.directConversationID)
    let snapshot = try await fixture.repository.snapshot()
    XCTAssertEqual(page.messages.map(\.text), ["Summarize this"])
    XCTAssertFalse(snapshot.drafts.contains { $0.conversationID == fixture.directConversationID })
  }

  func testRoundStoresSanitizedBodyAndClearsExactCanonicalMentionSource() async throws {
    let fixture = try await fixture()
    let source = "@\"Risk Reviewer\" @\"Research Partner\"  Compare risks"
    try await fixture.repository.apply(
      .saveDraft(Draft(conversationID: fixture.groupConversationID, text: source)))
    let command = SendRoundCommand(
      conversationID: fixture.groupConversationID,
      targets: [fixture.secondBot, fixture.firstBot].map { .init(targetBotID: $0.id) },
      text: "Compare risks", expectedDraftText: source)

    try await fixture.repository.apply(.beginGenerationRound(command))

    let page = try await fixture.repository.messages(conversationID: fixture.groupConversationID)
    let snapshot = try await fixture.repository.snapshot()
    XCTAssertEqual(page.messages.map(\.text), ["Compare risks"])
    XCTAssertFalse(snapshot.drafts.contains { $0.conversationID == fixture.groupConversationID })
  }

  func testSingleSendKeepsNewerRawDraftEvenWhenSanitizedBodyMatches() async throws {
    let fixture = try await fixture()
    let captured = "@\"Research Partner\" Summarize this"
    let newer = "@\"Research Partner\" Summarize this and cite sources"
    try await fixture.repository.apply(
      .saveDraft(Draft(conversationID: fixture.directConversationID, text: newer)))
    let command = SendCommand(
      conversationID: fixture.directConversationID, targetBotID: fixture.firstBot.id,
      text: "Summarize this", expectedDraftText: captured)

    try await fixture.repository.apply(.beginGeneration(command))

    let snapshot = try await fixture.repository.snapshot()
    XCTAssertEqual(
      snapshot.drafts.first { $0.conversationID == fixture.directConversationID }?.text, newer)
  }

  func testRoundKeepsNewerRawDraftEvenWhenSanitizedBodyMatches() async throws {
    let fixture = try await fixture()
    let captured = "@\"Research Partner\" @\"Risk Reviewer\" Compare"
    let newer = "@\"Research Partner\" @\"Risk Reviewer\" Compare with examples"
    try await fixture.repository.apply(
      .saveDraft(Draft(conversationID: fixture.groupConversationID, text: newer)))
    let command = SendRoundCommand(
      conversationID: fixture.groupConversationID,
      targets: [fixture.firstBot, fixture.secondBot].map { .init(targetBotID: $0.id) },
      text: "Compare", expectedDraftText: captured)

    try await fixture.repository.apply(.beginGenerationRound(command))

    let snapshot = try await fixture.repository.snapshot()
    XCTAssertEqual(
      snapshot.drafts.first { $0.conversationID == fixture.groupConversationID }?.text, newer)
  }

  func testLegacyCommandWithoutSourceStillClearsTrimEquivalentDraft() async throws {
    let fixture = try await fixture()
    try await fixture.repository.apply(
      .saveDraft(
        Draft(conversationID: fixture.directConversationID, text: "  Ordinary question\n")))
    let command = SendCommand(
      conversationID: fixture.directConversationID, targetBotID: fixture.firstBot.id,
      text: "Ordinary question")

    try await fixture.repository.apply(.beginGeneration(command))

    let snapshot = try await fixture.repository.snapshot()
    XCTAssertFalse(snapshot.drafts.contains { $0.conversationID == fixture.directConversationID })
  }
}
