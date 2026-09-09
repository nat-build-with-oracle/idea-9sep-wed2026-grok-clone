import CoreData
import XCTest

@testable import WorkspaceCore

@MainActor final class AttachmentMigrationTests: XCTestCase {
  private struct V2Fixture {
    let directory: URL
    let url: URL
    let bot: Bot
    let conversation: Conversation
    let routine: Routine
    let run: RoutineRun
    let draft: Draft?
  }

  private func directory(_ prefix: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "\(prefix)-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return directory
  }

  private func makeV2Store(danglingAttachment: Bool = false) throws -> V2Fixture {
    let directory = try directory("AttachmentMigrationV2")
    let url = directory.appendingPathComponent("workspace.sqlite")
    let model = CoreDataWorkspaceRepository.modelV2()
    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
    let store = try coordinator.addPersistentStore(
      ofType: NSSQLiteStoreType, configurationName: nil, at: url)
    let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
    context.persistentStoreCoordinator = coordinator
    let bot = Bot(name: "V2 bot")
    let conversation = Conversation(kind: .direct, title: bot.name, memberBotIDs: [bot.id])
    let routine = Routine(
      ownerBotID: bot.id, name: "V2 routine", prompt: "report",
      trigger: .interval(minutes: 30), timezoneID: "UTC")
    let run = RoutineRun(
      routineID: routine.id, ownerBotID: bot.id, conversationID: conversation.id,
      name: routine.name, prompt: routine.prompt, providerBinding: nil,
      createdAt: Date(timeIntervalSince1970: 1_789_000_000),
      generationID: nil, status: .interrupted,
      endedAt: Date(timeIntervalSince1970: 1_789_000_001), error: .interrupted)
    let draft =
      danglingAttachment
      ? Draft(conversationID: conversation.id, text: "dangling", attachmentIDs: [UUID()]) : nil
    try context.performAndWait {
      let metadata = NSEntityDescription.insertNewObject(forEntityName: "Metadata", into: context)
      metadata.setValue("workspace", forKey: "id")
      metadata.setValue(Int64(2), forKey: "schemaVersion")
      metadata.setValue(Int64(41), forKey: "revision")
      for (entity, id, value) in [
        ("Bot", bot.id, try JSONEncoder().encode(bot)),
        ("Conversation", conversation.id, try JSONEncoder().encode(conversation)),
        ("Routine", routine.id, try JSONEncoder().encode(routine)),
        ("RoutineRun", run.id, try JSONEncoder().encode(run)),
      ] {
        let row = NSEntityDescription.insertNewObject(forEntityName: entity, into: context)
        row.setValue(id.uuidString, forKey: "id")
        row.setValue(value, forKey: "payload")
        if entity == "RoutineRun" {
          row.setValue(run.routineID.uuidString, forKey: "routineID")
          row.setValue(run.createdAt, forKey: "createdAt")
        }
      }
      if let draft {
        let row = NSEntityDescription.insertNewObject(forEntityName: "Draft", into: context)
        row.setValue(draft.id.uuidString, forKey: "id")
        row.setValue(try JSONEncoder().encode(draft), forKey: "payload")
      }
      try context.save()
    }
    try coordinator.remove(store)
    return V2Fixture(
      directory: directory, url: url, bot: bot, conversation: conversation, routine: routine,
      run: run, draft: draft)
  }

