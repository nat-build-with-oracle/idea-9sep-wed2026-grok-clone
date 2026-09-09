import CoreData
import XCTest

@testable import WorkspaceCore

@MainActor final class ConversationActivityTests: XCTestCase {
  private func temporaryURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ConversationActivityTests-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return directory.appendingPathComponent("workspace.sqlite")
  }

  private func makeStore(conversations: [Conversation], messages: [Message]) throws -> URL {
    let url = try temporaryURL()
    let coordinator = NSPersistentStoreCoordinator(
      managedObjectModel: CoreDataWorkspaceRepository.modelV4())
    let store = try coordinator.addPersistentStore(
      ofType: NSSQLiteStoreType, configurationName: nil, at: url)
    let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
    context.persistentStoreCoordinator = coordinator
    try context.performAndWait {
      let metadata = NSEntityDescription.insertNewObject(forEntityName: "Metadata", into: context)
      metadata.setValue("workspace", forKey: "id")
      metadata.setValue(Int64(4), forKey: "schemaVersion")
      metadata.setValue(Int64(0), forKey: "revision")
      for conversation in conversations {
        let row = NSEntityDescription.insertNewObject(
          forEntityName: "Conversation", into: context)
        row.setValue(conversation.id.uuidString, forKey: "id")
        row.setValue(try JSONEncoder().encode(conversation), forKey: "payload")
      }
      for message in messages {
        let row = NSEntityDescription.insertNewObject(forEntityName: "Message", into: context)
        row.setValue(message.id.uuidString, forKey: "id")
        row.setValue(try JSONEncoder().encode(message), forKey: "payload")
        row.setValue(message.conversationID.uuidString, forKey: "conversationID")
        row.setValue(message.sequence, forKey: "sequence")
        row.setValue(message.text, forKey: "searchText")
        row.setValue(message.role.rawValue, forKey: "messageRole")
      }
      try context.save()
    }
    try coordinator.remove(store)
    return url
  }

  private func message(
    conversationID: UUID, sequence: Int64, role: Message.Role, text: String,
    at date: Date = Date(timeIntervalSince1970: 1_789_000_000), attachments: [UUID] = []
  ) -> Message {
    Message(
      id: UUID(), conversationID: conversationID, sequence: sequence, role: role,
      speakerBotID: nil, speakerNameSnapshot: nil, text: text, createdAt: date,
      replyToID: nil, attachmentIDs: attachments, generationID: nil)
  }

  func testEmptyAndLatestPreviewTimestampUnicodeBoundAndAttachmentSafety() async throws {
    var empty = Conversation(kind: .group, title: "Empty", memberBotIDs: [])
    let unicode = Conversation(kind: .group, title: "Unicode", memberBotIDs: [])
    let oneAttachment = Conversation(kind: .group, title: "One", memberBotIDs: [])
    let manyAttachments = Conversation(kind: .group, title: "Many", memberBotIDs: [])
    let date = Date(timeIntervalSince1970: 1_789_123_456)
    let family = "👨‍👩‍👧‍👦"
    let longText = String(repeating: family, count: 161)
    let messages = [
      message(conversationID: unicode.id, sequence: 1, role: .assistant, text: longText, at: date),
      message(
        conversationID: oneAttachment.id, sequence: 1, role: .user, text: " \n",
        attachments: [UUID()]),
      message(
        conversationID: manyAttachments.id, sequence: 1, role: .event, text: "",
        attachments: [UUID(), UUID()]),
    ]
    empty.nextSequence = 1
    let url = try makeStore(
      conversations: [empty, unicode, oneAttachment, manyAttachments], messages: messages)
    let repository = try await CoreDataWorkspaceRepository.open(at: url)
    addTeardownBlock { try await repository.close() }

    let activity = Dictionary(
      uniqueKeysWithValues: try await repository.snapshot().conversationActivity.map {
        ($0.conversationID, $0)
      })
    XCTAssertEqual(activity[empty.id]?.latestSequence, 0)
    XCTAssertNil(activity[empty.id]?.lastMessagePreview)
    XCTAssertNil(activity[empty.id]?.lastMessageAt)
    XCTAssertEqual(activity[empty.id]?.unreadAssistantCount, 0)
    XCTAssertEqual(activity[unicode.id]?.lastMessagePreview, String(longText.prefix(160)))
    XCTAssertEqual(activity[unicode.id]?.lastMessagePreview?.count, 160)
    XCTAssertEqual(activity[unicode.id]?.latestMessageID, messages[0].id)
    XCTAssertEqual(activity[unicode.id]?.latestMessageTextByteCount, longText.utf8.count)
    XCTAssertEqual(activity[unicode.id]?.lastMessageAt, date)
    XCTAssertEqual(activity[oneAttachment.id]?.lastMessagePreview, "Text attachment")
    XCTAssertEqual(activity[manyAttachments.id]?.lastMessagePreview, "Text attachments")
  }

  func testUnreadAssistantCountIsExactBeyondOneHundredAndIgnoresOtherRoles() async throws {
    var conversation = Conversation(
      kind: .group, title: "Count", memberBotIDs: [], lastReadSequence: 1)
    var messages = [
      message(conversationID: conversation.id, sequence: 1, role: .assistant, text: "read"),
      message(conversationID: conversation.id, sequence: 2, role: .user, text: "user"),
      message(conversationID: conversation.id, sequence: 3, role: .event, text: "event"),
    ]
    for sequence in 4...104 {
      messages.append(
        message(
          conversationID: conversation.id, sequence: Int64(sequence), role: .assistant,
          text: sequence == 104 ? "partial" : "reply"))
    }
    conversation.nextSequence = 105
    let repository = try await CoreDataWorkspaceRepository.open(
      at: makeStore(conversations: [conversation], messages: messages))
    addTeardownBlock { try await repository.close() }
    let snapshot = try await repository.snapshot()
    let activity = try XCTUnwrap(snapshot.conversationActivity.first)
    XCTAssertEqual(activity.latestSequence, 104)
    XCTAssertEqual(activity.unreadAssistantCount, 101)
  }

  func testLatestMessageMetadataTracksAppendedDeltaAtTheSameSequence() async throws {
    let url = try temporaryURL()
    let repository = try await CoreDataWorkspaceRepository.open(at: url)
    addTeardownBlock { try await repository.close() }
    let bot = Bot(name: "Writer")
    let conversationID = UUID()
    try await repository.apply(.createBot(bot, conversationID: conversationID))
    let command = SendCommand(conversationID: conversationID, targetBotID: bot.id, text: "Go")
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
          kind: .delta("🙂"))))
    let firstSnapshot = try await repository.snapshot()
    let first = try XCTUnwrap(firstSnapshot.conversationActivity.first)
    try await repository.apply(
      .applyGenerationEvent(
        GenerationEvent(
          generationID: command.generationID, attemptID: command.attemptID, sequence: 3,
          kind: .delta(" more"))))
    let secondSnapshot = try await repository.snapshot()
    let second = try XCTUnwrap(secondSnapshot.conversationActivity.first)
    XCTAssertEqual(second.latestSequence, first.latestSequence)
    XCTAssertEqual(second.latestMessageID, first.latestMessageID)
    XCTAssertEqual(first.latestMessageTextByteCount, "🙂".utf8.count)
    XCTAssertEqual(second.latestMessageTextByteCount, "🙂 more".utf8.count)
  }

  func testReadMarkersRemainMonotonicRangeCheckedAndRollbackOnSaveFailure() async throws {
    var conversation = Conversation(
      kind: .group, title: "Read", memberBotIDs: [], lastReadSequence: 50)
    conversation.nextSequence = 121
    let repository = try await CoreDataWorkspaceRepository.open(
      at: makeStore(conversations: [conversation], messages: []))
    addTeardownBlock { try await repository.close() }

    try await repository.apply(.markRead(conversationID: conversation.id, throughSequence: 20))
    var snapshot = try await repository.snapshot()
    XCTAssertEqual(snapshot.conversations.first?.lastReadSequence, 50)
    do {
      try await repository.apply(.markRead(conversationID: conversation.id, throughSequence: 121))
      XCTFail("An out-of-range marker must fail")
    } catch { XCTAssertEqual(error as? WorkspaceError, .invalidPage) }
    await repository.injectNextSaveFailure()
    do {
      try await repository.apply(.markRead(conversationID: conversation.id, throughSequence: 100))
      XCTFail("The injected save must fail")
    } catch { XCTAssertEqual(error as? WorkspaceError, .storeUnavailable) }
    snapshot = try await repository.snapshot()
    XCTAssertEqual(snapshot.conversations.first?.lastReadSequence, 50)
  }
}
