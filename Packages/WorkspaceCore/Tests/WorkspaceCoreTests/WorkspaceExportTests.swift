import Foundation
import XCTest

@testable import WorkspaceCore

@MainActor final class WorkspaceExportTests: XCTestCase {
  private let date = Date(timeIntervalSince1970: 1_789_000_000)

  private func open() async throws -> CoreDataWorkspaceRepository {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "WorkspaceExportTests-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let repository = try await CoreDataWorkspaceRepository.open(
      at: directory.appendingPathComponent("workspace.sqlite"))
    addTeardownBlock {
      try await repository.close()
      try? FileManager.default.removeItem(at: directory)
    }
    return repository
  }

  func testExportIncludesCompleteTextWorkspaceAndRedactsCredentialReference() async throws {
    let repository = try await open()
    let credentialSentinel = "SECRET-CREDENTIAL-REFERENCE-MUST-NOT-EXPORT"
    let provider = ProviderConfig(
      name: "Local router", apiRoot: URL(string: "http://127.0.0.1:20128/v1")!,
      modelID: "glm/glm-5.3", credentialReference: credentialSentinel,
      allowsLoopbackHTTP: true)
    try await repository.apply(.saveProvider(provider))
    let first = Bot(
      name: "First", description: "Lead", color: "blue", shape: .square,
      createdAt: date, providerConfigID: provider.id)
    let second = Bot(name: "Second", createdAt: date.addingTimeInterval(1))
    let firstConversation = UUID()
    let secondConversation = UUID()
    try await repository.apply(.createBot(first, conversationID: firstConversation))
    try await repository.apply(.createBot(second, conversationID: secondConversation))
    let group = Conversation(
      kind: .group, title: "Project", memberBotIDs: [second.id, first.id], createdAt: date)
    try await repository.apply(.createGroup(group))
    try await repository.apply(.setHidden(botID: second.id, at: date))

    let original = SendCommand(
      conversationID: firstConversation, targetBotID: first.id, text: "Original",
      createdAt: date)
    try await repository.apply(.beginGeneration(original))
    try await repository.apply(
      .applyGenerationEvent(
        GenerationEvent(
          generationID: original.generationID, attemptID: original.attemptID, sequence: 1,
          kind: .started, createdAt: date)))
    try await repository.apply(
      .applyGenerationEvent(
        GenerationEvent(
          generationID: original.generationID, attemptID: original.attemptID, sequence: 2,
          kind: .delta("Partial reply"), createdAt: date)))
    try await repository.apply(
      .saveDraft(
        Draft(
          conversationID: firstConversation, text: "Reply later",
          replyToID: original.userMessageID, updatedAt: date)))
    let routine = Routine(
      ownerBotID: first.id, name: "Daily brief", prompt: "Summarize updates",
      trigger: .daily(hour: 9, minute: 30), timezoneID: "Asia/Bangkok", enabled: true,
      nextRunAt: date.addingTimeInterval(3_600))
    try await repository.apply(.saveRoutine(routine))

    for index in 1...105 {
      try await repository.apply(
        .beginGeneration(
          SendCommand(
            conversationID: group.id, targetBotID: first.id, text: "Group \(index)",
            replyToID: nil, createdAt: date.addingTimeInterval(Double(index)))))
    }

    let document = try await repository.exportSnapshot()
    XCTAssertEqual(document.formatVersion, 1)
    XCTAssertEqual(document.sourceSchemaVersion, 1)
    XCTAssertEqual(document.bots.count, 2)
    XCTAssertEqual(document.bots.first { $0.id == second.id }?.hiddenAt, date)
    XCTAssertEqual(
      document.conversations.first { $0.id == group.id }?.memberBotIDs, [second.id, first.id])
    XCTAssertEqual(document.messages.count, 107)
    XCTAssertEqual(document.messages.filter { $0.conversationID == group.id }.count, 105)
    XCTAssertEqual(document.messages.first { $0.role == .assistant }?.text, "Partial reply")
    XCTAssertEqual(document.drafts.first?.replyToID, original.userMessageID)
    XCTAssertEqual(document.generations.count, 106)
    XCTAssertEqual(document.routines, [routine])
    XCTAssertEqual(document.providers, [WorkspaceExportProvider(provider)])
    XCTAssertEqual(document.summary.messageCount, 107)
    XCTAssertEqual(document.summary.providerCount, 1)

    let data = try document.encoded()
    let json = try XCTUnwrap(String(data: data, encoding: .utf8))
    XCTAssertFalse(json.contains(credentialSentinel))
    XCTAssertFalse(json.contains("credentialReference"))
    XCTAssertFalse(json.contains("workspace.sqlite"))
    XCTAssertTrue(
      json.contains("810692800"), "Dates must retain exact Foundation reference-date seconds")
  }

  func testEncodingIsDeterministicSortedAndRoundTrips() async throws {
    let repository = try await open()
    let higher = Bot(
      id: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!, name: "Last",
      createdAt: date)
    let lower = Bot(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "First",
      createdAt: date)
    try await repository.apply(.createBot(higher, conversationID: UUID()))
    try await repository.apply(.createBot(lower, conversationID: UUID()))
    let document = try await repository.exportSnapshot()

    XCTAssertEqual(document.bots.map(\.id), [lower.id, higher.id])
    let first = try document.encoded()
    XCTAssertEqual(first, try document.encoded())
    let decoder = JSONDecoder()
    let decoded = try decoder.decode(WorkspaceExportDocument.self, from: first)
    XCTAssertEqual(decoded, document)
    XCTAssertEqual(try decoded.encoded(), first)
  }

  func testExportRejectsUnsupportedAttachmentsAndByteBoundWithoutTruncation() async throws {
    let message = Message(
      id: UUID(), conversationID: UUID(), sequence: 1, role: .user, speakerBotID: nil,
      speakerNameSnapshot: nil, text: "Has file", createdAt: date, replyToID: nil,
      attachmentIDs: [UUID()], generationID: nil)
    XCTAssertThrowsError(
      try WorkspaceExportDocument(
        exportedAt: date, revision: 1, bots: [], conversations: [], messages: [message],
        drafts: [], generations: [], routines: [], providers: [])
    ) { XCTAssertEqual($0 as? WorkspaceExportError, .unsupportedAttachments) }
    let draft = Draft(conversationID: UUID(), text: "Staged", attachmentIDs: [UUID()])
    XCTAssertThrowsError(
      try WorkspaceExportDocument(
        exportedAt: date, revision: 1, bots: [], conversations: [], messages: [],
        drafts: [draft], generations: [], routines: [], providers: [])
    ) { XCTAssertEqual($0 as? WorkspaceExportError, .unsupportedAttachments) }

    let document = try WorkspaceExportDocument(
      exportedAt: date, revision: 0, bots: [], conversations: [], messages: [], drafts: [],
      generations: [], routines: [], providers: [])
    XCTAssertThrowsError(try document.encoded(maxBytes: 0)) {
      XCTAssertEqual($0 as? WorkspaceExportError, .invalidByteLimit)
    }
    XCTAssertThrowsError(try document.encoded(maxBytes: 1)) { error in
      guard case .exceedsByteLimit(let limit, let actual) = error as? WorkspaceExportError else {
        return XCTFail("Expected exceedsByteLimit, got \(error)")
      }
      XCTAssertEqual(limit, 1)
      XCTAssertGreaterThan(actual, 1)
    }
  }

  func testAtomicExportRevisionMatchesConcurrentMessageSet() async throws {
    let repository = try await open()
    let bot = Bot(name: "Concurrent", createdAt: date)
    let conversationID = UUID()
    try await repository.apply(.createBot(bot, conversationID: conversationID))

    async let writes: Void = withThrowingTaskGroup(of: Void.self) { group in
      for index in 1...40 {
        group.addTask {
          try await repository.apply(
            .beginGeneration(
              SendCommand(
                conversationID: conversationID, targetBotID: bot.id, text: "Message \(index)")))
        }
      }
      try await group.waitForAll()
    }
    let document = try await repository.exportSnapshot()
    try await writes

    XCTAssertEqual(document.revision, Int64(document.messages.count + 1))
    XCTAssertEqual(document.messages.count, document.generations.count)
    XCTAssertEqual(document.conversations.first?.nextSequence, Int64(document.messages.count + 1))
  }

  func testRepositoryDefaultExplicitlyRejectsUnsupportedExport() async throws {
    let repository: any WorkspaceRepository = UnsupportedExportRepository()
    do {
      _ = try await repository.exportSnapshot()
      XCTFail("Expected unsupported export")
    } catch {
      XCTAssertEqual(error as? WorkspaceExportError, .unsupportedRepository)
    }
  }
}

private struct UnsupportedExportRepository: WorkspaceRepository {
  func snapshot() async throws -> WorkspaceSnapshot { throw WorkspaceError.storeUnavailable }
  func apply(_ mutation: WorkspaceMutation, expectedRevision: Int64?) async throws -> Int64 {
    throw WorkspaceError.storeUnavailable
  }
  func messages(conversationID: UUID, beforeSequence: Int64?, limit: Int) async throws
    -> MessagePage
  { throw WorkspaceError.storeUnavailable }
  func search(_ query: String, includeHidden: Bool) async throws -> [Conversation] {
    throw WorkspaceError.storeUnavailable
  }
}