  private func readVersionAndRun(_ fixture: V2Fixture) throws -> (Int64, RoutineRun) {
    let model = CoreDataWorkspaceRepository.modelV2()
    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
    let store = try coordinator.addPersistentStore(
      ofType: NSSQLiteStoreType, configurationName: nil, at: fixture.url,
      options: [NSReadOnlyPersistentStoreOption: true])
    defer { try? coordinator.remove(store) }
    let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
    context.persistentStoreCoordinator = coordinator
    return try context.performAndWait {
      let metadata = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "Metadata"))[0]
      let runRow = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "RoutineRun"))[0]
      return (
        try XCTUnwrap(metadata.value(forKey: "schemaVersion") as? Int64),
        try JSONDecoder().decode(
          RoutineRun.self, from: try XCTUnwrap(runRow.value(forKey: "payload") as? Data))
      )
    }
  }

  private func assertMigrates(_ fixture: V2Fixture) async throws {
    let repository = try await CoreDataWorkspaceRepository.open(at: fixture.url)
    let snapshot = try await repository.snapshot()
    XCTAssertEqual(snapshot.revision, 41)
    XCTAssertEqual(snapshot.bots, [fixture.bot])
    XCTAssertEqual(snapshot.conversations, [fixture.conversation])
    XCTAssertEqual(snapshot.routines, [fixture.routine])
    let runs = try await repository.routineRuns(routineID: fixture.routine.id)
    let exported = try await repository.exportSnapshot()
    XCTAssertEqual(runs, [fixture.run])
    XCTAssertTrue(exported.attachments.isEmpty)
    try await repository.close()
  }

  func testV2MigratesToV3PreservingRoutineLedger() async throws {
    try await assertMigrates(makeV2Store())
  }

  func testV2FailureBeforeReplacementPreservesOriginalStore() async throws {
    let fixture = try makeV2Store()
    do {
      _ = try await CoreDataWorkspaceRepository.open(
        at: fixture.url, migrationFailureForTesting: .beforeReplacement)
      XCTFail("Expected failure")
    } catch { XCTAssertEqual(error as? WorkspaceError, .storeUnavailable) }
    let original = try readVersionAndRun(fixture)
    XCTAssertEqual(original.0, 2)
    XCTAssertEqual(original.1, fixture.run)
    try await assertMigrates(fixture)
  }

  func testV2FailureAfterReplacementRestoresOriginalStore() async throws {
    let fixture = try makeV2Store()
    do {
      _ = try await CoreDataWorkspaceRepository.open(
        at: fixture.url, migrationFailureForTesting: .afterReplacement)
      XCTFail("Expected failure")
    } catch { XCTAssertEqual(error as? WorkspaceError, .storeUnavailable) }
    let original = try readVersionAndRun(fixture)
    XCTAssertEqual(original.0, 2)
    XCTAssertEqual(original.1, fixture.run)
    try await assertMigrates(fixture)
  }

  func testV2DanglingAttachmentReferenceIsRejectedWithLedgerAndSourcePreserved() async throws {
    let fixture = try makeV2Store(danglingAttachment: true)
    do {
      _ = try await CoreDataWorkspaceRepository.open(at: fixture.url)
      XCTFail("Expected invalid legacy reference")
    } catch { XCTAssertEqual(error as? WorkspaceError, .invalidStore) }
    let original = try readVersionAndRun(fixture)
    XCTAssertEqual(original.0, 2)
    XCTAssertEqual(original.1, fixture.run)

    let model = CoreDataWorkspaceRepository.modelV2()
    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
    let store = try coordinator.addPersistentStore(
      ofType: NSSQLiteStoreType, configurationName: nil, at: fixture.url,
      options: [NSReadOnlyPersistentStoreOption: true])
    let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
    context.persistentStoreCoordinator = coordinator
    try context.performAndWait {
      let row = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "Draft"))[0]
      XCTAssertEqual(
        try JSONDecoder().decode(
          Draft.self, from: try XCTUnwrap(row.value(forKey: "payload") as? Data)), fixture.draft)
    }
    try coordinator.remove(store)
  }

  func testLegacyDanglingAttachmentReferenceIsRejectedWithoutReplacement() async throws {
    let directory = try directory("AttachmentMigrationV1Dangling")
    let url = directory.appendingPathComponent("workspace.sqlite")
    let model = CoreDataWorkspaceRepository.modelV1()
    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
    let store = try coordinator.addPersistentStore(
      ofType: NSSQLiteStoreType, configurationName: nil, at: url)
    let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
    context.persistentStoreCoordinator = coordinator
    let draft = Draft(conversationID: UUID(), text: "dangling", attachmentIDs: [UUID()])
    try context.performAndWait {
      let metadata = NSEntityDescription.insertNewObject(forEntityName: "Metadata", into: context)
      metadata.setValue("workspace", forKey: "id")
      metadata.setValue(Int64(1), forKey: "schemaVersion")
      metadata.setValue(Int64(9), forKey: "revision")
      let row = NSEntityDescription.insertNewObject(forEntityName: "Draft", into: context)
      row.setValue(draft.id.uuidString, forKey: "id")
      row.setValue(try JSONEncoder().encode(draft), forKey: "payload")
      try context.save()
    }
    try coordinator.remove(store)
    do {
      _ = try await CoreDataWorkspaceRepository.open(at: url)
      XCTFail("Expected invalid legacy reference")
    } catch { XCTAssertEqual(error as? WorkspaceError, .invalidStore) }

    let check = NSPersistentStoreCoordinator(managedObjectModel: model)
    let checkedStore = try check.addPersistentStore(
      ofType: NSSQLiteStoreType, configurationName: nil, at: url,
      options: [NSReadOnlyPersistentStoreOption: true])
    let checkContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
    checkContext.persistentStoreCoordinator = check
    try checkContext.performAndWait {
      let metadata = try checkContext.fetch(
        NSFetchRequest<NSManagedObject>(entityName: "Metadata"))[0]
      let row = try checkContext.fetch(NSFetchRequest<NSManagedObject>(entityName: "Draft"))[0]
      XCTAssertEqual(metadata.value(forKey: "schemaVersion") as? Int64, 1)
      XCTAssertEqual(
        try JSONDecoder().decode(
          Draft.self, from: try XCTUnwrap(row.value(forKey: "payload") as? Data)), draft)
    }
    try check.remove(checkedStore)
  }
}
