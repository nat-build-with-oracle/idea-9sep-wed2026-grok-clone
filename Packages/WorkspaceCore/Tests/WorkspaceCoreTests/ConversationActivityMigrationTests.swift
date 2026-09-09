import CoreData
import XCTest

@testable import WorkspaceCore

@MainActor final class ConversationActivityMigrationTests: XCTestCase {
  private struct Fixture {
    let url: URL
    let conversation: Conversation
    let message: Message
    let attachment: AttachmentContent
  }

  private func makeV3Store() throws -> Fixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ConversationActivityMigrationTests-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("workspace.sqlite")
    let coordinator = NSPersistentStoreCoordinator(
      managedObjectModel: CoreDataWorkspaceRepository.modelV3())
    let store = try coordinator.addPersistentStore(
      ofType: NSSQLiteStoreType, configurationName: nil, at: url)
    let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
    context.persistentStoreCoordinator = coordinator
    var conversation = Conversation(
      kind: .group, title: "V3", memberBotIDs: [], lastReadSequence: 7)
    conversation.nextSequence = 9
    let storedConversation = conversation
    let attachment = try AttachmentContent(
      conversationID: conversation.id, originalName: "private-name.txt",
      data: Data("exact legacy bytes".utf8))
    let message = Message(
      id: UUID(), conversationID: conversation.id, sequence: 8, role: .assistant,
      speakerBotID: nil, speakerNameSnapshot: nil, text: "", createdAt: Date(),
      replyToID: nil, attachmentIDs: [attachment.attachment.id], generationID: UUID())
    try context.performAndWait {
      let metadata = NSEntityDescription.insertNewObject(forEntityName: "Metadata", into: context)
      metadata.setValue("workspace", forKey: "id")
      metadata.setValue(Int64(3), forKey: "schemaVersion")
      metadata.setValue(Int64(12), forKey: "revision")
      let conversationRow = NSEntityDescription.insertNewObject(
        forEntityName: "Conversation", into: context)
      conversationRow.setValue(storedConversation.id.uuidString, forKey: "id")
      conversationRow.setValue(try JSONEncoder().encode(storedConversation), forKey: "payload")
      let messageRow = NSEntityDescription.insertNewObject(
        forEntityName: "Message", into: context)
      messageRow.setValue(message.id.uuidString, forKey: "id")
      messageRow.setValue(try JSONEncoder().encode(message), forKey: "payload")
      messageRow.setValue(storedConversation.id.uuidString, forKey: "conversationID")
      messageRow.setValue(message.sequence, forKey: "sequence")
      messageRow.setValue(message.text, forKey: "searchText")
      let attachmentRow = NSEntityDescription.insertNewObject(
        forEntityName: "Attachment", into: context)
      attachmentRow.setValue(attachment.attachment.id.uuidString, forKey: "id")
      attachmentRow.setValue(
        try JSONEncoder().encode(attachment.attachment), forKey: "payload")
      attachmentRow.setValue(attachment.data, forKey: "content")
      try context.save()
    }
    try coordinator.remove(store)
    return Fixture(
      url: url, conversation: storedConversation, message: message, attachment: attachment)
  }

  func testV3MigrationBackfillsRoleAndPreservesAttachmentBytesAndReadMarker() async throws {
    let fixture = try makeV3Store()
    let repository = try await CoreDataWorkspaceRepository.open(at: fixture.url)
    let snapshot = try await repository.snapshot()
    XCTAssertEqual(snapshot.conversations.first?.lastReadSequence, 7)
    XCTAssertEqual(snapshot.conversationActivity.first?.unreadAssistantCount, 1)
    XCTAssertEqual(snapshot.conversationActivity.first?.lastMessagePreview, "Text attachment")
    let migratedAttachment = try await repository.attachmentContent(
      id: fixture.attachment.attachment.id)
    let migratedMessage = try await repository.message(id: fixture.message.id)
    XCTAssertEqual(migratedAttachment, fixture.attachment)
    XCTAssertEqual(migratedMessage, fixture.message)
    try await repository.close()
  }

  func testV3MigrationFailureDoesNotReplaceOrResetOriginal() async throws {
    let fixture = try makeV3Store()
    do {
      _ = try await CoreDataWorkspaceRepository.open(
        at: fixture.url, migrationFailureForTesting: .beforeReplacement)
      XCTFail("Expected migration failure")
    } catch { XCTAssertEqual(error as? WorkspaceError, .storeUnavailable) }
    try assertOriginalV3(fixture)
  }

  func testV3MigrationFailureAfterReplacementRestoresOriginalWithAttachment() async throws {
    let fixture = try makeV3Store()
    do {
      _ = try await CoreDataWorkspaceRepository.open(
        at: fixture.url, migrationFailureForTesting: .afterReplacement)
      XCTFail("Expected migration failure")
    } catch { XCTAssertEqual(error as? WorkspaceError, .storeUnavailable) }
    try assertOriginalV3(fixture)
  }

  private func assertOriginalV3(_ fixture: Fixture) throws {
    let coordinator = NSPersistentStoreCoordinator(
      managedObjectModel: CoreDataWorkspaceRepository.modelV3())
    let store = try coordinator.addPersistentStore(
      ofType: NSSQLiteStoreType, configurationName: nil, at: fixture.url,
      options: [NSReadOnlyPersistentStoreOption: true])
    defer { try? coordinator.remove(store) }
    let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
    context.persistentStoreCoordinator = coordinator
    try context.performAndWait {
      let metadata = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "Metadata"))[0]
      let attachment = try context.fetch(
        NSFetchRequest<NSManagedObject>(entityName: "Attachment"))[0]
      XCTAssertEqual(metadata.value(forKey: "schemaVersion") as? Int64, 3)
      XCTAssertEqual(attachment.value(forKey: "content") as? Data, fixture.attachment.data)
    }
  }
}
