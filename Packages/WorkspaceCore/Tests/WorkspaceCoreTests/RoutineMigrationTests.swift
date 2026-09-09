import CoreData
import XCTest

@testable import WorkspaceCore

@MainActor final class RoutineMigrationTests: XCTestCase {
  private struct LegacyFixture {
    let url: URL
    let directory: URL
    let bot: Bot
    let conversation: Conversation
    let draft: Draft
    let message: Message
    let generation: Generation
    let routine: Routine
    let provider: ProviderConfig
  }

  private func makeLegacyStore(schemaVersion: Int64 = 1) throws -> LegacyFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "RoutineMigrationTests-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("workspace.sqlite")
    let model = CoreDataWorkspaceRepository.modelV1()
    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
    let store = try coordinator.addPersistentStore(
      ofType: NSSQLiteStoreType, configurationName: nil, at: url)
    let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
    context.persistentStoreCoordinator = coordinator
    let provider = ProviderConfig(
      name: "Legacy provider", apiRoot: URL(string: "https://legacy.invalid/v1")!,
      modelID: "legacy-model", credentialReference: "legacy-secret-reference")
    let bot = Bot(name: "Legacy routine bot", providerConfigID: provider.id)
    var conversation = Conversation(
      kind: .direct, title: bot.name, memberBotIDs: [bot.id])
    conversation.nextSequence = 2
    let generationID = UUID()
    let message = Message(
      id: UUID(), conversationID: conversation.id, sequence: 1, role: .user,
      speakerBotID: nil, speakerNameSnapshot: nil, text: "Legacy message", createdAt: Date(),
      replyToID: nil, attachmentIDs: [], generationID: generationID)
    let draft = Draft(conversationID: conversation.id, text: "Legacy draft")
    let generation = Generation(
      id: generationID, conversationID: conversation.id, userMessageID: message.id,
      attemptID: UUID(), targetBotID: bot.id, state: .interrupted, lastEventSequence: 0,
      error: "Legacy interruption")
    let routine = Routine(
      ownerBotID: bot.id, name: "Legacy check", prompt: "Report",
      trigger: .interval(minutes: 30), timezoneID: "Asia/Bangkok", enabled: true,
      nextRunAt: Date(timeIntervalSince1970: 1_789_000_000))
    let legacyRoutinePayload = try legacyRoutineData(routine)
    let messagePayload = try JSONEncoder().encode(message)
    let conversationID = conversation.id
    let encodedRows: [(String, UUID, Data)] = try [
      ("Bot", bot.id, JSONEncoder().encode(bot)),
      ("Conversation", conversation.id, JSONEncoder().encode(conversation)),
      ("Draft", draft.id, JSONEncoder().encode(draft)),
      ("Generation", generation.id, JSONEncoder().encode(generation)),
      ("Provider", provider.id, JSONEncoder().encode(provider)),
    ]
    try context.performAndWait {
      let metadata = NSEntityDescription.insertNewObject(forEntityName: "Metadata", into: context)
      metadata.setValue("workspace", forKey: "id")
      metadata.setValue(schemaVersion, forKey: "schemaVersion")
      metadata.setValue(Int64(7), forKey: "revision")
      for (entity, id, payload) in encodedRows {
        let record = NSEntityDescription.insertNewObject(forEntityName: entity, into: context)
        record.setValue(id.uuidString, forKey: "id")
        record.setValue(payload, forKey: "payload")
      }
      let messageRecord = NSEntityDescription.insertNewObject(
        forEntityName: "Message", into: context)
      messageRecord.setValue(message.id.uuidString, forKey: "id")
      messageRecord.setValue(messagePayload, forKey: "payload")
      messageRecord.setValue(conversationID.uuidString, forKey: "conversationID")
      messageRecord.setValue(message.sequence, forKey: "sequence")
      messageRecord.setValue(message.text, forKey: "searchText")
      let routineRecord = NSEntityDescription.insertNewObject(
        forEntityName: "Routine", into: context)
      routineRecord.setValue(routine.id.uuidString, forKey: "id")
      routineRecord.setValue(legacyRoutinePayload, forKey: "payload")
      try context.save()
    }
    try coordinator.remove(store)
    return LegacyFixture(
      url: url, directory: directory, bot: bot, conversation: conversation, draft: draft,
      message: message, generation: generation, routine: routine, provider: provider)
  }

  private func legacyRoutineData(_ routine: Routine) throws -> Data {
    let encoded = try JSONEncoder().encode(routine)
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "providerBinding")
    object.removeValue(forKey: "scheduleID")
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }

  private func assertMigrated(_ fixture: LegacyFixture) async throws {
    let repository = try await CoreDataWorkspaceRepository.open(at: fixture.url)
    let snapshot = try await repository.snapshot()
    XCTAssertEqual(snapshot.revision, 7)
    XCTAssertEqual(snapshot.bots, [fixture.bot])
    XCTAssertEqual(snapshot.conversations, [fixture.conversation])
    XCTAssertEqual(snapshot.drafts, [fixture.draft])
    XCTAssertEqual(snapshot.generations, [fixture.generation])
    XCTAssertEqual(snapshot.providers, [fixture.provider])
    XCTAssertEqual(snapshot.routines.count, 1)
    XCTAssertEqual(snapshot.routines.first?.id, fixture.routine.id)
    XCTAssertNil(snapshot.routines.first?.providerBinding)
    XCTAssertNil(snapshot.routines.first?.scheduleID)
    let runs = try await repository.routineRuns(routineID: nil, limit: 100)
    let exported = try await repository.exportSnapshot()
    XCTAssertEqual(exported.messages, [fixture.message])
    XCTAssertEqual(exported.summary.botCount, 1)
    XCTAssertEqual(exported.summary.conversationCount, 1)
    XCTAssertEqual(exported.summary.messageCount, 1)
    XCTAssertEqual(exported.summary.draftCount, 1)
    XCTAssertEqual(exported.summary.generationCount, 1)
    XCTAssertEqual(exported.summary.routineCount, 1)
    XCTAssertEqual(exported.summary.routineRunCount, 0)
    XCTAssertEqual(exported.summary.providerCount, 1)
    XCTAssertEqual(exported.providers, [WorkspaceExportProvider(fixture.provider)])
    XCTAssertTrue(runs.isEmpty)
    XCTAssertEqual(exported.sourceSchemaVersion, 2)
    try await repository.close()
  }

  func testLegacyV1MigratesToV2AndPreservesLegacyRoutine() async throws {
    try await assertMigrated(makeLegacyStore())
  }

  func testFailureBeforeReplacementLeavesOriginalStoreMigratable() async throws {
    let fixture = try makeLegacyStore()
    do {
      _ = try await CoreDataWorkspaceRepository.open(
        at: fixture.url, migrationFailureForTesting: .beforeReplacement)
      XCTFail("Expected injected migration failure")
    } catch { XCTAssertEqual(error as? WorkspaceError, .storeUnavailable) }
    XCTAssertEqual(try readLegacySchemaVersion(at: fixture.url), 1)
    try assertLegacyRowsReadable(fixture)
    try await assertMigrated(fixture)
  }

  func testFailureAfterReplacementRestoresOriginalStore() async throws {
    let fixture = try makeLegacyStore()
    do {
      _ = try await CoreDataWorkspaceRepository.open(
        at: fixture.url, migrationFailureForTesting: .afterReplacement)
      XCTFail("Expected injected replacement failure")
    } catch { XCTAssertEqual(error as? WorkspaceError, .storeUnavailable) }
    XCTAssertEqual(try readLegacySchemaVersion(at: fixture.url), 1)
    try assertLegacyRowsReadable(fixture)
    try await assertMigrated(fixture)
  }

  func testCompatibleV1ModelWithUnknownInternalVersionIsRejectedWithoutConversion() async throws {
    let fixture = try makeLegacyStore(schemaVersion: 991)
    do {
      _ = try await CoreDataWorkspaceRepository.open(at: fixture.url)
      XCTFail("Unknown internal versions must fail closed")
    } catch { XCTAssertEqual(error as? WorkspaceError, .unsupportedSchema) }
    XCTAssertEqual(try readLegacySchemaVersion(at: fixture.url), 991)
  }

  private func readLegacySchemaVersion(at url: URL) throws -> Int64 {
    let coordinator = NSPersistentStoreCoordinator(
      managedObjectModel: CoreDataWorkspaceRepository.modelV1())
    let store = try coordinator.addPersistentStore(
      ofType: NSSQLiteStoreType, configurationName: nil, at: url,
      options: [NSReadOnlyPersistentStoreOption: true])
    defer { try? coordinator.remove(store) }
    let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
    context.persistentStoreCoordinator = coordinator
    return try context.performAndWait {
      let request = NSFetchRequest<NSManagedObject>(entityName: "Metadata")
      request.fetchLimit = 1
      guard let value = try context.fetch(request).first?.value(forKey: "schemaVersion") as? Int64
      else { throw WorkspaceError.invalidStore }
      return value
    }
  }

  private func assertLegacyRowsReadable(_ fixture: LegacyFixture) throws {
    let coordinator = NSPersistentStoreCoordinator(
      managedObjectModel: CoreDataWorkspaceRepository.modelV1())
    let store = try coordinator.addPersistentStore(
      ofType: NSSQLiteStoreType, configurationName: nil, at: fixture.url,
      options: [NSReadOnlyPersistentStoreOption: true])
    defer { try? coordinator.remove(store) }
    let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
    context.persistentStoreCoordinator = coordinator
    try context.performAndWait {
      let expectations: [(String, UUID)] = [
        ("Bot", fixture.bot.id), ("Conversation", fixture.conversation.id),
        ("Draft", fixture.draft.id), ("Message", fixture.message.id),
        ("Generation", fixture.generation.id), ("Routine", fixture.routine.id),
        ("Provider", fixture.provider.id),
      ]
      for (entity, id) in expectations {
        let request = NSFetchRequest<NSManagedObject>(entityName: entity)
        request.predicate = NSPredicate(format: "id == %@", id.uuidString)
        request.fetchLimit = 1
        guard try context.fetch(request).first?.value(forKey: "payload") is Data else {
          throw WorkspaceError.invalidStore
        }
      }
    }
  }
}
