@preconcurrency import CoreData
import Darwin
import Foundation

/// One private-queue context owns every managed object and transaction. Only Sendable DTOs escape.
/// `@unchecked` is restricted to the Core Data queue boundary, not shared mutable domain state.
public final class CoreDataWorkspaceRepository: WorkspaceRepository, @unchecked Sendable {
  private let context: NSManagedObjectContext
  private let lease: StoreLease
  // Access only within context.perform, including close and fault injection.
  private var closed = false
  private var failNextSave = false

  /// Store opening can perform disk I/O; callers should invoke this off the main actor.
  public static func open(at url: URL) async throws -> CoreDataWorkspaceRepository {
    try await Task.detached { try CoreDataWorkspaceRepository(storeURL: url) }.value
  }

  private init(storeURL: URL) throws {
    guard storeURL.isFileURL else { throw WorkspaceError.invalidStore }
    let canonical = storeURL.standardizedFileURL.resolvingSymlinksInPath()
    do {
      try FileManager.default.createDirectory(
        at: canonical.deletingLastPathComponent(),
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    } catch { throw WorkspaceError.storeUnavailable }
    lease = try StoreLease(url: canonical.appendingPathExtension("lock"))
    let model = Self.modelV1()
    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
    let existingStore = FileManager.default.fileExists(atPath: canonical.path)
    if existingStore {
      let metadata: [String: Any]
      do {
        metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
          ofType: NSSQLiteStoreType, at: canonical, options: [NSReadOnlyPersistentStoreOption: true]
        )
      } catch { throw WorkspaceError.invalidStore }
      guard model.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata) else {
        throw WorkspaceError.unsupportedSchema
      }
    }
    do {
      try coordinator.addPersistentStore(
        ofType: NSSQLiteStoreType, configurationName: nil,
        at: canonical,
        options: [
          NSMigratePersistentStoresAutomaticallyOption: false,
          NSInferMappingModelAutomaticallyOption: false,
        ])
    } catch { throw WorkspaceError.storeUnavailable }
    context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
    context.persistentStoreCoordinator = coordinator
    context.undoManager = nil
    context.mergePolicy = NSErrorMergePolicy
    try context.performAndWait {
      if try self.find("Metadata", id: "workspace") == nil {
        guard !existingStore else { throw WorkspaceError.invalidStore }
        let metadata = NSEntityDescription.insertNewObject(forEntityName: "Metadata", into: context)
        metadata.setValue("workspace", forKey: "id")
        metadata.setValue(Int64(1), forKey: "schemaVersion")
        metadata.setValue(Int64(0), forKey: "revision")
        try context.save()
      }
      guard try self.metadata().value(forKey: "schemaVersion") as? Int64 == 1 else {
        throw WorkspaceError.unsupportedSchema
      }
    }
  }

  public func close() async throws {
    try await context.perform {
      guard !self.closed else { return }
      self.context.reset()
      if let coordinator = self.context.persistentStoreCoordinator {
        for store in coordinator.persistentStores { try coordinator.remove(store) }
      }
      self.closed = true
      self.lease.release()
    }
  }

  public func snapshot() async throws -> WorkspaceSnapshot {
    try await context.perform {
      try self.requireOpen()
      return try WorkspaceSnapshot(
        revision: self.revision(), bots: self.all("Bot", as: Bot.self),
        conversations: self.all("Conversation", as: Conversation.self),
        drafts: self.all("Draft", as: Draft.self),
        generations: self.all("Generation", as: Generation.self),
        routines: self.all("Routine", as: Routine.self),
        providers: self.all("Provider", as: ProviderConfig.self))
    }
  }

  @discardableResult public func apply(_ mutation: WorkspaceMutation, expectedRevision: Int64?)
    async throws -> Int64
  {
    try await context.perform {
      try self.requireOpen()
      do {
        let revision = try self.revision()
        if let expectedRevision, revision != expectedRevision { throw WorkspaceError.staleRevision }
        try self.mutate(mutation)
        guard revision < Int64.max else { throw WorkspaceError.invalidStore }
        try self.metadata().setValue(revision + 1, forKey: "revision")
        if self.failNextSave {
          self.failNextSave = false
          throw WorkspaceError.storeUnavailable
        }
        do { try self.context.save() } catch { throw WorkspaceError.storeUnavailable }
        return revision + 1
      } catch {
        self.context.rollback()
        throw error
      }
    }
  }

  public func messages(conversationID: UUID, beforeSequence: Int64?, limit: Int) async throws
    -> MessagePage
  {
    guard (1...500).contains(limit), beforeSequence.map({ $0 > 0 }) ?? true else {
      throw WorkspaceError.invalidPage
    }
    return try await context.perform {
      try self.requireOpen()
      let _: Conversation = try self.read("Conversation", id: conversationID)
      let request = NSFetchRequest<NSManagedObject>(entityName: "Message")
      var terms = [NSPredicate(format: "conversationID == %@", conversationID.uuidString)]
      if let beforeSequence { terms.append(NSPredicate(format: "sequence < %lld", beforeSequence)) }
      request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: terms)
      request.sortDescriptors = [NSSortDescriptor(key: "sequence", ascending: false)]
      request.fetchLimit = limit + 1
      request.fetchBatchSize = limit + 1
      let rows = try self.context.fetch(request)
      let messages = try rows.prefix(limit).map { try self.decode($0, as: Message.self) }.reversed()
      return MessagePage(messages: Array(messages), hasMore: rows.count > limit)
    }
  }

  public func search(_ query: String, includeHidden: Bool = false) async throws -> [Conversation] {
    try await context.perform {
      try self.requireOpen()
      let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
      let bots = try self.all("Bot", as: Bot.self)
      let hidden = Set(bots.filter { $0.hiddenAt != nil }.map(\.id))
      var matchingIDs = Set<String>()
      if !clean.isEmpty {
        // Dictionary results avoid materializing full message text for sidebar search.
        let request = NSFetchRequest<NSDictionary>(entityName: "Message")
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = ["conversationID"]
        request.returnsDistinctResults = true
        request.predicate = NSPredicate(format: "searchText CONTAINS[cd] %@", clean)
        matchingIDs = Set(
          try self.context.fetch(request).compactMap { $0["conversationID"] as? String })
      }
      return try self.all("Conversation", as: Conversation.self).filter { conversation in
        let isHidden =
          conversation.kind == .direct && conversation.memberBotIDs.contains(where: hidden.contains)
        guard includeHidden || !isHidden else { return false }
        return clean.isEmpty || conversation.title.localizedStandardContains(clean)
          || matchingIDs.contains(conversation.id.uuidString)
      }.sorted { $0.createdAt > $1.createdAt }
    }
  }

  public func message(id: UUID) async throws -> Message {
    try await context.perform {
      try self.requireOpen()
      return try self.read("Message", id: id)
    }
  }

  // Test seam at the actual transaction/save boundary; no production bypass or transport involved.
  func injectNextSaveFailure() async {
    await context.perform { self.failNextSave = true }
  }

  private func mutate(_ mutation: WorkspaceMutation) throws {
    switch mutation {
    case .createBot(let input, let conversationID):
      let bot = try DomainValidation.bot(input)
      guard bot.id != conversationID else { throw WorkspaceError.identityConflict }
      try ensureIdentityAvailable(bot.id)
      try ensureIdentityAvailable(conversationID)
      try validateProvider(bot.providerConfigID)
      let conversation = Conversation(
        id: conversationID, kind: .direct, title: bot.name,
        memberBotIDs: [bot.id], createdAt: bot.createdAt)
      try put("Bot", value: bot)
      try put("Conversation", value: conversation)

    case .updateBot(let input):
      let existing: Bot = try read("Bot", id: input.id)
      var bot = try DomainValidation.bot(input)
      guard bot.createdAt == existing.createdAt else { throw WorkspaceError.identityConflict }
      // Hide/unhide is its own command: unrelated editor snapshots must not change visibility.
      bot.hiddenAt = existing.hiddenAt
      try validateProvider(bot.providerConfigID)
      try put("Bot", value: bot)
      for var conversation in try all("Conversation", as: Conversation.self)
      where conversation.kind == .direct && conversation.memberBotIDs == [bot.id] {
        conversation.title = bot.name
        try put("Conversation", value: conversation)
      }

    case .editBot(let id, let expected, let replacement):
      var bot: Bot = try read("Bot", id: id)
      let expected = try expected.validated()
      let replacement = try replacement.validated()
      guard BotProfile(bot) == expected else { throw WorkspaceError.editConflict }
      bot.name = replacement.name
      bot.description = replacement.description
      bot.color = replacement.color
      bot.shape = replacement.shape
      try put("Bot", value: bot)
      for var conversation in try all("Conversation", as: Conversation.self)
      where conversation.kind == .direct && conversation.memberBotIDs == [bot.id] {
        conversation.title = bot.name
        try put("Conversation", value: conversation)
      }

    case .setHidden(let id, let at):
      var bot: Bot = try read("Bot", id: id)
      bot.hiddenAt = at
      try put("Bot", value: bot)

    case .createGroup(var conversation):
      guard conversation.kind == .group, conversation.nextSequence == 1,
        conversation.lastReadSequence == 0
      else {
        throw WorkspaceError.invalidMembers
      }
      try ensureIdentityAvailable(conversation.id)
      conversation.title = try DomainValidation.name(conversation.title)
      try validateMembers(conversation.memberBotIDs)
      try put("Conversation", value: conversation)

    case .updateGroup(let id, let title, let members):
      var conversation: Conversation = try read("Conversation", id: id)
      guard conversation.kind == .group else { throw WorkspaceError.invalidMembers }
      conversation.title = try DomainValidation.name(title)
      try validateMembers(members)
      conversation.memberBotIDs = members
      try put("Conversation", value: conversation)

    case .editGroup(let id, let expected, let replacement):
      var conversation: Conversation = try read("Conversation", id: id)
      guard conversation.kind == .group else { throw WorkspaceError.invalidMembers }
      let expected = try expected.validated()
      let replacement = try replacement.validated()
      guard GroupProfile(conversation) == expected else { throw WorkspaceError.editConflict }
      try validateEditedMembers(
        replacement.memberBotIDs, retaining: Set(conversation.memberBotIDs))
      conversation.title = replacement.title
      conversation.memberBotIDs = replacement.memberBotIDs
      try put("Conversation", value: conversation)

    case .saveDraft(let draft):
      let _: Conversation = try read("Conversation", id: draft.conversationID)
      // Attachment staging has not shipped yet. Refuse dangling references instead of silently dropping them.
      guard draft.attachmentIDs.isEmpty else { throw WorkspaceError.invalidDraft }
      try validateReply(draft.replyToID, conversationID: draft.conversationID)
      try put("Draft", value: draft)

    case .beginGeneration(let command):
      var conversation: Conversation = try read("Conversation", id: command.conversationID)
      let text = command.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { throw WorkspaceError.invalidDraft }
      if conversation.kind == .group {
        try validateMembers(conversation.memberBotIDs, allowHidden: true)
      }
      guard conversation.memberBotIDs.contains(command.targetBotID) else {
        throw WorkspaceError.invalidMembers
      }
      let _: Bot = try read("Bot", id: command.targetBotID)
      guard command.userMessageID != command.generationID else {
        throw WorkspaceError.identityConflict
      }
      try ensureIdentityAvailable(command.userMessageID)
      try ensureIdentityAvailable(command.generationID)
      try validateReply(command.replyToID, conversationID: conversation.id)
      guard conversation.nextSequence < Int64.max else { throw WorkspaceError.invalidStore }
      let message = Message(
        id: command.userMessageID, conversationID: conversation.id,
        sequence: conversation.nextSequence, role: .user, speakerBotID: nil,
        speakerNameSnapshot: nil, text: text, createdAt: command.createdAt,
        replyToID: command.replyToID, attachmentIDs: [], generationID: command.generationID)
      let generation = Generation(
        id: command.generationID, conversationID: conversation.id,
        userMessageID: command.userMessageID, attemptID: command.attemptID,
        targetBotID: command.targetBotID, state: .queued, lastEventSequence: 0, error: nil)
      conversation.nextSequence += 1
      try put("Message", value: message)
      try put("Generation", value: generation)
      try put("Conversation", value: conversation)
      if let record = try find("Draft", id: conversation.id.uuidString) {
        let draft = try decode(record, as: Draft.self)
        if draft.text.trimmingCharacters(in: .whitespacesAndNewlines) == text,
          draft.replyToID == command.replyToID, draft.attachmentIDs.isEmpty
        {
          context.delete(record)
        }
      }

    case .cancelGeneration(let id, let attemptID):
      var generation: Generation = try read("Generation", id: id)
      guard generation.attemptID == attemptID, !generation.state.isTerminal else { return }
      generation.state = .cancelled
      try put("Generation", value: generation)

    case .applyGenerationEvent(let event):
      var generation: Generation = try read("Generation", id: event.generationID)
      guard generation.attemptID == event.attemptID, !generation.state.isTerminal,
        event.sequence > generation.lastEventSequence
      else { return }
      switch event.kind {
      case .started:
        guard generation.state == .queued else { return }
        generation.state = .connecting
      case .delta(let text):
        guard generation.state == .connecting || generation.state == .streaming else { return }
        var conversation: Conversation = try read("Conversation", id: generation.conversationID)
        let bot: Bot = try read("Bot", id: generation.targetBotID)
        var message: Message
        if let id = generation.assistantMessageID {
          message = try read("Message", id: id)
        } else {
          guard conversation.nextSequence < Int64.max else { throw WorkspaceError.invalidStore }
          message = Message(
            id: UUID(), conversationID: conversation.id, sequence: conversation.nextSequence,
            role: .assistant, speakerBotID: bot.id, speakerNameSnapshot: bot.name, text: "",
            createdAt: event.createdAt, replyToID: generation.userMessageID,
            attachmentIDs: [], generationID: generation.id)
          conversation.nextSequence += 1
          generation.assistantMessageID = message.id
          try put("Conversation", value: conversation)
        }
        guard message.text.utf8.count + text.utf8.count <= 4_194_304 else {
          throw ProviderError.outputLimit
        }
        message.text += text
        generation.state = .streaming
        try put("Message", value: message)
      case .completed:
        guard generation.state == .connecting || generation.state == .streaming else { return }
        generation.state = .completed
      case .failed(let error):
        generation.state = .failed
        generation.error = error.localizedDescription
      }
      generation.lastEventSequence = event.sequence
      try put("Generation", value: generation)

    case .retryGeneration(let id, let attemptID):
      var generation: Generation = try read("Generation", id: id)
      guard [.failed, .cancelled, .interrupted].contains(generation.state),
        generation.attemptID != attemptID
      else {
        throw WorkspaceError.identityConflict
      }
      let _: Bot = try read("Bot", id: generation.targetBotID)
      var conversation: Conversation = try read("Conversation", id: generation.conversationID)
      guard conversation.memberBotIDs.contains(generation.targetBotID),
        conversation.nextSequence < Int64.max
      else {
        throw WorkspaceError.invalidMembers
      }
      let provenance = Message(
        id: UUID(), conversationID: conversation.id, sequence: conversation.nextSequence,
        role: .event, speakerBotID: nil, speakerNameSnapshot: nil,
        text: "Retrying an earlier reply",
        createdAt: Date(), replyToID: generation.userMessageID, attachmentIDs: [],
        generationID: generation.id)
      conversation.nextSequence += 1
      generation.attemptID = attemptID
      generation.state = .queued
      generation.lastEventSequence = 0
      generation.error = nil
      generation.assistantMessageID = nil
      try put("Message", value: provenance)
      try put("Conversation", value: conversation)
      try put("Generation", value: generation)

    case .interruptPendingGenerations:
      for var generation in try all("Generation", as: Generation.self)
      where !generation.state.isTerminal {
        generation.state = .interrupted
        generation.error =
          "The app stopped before this reply finished. Retry explicitly to continue."
        try put("Generation", value: generation)
      }

    case .saveRoutine(let input):
      let routine = try DomainValidation.routine(input)
      let _: Bot = try read("Bot", id: routine.ownerBotID)
      if let record = try find("Routine", id: routine.id.uuidString) {
        let existing = try decode(record, as: Routine.self)
        guard existing.ownerBotID == routine.ownerBotID else {
          throw WorkspaceError.identityConflict
        }
      } else {
        try ensureIdentityAvailable(routine.id)
      }
      try put("Routine", value: routine)

    case .saveProvider(let input):
      let provider = try DomainValidation.provider(input)
      if try find("Provider", id: provider.id.uuidString) == nil {
        try ensureIdentityAvailable(provider.id)
      }
      try put("Provider", value: provider)

    case .markRead(let id, let sequence):
      var conversation: Conversation = try read("Conversation", id: id)
      guard sequence >= 0, sequence < conversation.nextSequence else {
        throw WorkspaceError.invalidPage
      }
      conversation.lastReadSequence = max(conversation.lastReadSequence, sequence)
      try put("Conversation", value: conversation)
    }
  }

  private func validateProvider(_ id: UUID?) throws {
    if let id { let _: ProviderConfig = try read("Provider", id: id) }
  }
  private func validateMembers(_ ids: [UUID], allowHidden: Bool = false) throws {
    _ = try GroupProfile(title: "Members", memberBotIDs: ids).validated()
    for id in ids {
      guard let record = try find("Bot", id: id.uuidString) else {
        throw WorkspaceError.invalidMembers
      }
      let bot = try decode(record, as: Bot.self)
      guard allowHidden || bot.hiddenAt == nil else { throw WorkspaceError.invalidMembers }
    }
  }
  private func validateEditedMembers(_ ids: [UUID], retaining existingIDs: Set<UUID>) throws {
    for id in ids {
      guard let record = try find("Bot", id: id.uuidString) else {
        throw WorkspaceError.invalidMembers
      }
      let bot = try decode(record, as: Bot.self)
      guard bot.hiddenAt == nil || existingIDs.contains(id) else {
        throw WorkspaceError.invalidMembers
      }
    }
  }
  private func validateReply(_ id: UUID?, conversationID: UUID) throws {
    guard let id else { return }
    guard let record = try find("Message", id: id.uuidString) else {
      throw WorkspaceError.invalidDraft
    }
    let message = try decode(record, as: Message.self)
    guard message.conversationID == conversationID, message.role != .event, !message.text.isEmpty
    else { throw WorkspaceError.invalidDraft }
  }
  private func ensureIdentityAvailable(_ id: UUID) throws {
    for entity in ["Bot", "Conversation", "Message", "Generation", "Routine", "Provider"] {
      if try find(entity, id: id.uuidString) != nil { throw WorkspaceError.identityConflict }
    }
  }
  private func requireOpen() throws { if closed { throw WorkspaceError.storeClosed } }
  private func metadata() throws -> NSManagedObject {
    guard let row = try find("Metadata", id: "workspace") else { throw WorkspaceError.invalidStore }
    return row
  }
  private func revision() throws -> Int64 {
    guard let revision = try metadata().value(forKey: "revision") as? Int64 else {
      throw WorkspaceError.invalidStore
    }
    return revision
  }
  private func find(_ entity: String, id: String) throws -> NSManagedObject? {
    let request = NSFetchRequest<NSManagedObject>(entityName: entity)
    request.predicate = NSPredicate(format: "id == %@", id)
    request.fetchLimit = 1
    return try context.fetch(request).first
  }
  private func read<T: Decodable>(_ entity: String, id: UUID) throws -> T {
    guard let record = try find(entity, id: id.uuidString) else {
      throw WorkspaceError.missingRecord
    }
    return try decode(record, as: T.self)
  }
  private func all<T: Decodable>(_ entity: String, as type: T.Type) throws -> [T] {
    let request = NSFetchRequest<NSManagedObject>(entityName: entity)
    request.sortDescriptors = [NSSortDescriptor(key: "id", ascending: true)]
    return try context.fetch(request).map { try decode($0, as: type) }
  }
  private func decode<T: Decodable>(_ record: NSManagedObject, as type: T.Type) throws -> T {
    guard let data = record.value(forKey: "payload") as? Data else {
      throw WorkspaceError.invalidStore
    }
    do { return try JSONDecoder().decode(type, from: data) } catch {
      throw WorkspaceError.invalidStore
    }
  }
  private func put<T: Encodable & Identifiable>(_ entity: String, value: T) throws
  where T.ID == UUID {
    let record =
      try find(entity, id: value.id.uuidString)
      ?? NSEntityDescription.insertNewObject(forEntityName: entity, into: context)
    record.setValue(value.id.uuidString, forKey: "id")
    record.setValue(try JSONEncoder().encode(value), forKey: "payload")
    if let message = value as? Message {
      record.setValue(message.conversationID.uuidString, forKey: "conversationID")
      record.setValue(message.sequence, forKey: "sequence")
      record.setValue(message.text, forKey: "searchText")
    }
  }

  /// v1 is immutable once shipped. A future version gets a separate model + explicit migration tests.
  static func modelV1() -> NSManagedObjectModel {
    let model = NSManagedObjectModel()
    model.versionIdentifiers = ["WorkspaceCore.v1"]
    var entities: [NSEntityDescription] = []
    for name in [
      "Bot", "Conversation", "Draft", "Message", "Generation", "Routine", "Provider", "Metadata",
    ] {
      let entity = NSEntityDescription()
      entity.name = name
      entity.managedObjectClassName = "NSManagedObject"
      var attributes = [attribute("id", .stringAttributeType)]
      if name == "Metadata" {
        attributes += [
          attribute("schemaVersion", .integer64AttributeType),
          attribute("revision", .integer64AttributeType),
        ]
      } else {
        attributes += [attribute("payload", .binaryDataAttributeType)]
      }
      if name == "Message" {
        attributes += [
          attribute("conversationID", .stringAttributeType),
          attribute("sequence", .integer64AttributeType),
          attribute("searchText", .stringAttributeType),
        ]
      }
      entity.properties = attributes
      entity.uniquenessConstraints = [["id"]]
      if name == "Message" {
        entity.uniquenessConstraints.append(["conversationID", "sequence"])
        entity.indexes = [
          NSFetchIndexDescription(
            name: "messageConversationSequence",
            elements: [
              NSFetchIndexElementDescription(
                property: attributes.first { $0.name == "conversationID" }!, collationType: .binary),
              NSFetchIndexElementDescription(
                property: attributes.first { $0.name == "sequence" }!, collationType: .binary),
            ])
        ]
      }
      entities.append(entity)
    }
    model.entities = entities
    return model
  }
  private static func attribute(_ name: String, _ type: NSAttributeType) -> NSAttributeDescription {
    let attribute = NSAttributeDescription()
    attribute.name = name
    attribute.attributeType = type
    attribute.isOptional = false
    return attribute
  }
}

/// Advisory process-wide lease prevents two repository owners assigning conflicting sequences.
/// Access is initialization, context-queue release, and final deinit only.
private final class StoreLease: @unchecked Sendable {
  private var descriptor: Int32
  init(url: URL) throws {
    descriptor = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw WorkspaceError.storeUnavailable }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      Darwin.close(descriptor)
      descriptor = -1
      throw WorkspaceError.storeInUse
    }
  }
  func release() {
    if descriptor >= 0 {
      flock(descriptor, LOCK_UN)
      Darwin.close(descriptor)
      descriptor = -1
    }
  }
  deinit { release() }
}
