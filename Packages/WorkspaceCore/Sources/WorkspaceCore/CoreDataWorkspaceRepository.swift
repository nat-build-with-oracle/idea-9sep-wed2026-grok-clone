@preconcurrency import CoreData
import Darwin
import Foundation
import OSLog

/// One private-queue context owns every managed object and transaction. Only Sendable DTOs escape.
/// `@unchecked` is restricted to the Core Data queue boundary, not shared mutable domain state.
public final class CoreDataWorkspaceRepository: WorkspaceRepository, @unchecked Sendable {
  private let context: NSManagedObjectContext
  private let lease: StoreLease
  // Access only within context.perform, including close and fault injection.
  private var closed = false
  private var failNextSave = false

  enum MigrationFailureForTesting { case beforeReplacement, afterReplacement }

  /// Store opening can perform disk I/O; callers should invoke this off the main actor.
  public static func open(at url: URL) async throws -> CoreDataWorkspaceRepository {
    try await Task.detached { try CoreDataWorkspaceRepository(storeURL: url) }.value
  }

  static func open(at url: URL, migrationFailureForTesting: MigrationFailureForTesting) async throws
    -> CoreDataWorkspaceRepository
  {
    try await Task.detached {
      try CoreDataWorkspaceRepository(
        storeURL: url, migrationFailureForTesting: migrationFailureForTesting)
    }.value
  }

  private init(
    storeURL: URL, migrationFailureForTesting: MigrationFailureForTesting? = nil
  ) throws {
    guard storeURL.isFileURL else { throw WorkspaceError.invalidStore }
    let canonical = storeURL.standardizedFileURL.resolvingSymlinksInPath()
    do {
      try FileManager.default.createDirectory(
        at: canonical.deletingLastPathComponent(),
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    } catch { throw WorkspaceError.storeUnavailable }
    lease = try StoreLease(url: canonical.appendingPathExtension("lock"))
    let model = Self.modelV4()
    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
    let existingStore = FileManager.default.fileExists(atPath: canonical.path)
    if existingStore {
      let metadata: [String: Any]
      do {
        metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
          ofType: NSSQLiteStoreType, at: canonical, options: [NSReadOnlyPersistentStoreOption: true]
        )
      } catch { throw WorkspaceError.invalidStore }
      if !model.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata) {
        let source: (NSManagedObjectModel, Int64)
        if Self.modelV3().isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata) {
          source = (Self.modelV3(), 3)
        } else if Self.modelV2().isConfiguration(
          withName: nil, compatibleWithStoreMetadata: metadata)
        {
          source = (Self.modelV2(), 2)
        } else if Self.modelV1().isConfiguration(
          withName: nil, compatibleWithStoreMetadata: metadata)
        {
          source = (Self.modelV1(), 1)
        } else {
          throw WorkspaceError.unsupportedSchema
        }
        try Self.migrateLegacyStore(
          at: canonical, sourceModel: source.0, sourceVersion: source.1,
          failureForTesting: migrationFailureForTesting)
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
        metadata.setValue(Int64(4), forKey: "schemaVersion")
        metadata.setValue(Int64(0), forKey: "revision")
        try context.save()
      }
      guard try self.metadata().value(forKey: "schemaVersion") as? Int64 == 4 else {
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
      let conversations = try self.all("Conversation", as: Conversation.self)
      return try WorkspaceSnapshot(
        revision: self.revision(), bots: self.all("Bot", as: Bot.self),
        conversations: conversations,
        drafts: self.all("Draft", as: Draft.self),
        generations: self.all("Generation", as: Generation.self),
        routines: self.all("Routine", as: Routine.self),
        providers: self.all("Provider", as: ProviderConfig.self),
        conversationActivity: conversations.map { try self.activity(for: $0) })
    }
  }

  public func exportSnapshot() async throws -> WorkspaceExportDocument {
    return try await context.perform {
      try self.requireOpen()
      let messages = try self.all("Message", as: Message.self)
      let drafts = try self.all("Draft", as: Draft.self)
      let referencedIDs = try self.referencedAttachmentIDs(messages: messages, drafts: drafts)
      let metadata = try referencedIDs.map { try self.readAttachmentMetadata(id: $0) }
      try self.validateAttachmentMetadataReferences(
        messages: messages, drafts: drafts, attachments: metadata)
      let encodedPayloadLowerBound = try metadata.reduce(0) { total, attachment in
        let (padded, paddingOverflow) = attachment.byteCount.addingReportingOverflow(2)
        let (base64Bytes, multiplyOverflow) = (padded / 3).multipliedReportingOverflow(by: 4)
        let (sum, sumOverflow) = total.addingReportingOverflow(base64Bytes)
        guard !paddingOverflow, !multiplyOverflow, !sumOverflow else {
          throw WorkspaceExportError.exceedsByteLimit(
            limit: WorkspaceExportDocument.defaultMaxEncodedBytes, actual: Int.max)
        }
        return sum
      }
      // The encoded attachment data alone cannot fit at this lower bound. Reject before Core Data
      // faults any binary content into memory; metadata and JSON structure add further bytes.
      guard encodedPayloadLowerBound < WorkspaceExportDocument.defaultMaxEncodedBytes else {
        throw WorkspaceExportError.exceedsByteLimit(
          limit: WorkspaceExportDocument.defaultMaxEncodedBytes,
          actual: encodedPayloadLowerBound)
      }
      let attachments = try referencedIDs.map { try self.readAttachmentContent(id: $0) }
      // Every row and the revision are captured in this single serialized Core Data turn.
      return try WorkspaceExportDocument(
        exportedAt: Date(), revision: self.revision(),
        bots: self.all("Bot", as: Bot.self),
        conversations: self.all("Conversation", as: Conversation.self),
        messages: messages, drafts: drafts,
        generations: self.all("Generation", as: Generation.self),
        routines: self.all("Routine", as: Routine.self),
        routineRuns: self.all("RoutineRun", as: RoutineRun.self),
        providers: self.all("Provider", as: ProviderConfig.self).map(WorkspaceExportProvider.init),
        attachments: attachments)
    }
  }

  public func botDeletionPlan(botID: UUID) async throws -> BotDeletionPlan {
    try await context.perform {
      try self.requireOpen()
      return try self.makeBotDeletionPlan(botID: botID)
    }
  }

  public func routineRuns(routineID: UUID?, limit: Int) async throws -> [RoutineRun] {
    guard (1...500).contains(limit) else { throw WorkspaceError.invalidPage }
    return try await context.perform {
      try self.requireOpen()
      let request = NSFetchRequest<NSManagedObject>(entityName: "RoutineRun")
      if let routineID {
        request.predicate = NSPredicate(format: "routineID == %@", routineID.uuidString)
      }
      request.sortDescriptors = [
        NSSortDescriptor(key: "createdAt", ascending: false),
        NSSortDescriptor(key: "id", ascending: false),
      ]
      request.fetchLimit = limit
      request.fetchBatchSize = limit
      return try self.context.fetch(request).map { try self.decode($0, as: RoutineRun.self) }
    }
  }

  public func routineDeletionPlan(routineID: UUID) async throws -> RoutineDeletionPlan {
    try await context.perform {
      try self.requireOpen()
      let routine: Routine = try self.read("Routine", id: routineID)
      let request = NSFetchRequest<NSManagedObject>(entityName: "RoutineRun")
      request.predicate = NSPredicate(format: "routineID == %@", routineID.uuidString)
      let runs = try self.context.fetch(request).map { try self.decode($0, as: RoutineRun.self) }
      return RoutineDeletionPlan(
        routine: routine, runIDs: Set(runs.map(\.id)),
        activeRunIDs: Set(runs.filter { !$0.status.isTerminal }.map(\.id)))
    }
  }

  public func routineRun(id: UUID) async throws -> RoutineRun {
    try await context.perform {
      try self.requireOpen()
      return try self.read("RoutineRun", id: id)
    }
  }

  public func attachments(ids: [UUID]) async throws -> [Attachment] {
    try AttachmentValidation.orderedUnique(ids)
    return try await context.perform {
      try self.requireOpen()
      return try ids.map { try self.readAttachmentMetadata(id: $0) }
    }
  }

  public func attachmentContent(id: UUID) async throws -> AttachmentContent {
    try await context.perform {
      try self.requireOpen()
      return try self.readAttachmentContent(id: id)
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

  /// Test-only corruption seam proving destructive operations refuse attachment references that
  /// the v1 store cannot otherwise create or own.
  func injectUnsupportedAttachmentReferenceForTesting(messageID: UUID) async throws {
    try await context.perform {
      try self.requireOpen()
      do {
        let message: Message = try self.read("Message", id: messageID)
        let corrupted = Message(
          id: message.id, conversationID: message.conversationID, sequence: message.sequence,
          role: message.role, speakerBotID: message.speakerBotID,
          speakerNameSnapshot: message.speakerNameSnapshot, text: message.text,
          createdAt: message.createdAt, replyToID: message.replyToID,
          attachmentIDs: [UUID()], generationID: message.generationID)
        try self.put("Message", value: corrupted)
        try self.context.save()
      } catch {
        self.context.rollback()
        throw error
      }
    }
  }

  func injectAttachmentCorruptionForTesting(id: UUID, data: Data) async throws {
    try await context.perform {
      try self.requireOpen()
      guard let record = try self.find("Attachment", id: id.uuidString) else {
        throw AttachmentError.missingAttachment
      }
      record.setValue(data, forKey: "content")
      try self.context.save()
    }
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

    case .deleteBot(let expected):
      let current = try makeBotDeletionPlan(botID: expected.botID)
      guard current.hasSameContent(as: expected) else {
        throw BotDeletionError.confirmationChanged
      }
      guard current.activeGenerationIDs.isEmpty, current.activeRoutineRunIDs.isEmpty else {
        throw BotDeletionError.activeWork
      }

      for id in current.messageIDs { try delete("Message", id: id) }
      for id in current.draftConversationIDs { try delete("Draft", id: id) }
      for id in current.generationIDs { try delete("Generation", id: id) }
      for id in current.routineRunIDs { try delete("RoutineRun", id: id) }
      for id in current.routineIDs { try delete("Routine", id: id) }
      for id in current.directConversationIDs { try delete("Conversation", id: id) }
      for id in current.attachmentIDs { try delete("Attachment", id: id) }
      for affected in current.affectedGroups {
        var group: Conversation = try read("Conversation", id: affected.id)
        group.memberBotIDs = affected.remainingMemberBotIDs
        try put("Conversation", value: group)
      }
      try delete("Bot", id: current.botID)

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
      let replacement = try replacement.validated()
      let current = GroupProfile(conversation)
      if current.memberBotIDs.count < 2 {
        // Confirmed bot deletion may intentionally leave a readable zero/one-member group. Its
        // exact stored snapshot remains a valid CAS expectation solely so the UI can repair it.
        guard current == expected else { throw WorkspaceError.editConflict }
      } else {
        guard current == (try expected.validated()) else { throw WorkspaceError.editConflict }
      }
      try validateEditedMembers(
        replacement.memberBotIDs, retaining: Set(conversation.memberBotIDs))
      conversation.title = replacement.title
      conversation.memberBotIDs = replacement.memberBotIDs
      try put("Conversation", value: conversation)

    case .saveDraft(let draft):
      let _: Conversation = try read("Conversation", id: draft.conversationID)
      let previousIDs =
        try find("Draft", id: draft.conversationID.uuidString).map {
          try decode($0, as: Draft.self).attachmentIDs
        } ?? []
      try validateAttachmentReferences(
        draft.attachmentIDs, conversationID: draft.conversationID)
      try validateReply(draft.replyToID, conversationID: draft.conversationID)
      try put("Draft", value: draft)
      try pruneUnreferencedAttachments(
        candidates: Set(previousIDs).subtracting(draft.attachmentIDs))

    case .saveDraftWithAttachments(let draft, let attachments):
      let _: Conversation = try read("Conversation", id: draft.conversationID)
      let previousIDs =
        try find("Draft", id: draft.conversationID.uuidString).map {
          try decode($0, as: Draft.self).attachmentIDs
        } ?? []
      try AttachmentValidation.orderedUnique(draft.attachmentIDs)
      let incomingIDs = attachments.map(\.attachment.id)
      try AttachmentValidation.orderedUnique(incomingIDs)
      guard Set(incomingIDs).isSubset(of: Set(draft.attachmentIDs)) else {
        throw AttachmentError.foreignAttachment
      }
      for content in attachments {
        guard content.attachment.conversationID == draft.conversationID else {
          throw AttachmentError.foreignAttachment
        }
        try AttachmentValidation.content(content.attachment, data: content.data)
        if let existing = try find("Attachment", id: content.attachment.id.uuidString) {
          let stored = try decodeAttachment(existing)
          guard stored == content else { throw AttachmentError.identityConflict }
        } else {
          try ensureIdentityAvailable(content.attachment.id)
          try putAttachment(content)
        }
      }
      try validateAttachmentReferences(
        draft.attachmentIDs, conversationID: draft.conversationID)
      try validateReply(draft.replyToID, conversationID: draft.conversationID)
      try put("Draft", value: draft)
      try pruneUnreferencedAttachments(
        candidates: Set(previousIDs).subtracting(draft.attachmentIDs))

    case .beginGeneration(let command):
      try beginGeneration(command, clearMatchingDraft: true, routineRunID: nil)

    case .cancelGeneration(let id, let attemptID):
      var generation: Generation = try read("Generation", id: id)
      guard generation.attemptID == attemptID, !generation.state.isTerminal else { return }
      generation.state = .cancelled
      try put("Generation", value: generation)
      try updateRoutineRun(
        generationID: generation.id, status: .cancelled, at: Date(), error: .cancelled)

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
      switch event.kind {
      case .started:
        try updateRoutineRun(
          generationID: generation.id, status: .running, at: event.createdAt, error: nil)
      case .completed:
        try updateRoutineRun(
          generationID: generation.id, status: .completed, at: event.createdAt, error: nil)
      case .failed(let error):
        try updateRoutineRun(
          generationID: generation.id, status: .failed, at: event.createdAt,
          error: RoutineFailureMapping.failure(error))
      case .delta: break
      }

    case .retryGeneration(let id, let attemptID):
      var generation: Generation = try read("Generation", id: id)
      guard generation.routineRunID == nil else { throw WorkspaceError.invalidRoutine }
      guard [.failed, .cancelled, .interrupted].contains(generation.state),
        generation.attemptID != attemptID
      else {
        throw WorkspaceError.identityConflict
      }
      var conversation: Conversation = try read("Conversation", id: generation.conversationID)
      if conversation.kind == .group {
        try validateMembers(conversation.memberBotIDs, allowHidden: true)
      }
      let _: Bot = try read("Bot", id: generation.targetBotID)
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
      for var run in try all("RoutineRun", as: RoutineRun.self) where !run.status.isTerminal {
        run.status = .interrupted
        run.endedAt = max(Date(), run.createdAt)
        run.error = .interrupted
        try put("RoutineRun", value: run)
      }

    case .createRoutine(let input), .saveRoutine(let input):
      if case .createRoutine = mutation { try ensureIdentityAvailable(input.id) }
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
      try validateRoutineBinding(routine.providerBinding)
      try put("Routine", value: routine)

    case .editRoutine(let expected, let replacement):
      let current: Routine = try read("Routine", id: expected.id)
      guard current == expected, replacement.id == expected.id,
        replacement.ownerBotID == expected.ownerBotID
      else { throw WorkspaceError.editConflict }
      let replacement = try DomainValidation.routine(replacement)
      if replacement.trigger != expected.trigger || replacement.timezoneID != expected.timezoneID {
        guard let replacementScheduleID = replacement.scheduleID,
          replacementScheduleID != expected.scheduleID
        else { throw WorkspaceError.invalidRoutine }
      }
      if replacement.enabled || replacement.providerBinding != expected.providerBinding {
        try validateRoutineBinding(replacement.providerBinding)
      }
      try put("Routine", value: replacement)

    case .pauseRoutineForDeletion(let expected, let expectedRunIDs):
      var current: Routine = try read("Routine", id: expected.id)
      let runs = try all("RoutineRun", as: RoutineRun.self).filter { $0.routineID == expected.id }
      guard current == expected, Set(runs.map(\.id)) == expectedRunIDs else {
        throw WorkspaceError.editConflict
      }
      current.enabled = false
      current.nextRunAt = nil
      try put("Routine", value: current)

    case .deleteRoutine(let expected, let expectedRunIDs):
      let current: Routine = try read("Routine", id: expected.id)
      guard current == expected else { throw WorkspaceError.editConflict }
      let runs = try all("RoutineRun", as: RoutineRun.self).filter {
        $0.routineID == expected.id
      }
      if let expectedRunIDs, Set(runs.map(\.id)) != expectedRunIDs {
        throw WorkspaceError.editConflict
      }
      guard runs.allSatisfy(\.status.isTerminal) else { throw BotDeletionError.activeWork }
      for run in runs { try delete("RoutineRun", id: run.id) }
      try delete("Routine", id: expected.id)

    case .claimRoutineRun(let expected, let run, let skipped, let nextRunAt):
      let current: Routine = try read("Routine", id: expected.id)
      guard current == expected else { throw WorkspaceError.editConflict }
      try validateRoutineRunClaim(
        routine: current, run: run, skipped: skipped, nextRunAt: nextRunAt)
      let existingRuns = try all("RoutineRun", as: RoutineRun.self)
      guard
        !existingRuns.contains(where: { $0.routineID == run.routineID && !$0.status.isTerminal })
      else { throw WorkspaceError.identityConflict }
      if let occurrenceID = run.occurrenceID {
        guard
          !existingRuns.contains(where: {
            $0.routineID == run.routineID && $0.occurrenceID == occurrenceID
          })
        else { throw WorkspaceError.identityConflict }
      }
      try ensureIdentityAvailable(run.id)
      if let generationID = run.generationID {
        try ensureIdentityAvailable(generationID)
        guard !existingRuns.contains(where: { $0.generationID == generationID }) else {
          throw WorkspaceError.identityConflict
        }
      }
      if let skipped {
        guard skipped.id != run.id, skipped.id != run.generationID else {
          throw WorkspaceError.identityConflict
        }
        try ensureIdentityAvailable(skipped.id)
        try put("RoutineRun", value: skipped)
      }
      try put("RoutineRun", value: run)
      if run.occurrenceID != nil {
        var updated = current
        updated.nextRunAt = nextRunAt
        try put("Routine", value: updated)
      }

    case .beginRoutineGeneration(let runID, let command):
      var run: RoutineRun = try read("RoutineRun", id: runID)
      guard run.status == .queued, run.generationID == command.generationID,
        run.ownerBotID == command.targetBotID, run.conversationID == command.conversationID,
        run.prompt == command.text, command.replyToID == nil, command.attachmentIDs.isEmpty
      else { throw WorkspaceError.invalidRoutine }
      guard let binding = run.providerBinding else { throw WorkspaceError.invalidProvider }
      let provider: ProviderConfig = try read("Provider", id: binding.providerID)
      guard binding.matches(provider) else { throw WorkspaceError.invalidProvider }
      try beginGeneration(command, clearMatchingDraft: false, routineRunID: runID)
      run.error = nil
      try put("RoutineRun", value: run)

    case .finishRoutineRun(let id, let status, let at, let error):
      var run: RoutineRun = try read("RoutineRun", id: id)
      guard run.status == .queued,
        [.failed, .cancelled, .interrupted, .blocked].contains(status),
        try run.generationID.map({ try find("Generation", id: $0.uuidString) == nil }) ?? true
      else { throw WorkspaceError.invalidRoutine }
      guard error != nil else { throw WorkspaceError.invalidRoutine }
      run.status = status
      run.endedAt = max(at, run.createdAt)
      run.error = error
      try put("RoutineRun", value: run)

    case .cancelRoutineRun(let id, let at):
      var run: RoutineRun = try read("RoutineRun", id: id)
      guard !run.status.isTerminal else { return }
      if let generationID = run.generationID,
        let record = try find("Generation", id: generationID.uuidString)
      {
        var generation = try decode(record, as: Generation.self)
        if !generation.state.isTerminal {
          generation.state = .cancelled
          try put("Generation", value: generation)
        }
      }
      run.status = .cancelled
      run.endedAt = max(at, run.createdAt)
      run.error = .cancelled
      try put("RoutineRun", value: run)

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

  private func beginGeneration(
    _ command: SendCommand, clearMatchingDraft: Bool, routineRunID: UUID?
  ) throws {
    var conversation: Conversation = try read("Conversation", id: command.conversationID)
    let text = command.text.trimmingCharacters(in: .whitespacesAndNewlines)
    try validateAttachmentReferences(
      command.attachmentIDs, conversationID: command.conversationID)
    guard !text.isEmpty || !command.attachmentIDs.isEmpty else { throw WorkspaceError.invalidDraft }
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
    let reservedRun = try all("RoutineRun", as: RoutineRun.self).first {
      $0.generationID == command.generationID
    }
    guard reservedRun?.id == routineRunID else { throw WorkspaceError.identityConflict }
    try ensureIdentityAvailable(command.userMessageID)
    try ensureIdentityAvailable(command.generationID)
    try validateReply(command.replyToID, conversationID: conversation.id)
    guard conversation.nextSequence < Int64.max else { throw WorkspaceError.invalidStore }
    let message = Message(
      id: command.userMessageID, conversationID: conversation.id,
      sequence: conversation.nextSequence, role: .user, speakerBotID: nil,
      speakerNameSnapshot: nil, text: text, createdAt: command.createdAt,
      replyToID: command.replyToID, attachmentIDs: command.attachmentIDs,
      generationID: command.generationID)
    let generation = Generation(
      id: command.generationID, conversationID: conversation.id,
      userMessageID: command.userMessageID, attemptID: command.attemptID,
      targetBotID: command.targetBotID, state: .queued, lastEventSequence: 0, error: nil,
      routineRunID: routineRunID)
    conversation.nextSequence += 1
    try put("Message", value: message)
    try put("Generation", value: generation)
    try put("Conversation", value: conversation)
    guard clearMatchingDraft, let record = try find("Draft", id: conversation.id.uuidString) else {
      return
    }
    let draft = try decode(record, as: Draft.self)
    if draft.text.trimmingCharacters(in: .whitespacesAndNewlines) == text,
      draft.replyToID == command.replyToID, draft.attachmentIDs == command.attachmentIDs
    {
      context.delete(record)
    }
  }

  private func validateRoutineBinding(_ binding: RoutineProviderBinding?) throws {
    guard let binding else { return }
    let provider: ProviderConfig = try read("Provider", id: binding.providerID)
    guard binding.matches(provider) else { throw WorkspaceError.invalidProvider }
  }

  private func validateRoutineRunClaim(
    routine: Routine, run: RoutineRun, skipped: RoutineRun?, nextRunAt: Date?
  ) throws {
    guard run.routineID == routine.id, run.ownerBotID == routine.ownerBotID,
      run.name == routine.name, run.prompt == routine.prompt,
      run.providerBinding == routine.providerBinding, run.status == .queued,
      run.generationID != nil, run.startedAt == nil, run.endedAt == nil, run.error == nil,
      run.skippedCount == 0, run.firstSkippedAt == nil, run.lastSkippedAt == nil
    else { throw WorkspaceError.invalidRoutine }
    let conversation: Conversation = try read("Conversation", id: run.conversationID)
    guard conversation.kind == .direct, conversation.memberBotIDs == [routine.ownerBotID] else {
      throw WorkspaceError.invalidRoutine
    }
    if let occurrenceID = run.occurrenceID {
      guard routine.enabled, let first = routine.nextRunAt, let scheduledAt = run.scheduledAt,
        let window = try RoutineSchedule.due(
          from: first, through: run.createdAt, trigger: routine.trigger,
          timezoneID: routine.timezoneID),
        scheduledAt == window.latest, nextRunAt == window.next,
        occurrenceID
          == (try RoutineSchedule.occurrenceID(
            scheduleID: routine.scheduleID ?? routine.id, at: window.latest,
            trigger: routine.trigger, timezoneID: routine.timezoneID))
      else { throw WorkspaceError.invalidRoutine }
      try validateSkippedRun(skipped, routine: routine, execution: run, window: window)
    } else {
      guard run.scheduledAt == nil, nextRunAt == nil, skipped == nil else {
        throw WorkspaceError.invalidRoutine
      }
    }
  }

  private func validateSkippedRun(
    _ skipped: RoutineRun?, routine: Routine, execution: RoutineRun, window: RoutineDueWindow
  ) throws {
    guard window.skippedCount > 0 else {
      guard skipped == nil else { throw WorkspaceError.invalidRoutine }
      return
    }
    guard let skipped, skipped.routineID == routine.id,
      skipped.ownerBotID == routine.ownerBotID,
      skipped.conversationID == execution.conversationID, skipped.name == routine.name,
      skipped.prompt == routine.prompt, skipped.providerBinding == routine.providerBinding,
      skipped.occurrenceID == nil, skipped.scheduledAt == nil,
      skipped.createdAt == execution.createdAt, skipped.generationID == nil,
      skipped.status == .skipped, skipped.startedAt == nil,
      skipped.endedAt == execution.createdAt, skipped.error == .supersededOccurrence,
      skipped.skippedCount == window.skippedCount,
      skipped.firstSkippedAt == window.firstSkippedAt,
      skipped.lastSkippedAt == window.lastSkippedAt
    else { throw WorkspaceError.invalidRoutine }
  }

  private func updateRoutineRun(
    generationID: UUID, status: RoutineRun.Status, at: Date, error: RoutineRun.Failure?
  ) throws {
    guard
      var run = try all("RoutineRun", as: RoutineRun.self).first(where: {
        $0.generationID == generationID
      })
    else { return }
    guard !run.status.isTerminal else { return }
    run.status = status
    if status == .running {
      run.startedAt = run.startedAt ?? max(at, run.createdAt)
    } else if status.isTerminal {
      run.endedAt = max(at, run.createdAt)
    }
    run.error = error
    try put("RoutineRun", value: run)
  }

  private func validateProvider(_ id: UUID?) throws {
    if let id { let _: ProviderConfig = try read("Provider", id: id) }
  }
  private func makeBotDeletionPlan(botID: UUID) throws -> BotDeletionPlan {
    let bot: Bot = try read("Bot", id: botID)
    let conversations = try all("Conversation", as: Conversation.self)
    let directConversations = conversations.filter {
      $0.kind == .direct && $0.memberBotIDs.contains(botID)
    }
    let directIDs = Set(directConversations.map(\.id))
    let allMessages = try all("Message", as: Message.self)
    let allDrafts = try all("Draft", as: Draft.self)
    let allAttachmentIDs = try referencedAttachmentIDs(messages: allMessages, drafts: allDrafts)
    let allAttachmentMetadata = try allAttachmentIDs.map { try readAttachmentMetadata(id: $0) }
    try validateAttachmentMetadataReferences(
      messages: allMessages, drafts: allDrafts, attachments: allAttachmentMetadata)
    let messages = allMessages.filter {
      directIDs.contains($0.conversationID)
    }
    let drafts = allDrafts.filter {
      directIDs.contains($0.conversationID)
    }
    let removedReferenceIDs = Set(
      messages.flatMap(\.attachmentIDs) + drafts.flatMap(\.attachmentIDs))
    let survivingReferenceIDs = Set(
      allMessages.filter { !directIDs.contains($0.conversationID) }
        .flatMap(\.attachmentIDs)
        + allDrafts.filter { !directIDs.contains($0.conversationID) }
        .flatMap(\.attachmentIDs))
    let deletedAttachmentIDs = sortedIDs(
      Array(removedReferenceIDs.subtracting(survivingReferenceIDs)))
    var attachmentBytes = 0
    for id in deletedAttachmentIDs {
      let content = try readAttachmentContent(id: id)
      let (sum, overflow) = attachmentBytes.addingReportingOverflow(content.attachment.byteCount)
      guard !overflow else { throw WorkspaceError.invalidStore }
      attachmentBytes = sum
    }

    let generations = try all("Generation", as: Generation.self)
    let deletedGenerations = generations.filter { directIDs.contains($0.conversationID) }
    let routines = try all("Routine", as: Routine.self).filter { $0.ownerBotID == botID }
    let routineIDs = Set(routines.map(\.id))
    let routineRuns = try all("RoutineRun", as: RoutineRun.self).filter {
      $0.ownerBotID == botID || routineIDs.contains($0.routineID)
    }
    let activeRoutineRuns = routineRuns.filter { !$0.status.isTerminal }
    let groups = conversations.filter {
      $0.kind == .group && $0.memberBotIDs.contains(botID)
    }.map {
      BotDeletionPlan.AffectedGroup(
        id: $0.id, title: $0.title,
        remainingMemberBotIDs: $0.memberBotIDs.filter { $0 != botID })
    }
    let initialCancellationIDs = Set(directConversations.map(\.id) + groups.map(\.id))
    let activeGenerations = generations.filter {
      !$0.state.isTerminal
        && ($0.targetBotID == botID || initialCancellationIDs.contains($0.conversationID))
    }
    let cancellationConversationIDs = initialCancellationIDs.union(
      activeGenerations.map(\.conversationID))

    return BotDeletionPlan(
      botID: bot.id, name: bot.name,
      directConversationIDs: sortedIDs(directConversations.map(\.id)),
      messageIDs: sortedIDs(messages.map(\.id)),
      draftConversationIDs: sortedIDs(drafts.map(\.conversationID)),
      generationIDs: sortedIDs(deletedGenerations.map(\.id)),
      routineIDs: sortedIDs(routines.map(\.id)),
      affectedGroups: groups.sorted { $0.id.uuidString < $1.id.uuidString },
      activeGenerationIDs: sortedIDs(activeGenerations.map(\.id)),
      cancellationConversationIDs: sortedIDs(Array(cancellationConversationIDs)),
      routineRunIDs: sortedIDs(routineRuns.map(\.id)),
      activeRoutineRunIDs: sortedIDs(activeRoutineRuns.map(\.id)),
      attachmentIDs: deletedAttachmentIDs, attachmentBytes: attachmentBytes)
  }

  private func sortedIDs(_ ids: [UUID]) -> [UUID] {
    ids.sorted { $0.uuidString < $1.uuidString }
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
    guard message.conversationID == conversationID, message.role != .event,
      !message.text.isEmpty || !message.attachmentIDs.isEmpty
    else { throw WorkspaceError.invalidDraft }
  }
  private func ensureIdentityAvailable(_ id: UUID) throws {
    for entity in [
      "Bot", "Conversation", "Message", "Generation", "Routine", "RoutineRun", "Provider",
      "Attachment",
    ] {
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
  private func activity(for conversation: Conversation) throws -> ConversationActivity {
    let latestRequest = NSFetchRequest<NSManagedObject>(entityName: "Message")
    latestRequest.predicate = NSPredicate(
      format: "conversationID == %@", conversation.id.uuidString)
    latestRequest.sortDescriptors = [NSSortDescriptor(key: "sequence", ascending: false)]
    latestRequest.fetchLimit = 1
    let latest = try context.fetch(latestRequest).first.map { try decode($0, as: Message.self) }

    let unreadRequest = NSFetchRequest<NSManagedObject>(entityName: "Message")
    unreadRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
      NSPredicate(format: "conversationID == %@", conversation.id.uuidString),
      NSPredicate(format: "messageRole == %@", Message.Role.assistant.rawValue),
      NSPredicate(format: "sequence > %lld", conversation.lastReadSequence),
    ])
    let unreadCount = try context.count(for: unreadRequest)
    guard unreadCount != NSNotFound else { throw WorkspaceError.invalidStore }
    return ConversationActivity(
      conversationID: conversation.id, latestSequence: latest?.sequence ?? 0,
      latestMessageID: latest?.id, latestMessageTextByteCount: latest?.text.utf8.count ?? 0,
      lastMessagePreview: latest.flatMap(Self.preview), lastMessageAt: latest?.createdAt,
      unreadAssistantCount: unreadCount)
  }

  private static func preview(_ message: Message) -> String? {
    let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
    if !text.isEmpty { return String(text.prefix(160)) }
    guard !message.attachmentIDs.isEmpty else { return nil }
    return message.attachmentIDs.count == 1 ? "Text attachment" : "Text attachments"
  }
  private func find(_ entity: String, id: String) throws -> NSManagedObject? {
    let request = NSFetchRequest<NSManagedObject>(entityName: entity)
    request.predicate = NSPredicate(format: "id == %@", id)
    request.fetchLimit = 1
    return try context.fetch(request).first
  }
  private func delete(_ entity: String, id: UUID) throws {
    guard let record = try find(entity, id: id.uuidString) else {
      throw WorkspaceError.missingRecord
    }
    context.delete(record)
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
  private func readAttachmentMetadata(id: UUID) throws -> Attachment {
    let payload: Data
    if let inserted = context.insertedObjects.first(where: {
      $0.entity.name == "Attachment" && $0.value(forKey: "id") as? String == id.uuidString
    }) {
      guard let value = inserted.value(forKey: "payload") as? Data else {
        throw AttachmentError.corruptAttachment
      }
      payload = value
    } else {
      let request = NSFetchRequest<NSDictionary>(entityName: "Attachment")
      request.resultType = .dictionaryResultType
      request.propertiesToFetch = ["payload"]
      request.predicate = NSPredicate(format: "id == %@", id.uuidString)
      request.fetchLimit = 1
      request.includesPendingChanges = false
      guard let value = try context.fetch(request).first?["payload"] as? Data else {
        throw AttachmentError.missingAttachment
      }
      payload = value
    }
    let attachment: Attachment
    do { attachment = try JSONDecoder().decode(Attachment.self, from: payload) } catch {
      throw AttachmentError.corruptAttachment
    }
    guard attachment.id == id else { throw AttachmentError.corruptAttachment }
    try AttachmentValidation.metadata(attachment)
    return attachment
  }
  private func readAttachmentContent(id: UUID) throws -> AttachmentContent {
    guard let record = try find("Attachment", id: id.uuidString) else {
      throw AttachmentError.missingAttachment
    }
    return try decodeAttachment(record)
  }
  private func decodeAttachment(_ record: NSManagedObject) throws -> AttachmentContent {
    guard let idString = record.value(forKey: "id") as? String, let id = UUID(uuidString: idString),
      let data = record.value(forKey: "content") as? Data
    else { throw AttachmentError.corruptAttachment }
    let attachment = try readAttachmentMetadata(id: id)
    return try AttachmentContent(attachment: attachment, data: data)
  }
  private func putAttachment(_ content: AttachmentContent) throws {
    let attachment = content.attachment
    try AttachmentValidation.content(attachment, data: content.data)
    let record = NSEntityDescription.insertNewObject(forEntityName: "Attachment", into: context)
    record.setValue(attachment.id.uuidString, forKey: "id")
    record.setValue(try JSONEncoder().encode(attachment), forKey: "payload")
    record.setValue(content.data, forKey: "content")
  }
  private func validateAttachmentReferences(_ ids: [UUID], conversationID: UUID) throws {
    try AttachmentValidation.orderedUnique(ids)
    var total = 0
    for id in ids {
      let content = try readAttachmentContent(id: id)
      guard content.attachment.conversationID == conversationID else {
        throw AttachmentError.foreignAttachment
      }
      let (sum, overflow) = total.addingReportingOverflow(content.attachment.byteCount)
      guard !overflow, sum <= AttachmentLimits.maxDraftBytes else {
        throw AttachmentError.draftTooLarge
      }
      total = sum
    }
  }
  private func referencedAttachmentIDs(messages: [Message], drafts: [Draft]) throws -> [UUID] {
    let references = messages.flatMap(\.attachmentIDs) + drafts.flatMap(\.attachmentIDs)
    return Set(references).sorted { $0.uuidString < $1.uuidString }
  }
  private func validateAttachmentMetadataReferences(
    messages: [Message], drafts: [Draft], attachments: [Attachment]
  ) throws {
    let byID = Dictionary(uniqueKeysWithValues: attachments.map { ($0.id, $0) })
    for (conversationID, ids) in messages.map({ ($0.conversationID, $0.attachmentIDs) })
      + drafts.map({ ($0.conversationID, $0.attachmentIDs) })
    {
      try AttachmentValidation.orderedUnique(ids)
      var total = 0
      for id in ids {
        guard let attachment = byID[id] else { throw AttachmentError.missingAttachment }
        guard attachment.conversationID == conversationID else {
          throw AttachmentError.foreignAttachment
        }
        let (sum, overflow) = total.addingReportingOverflow(attachment.byteCount)
        guard !overflow, sum <= AttachmentLimits.maxDraftBytes else {
          throw AttachmentError.draftTooLarge
        }
        total = sum
      }
    }
  }
  private func pruneUnreferencedAttachments(candidates: Set<UUID>) throws {
    guard !candidates.isEmpty else { return }
    let messages = try all("Message", as: Message.self)
    let drafts = try all("Draft", as: Draft.self)
    let referenced = Set(messages.flatMap(\.attachmentIDs) + drafts.flatMap(\.attachmentIDs))
    for id in candidates where !referenced.contains(id) {
      guard let record = try find("Attachment", id: id.uuidString) else {
        throw AttachmentError.missingAttachment
      }
      context.delete(record)
    }
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
      record.setValue(message.role.rawValue, forKey: "messageRole")
    } else if let run = value as? RoutineRun {
      record.setValue(run.routineID.uuidString, forKey: "routineID")
      record.setValue(run.createdAt, forKey: "createdAt")
    }
  }

  private static func migrateLegacyStore(
    at sourceURL: URL, sourceModel: NSManagedObjectModel, sourceVersion: Int64,
    failureForTesting: MigrationFailureForTesting?
  ) throws {
    let directory = sourceURL.deletingLastPathComponent()
    let token = UUID().uuidString
    let migratedURL = directory.appendingPathComponent(".workspace-migration-\(token).sqlite")
    let backupURL = directory.appendingPathComponent(".workspace-recovery-\(token).sqlite")
    let destinationModel = modelV4()
    let fileManager = FileManager.default
    var preserveBackup = false
    defer {
      var cleanupURLs = [migratedURL]
      if !preserveBackup { cleanupURLs.append(backupURL) }
      for url in cleanupURLs {
        try? fileManager.removeItem(at: url)
        try? fileManager.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
        try? fileManager.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
      }
    }
    do {
      try validateLegacyStore(at: sourceURL, model: sourceModel, version: sourceVersion)
      let mapping = try NSMappingModel.inferredMappingModel(
        forSourceModel: sourceModel, destinationModel: destinationModel)
      let manager = NSMigrationManager(sourceModel: sourceModel, destinationModel: destinationModel)
      try manager.migrateStore(
        from: sourceURL, sourceType: NSSQLiteStoreType,
        options: [NSReadOnlyPersistentStoreOption: true],
        with: mapping, toDestinationURL: migratedURL, destinationType: NSSQLiteStoreType,
        destinationOptions: nil)
      try setMigratedSchemaVersionAndValidate(
        at: migratedURL, model: destinationModel, sourceVersion: sourceVersion)
      if failureForTesting == .beforeReplacement { throw WorkspaceError.storeUnavailable }

      let replacement = NSPersistentStoreCoordinator(managedObjectModel: destinationModel)
      try replacement.replacePersistentStore(
        at: backupURL, destinationOptions: nil, withPersistentStoreFrom: sourceURL,
        sourceOptions: [NSReadOnlyPersistentStoreOption: true], type: .sqlite)
      do {
        try replacement.replacePersistentStore(
          at: sourceURL, destinationOptions: nil, withPersistentStoreFrom: migratedURL,
          sourceOptions: [NSReadOnlyPersistentStoreOption: true], type: .sqlite)
        if failureForTesting == .afterReplacement { throw WorkspaceError.storeUnavailable }
      } catch {
        do {
          try replacement.replacePersistentStore(
            at: sourceURL, destinationOptions: nil, withPersistentStoreFrom: backupURL,
            sourceOptions: [NSReadOnlyPersistentStoreOption: true], type: .sqlite)
        } catch {
          // Preserve the consistent recovery store for manual recovery rather than deleting it.
          preserveBackup = true
          Logger(subsystem: "WorkspaceCore", category: "Migration").error(
            "Automatic restoration failed; preserved recovery store \(backupURL.lastPathComponent, privacy: .public)"
          )
          throw WorkspaceError.storeUnavailable
        }
        throw error
      }
    } catch let error as WorkspaceError {
      throw error
    } catch {
      throw WorkspaceError.storeUnavailable
    }
  }

  private static func validateLegacyStore(
    at url: URL, model: NSManagedObjectModel, version: Int64
  ) throws {
    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
    let store = try coordinator.addPersistentStore(
      ofType: NSSQLiteStoreType, configurationName: nil, at: url,
      options: [NSReadOnlyPersistentStoreOption: true])
    defer { try? coordinator.remove(store) }
    let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
    context.persistentStoreCoordinator = coordinator
    try context.performAndWait {
      let metadataRequest = NSFetchRequest<NSManagedObject>(entityName: "Metadata")
      metadataRequest.predicate = NSPredicate(format: "id == %@", "workspace")
      metadataRequest.fetchLimit = 2
      let metadata = try context.fetch(metadataRequest)
      guard metadata.count == 1,
        metadata[0].value(forKey: "schemaVersion") as? Int64 == version
      else { throw WorkspaceError.unsupportedSchema }

      var entities = [
        "Bot", "Conversation", "Draft", "Message", "Generation", "Routine", "Provider",
      ]
      if version >= 2 { entities.append("RoutineRun") }
      if version >= 3 { entities.append("Attachment") }
      for entity in entities {
        let request = NSFetchRequest<NSManagedObject>(entityName: entity)
        for record in try context.fetch(request) {
          guard let payload = record.value(forKey: "payload") as? Data else {
            throw WorkspaceError.invalidStore
          }
          try validateLegacyPayload(payload, entity: entity, allowsAttachments: version >= 3)
        }
      }
    }
  }

  private static func validateLegacyPayload(
    _ payload: Data, entity: String, allowsAttachments: Bool
  ) throws {
    let decoder = JSONDecoder()
    do {
      switch entity {
      case "Bot": _ = try decoder.decode(Bot.self, from: payload)
      case "Conversation": _ = try decoder.decode(Conversation.self, from: payload)
      case "Draft":
        let draft = try decoder.decode(Draft.self, from: payload)
        guard allowsAttachments || draft.attachmentIDs.isEmpty else {
          throw WorkspaceError.invalidStore
        }
      case "Message":
        let message = try decoder.decode(Message.self, from: payload)
        guard allowsAttachments || message.attachmentIDs.isEmpty else {
          throw WorkspaceError.invalidStore
        }
      case "Generation": _ = try decoder.decode(Generation.self, from: payload)
      case "Routine": _ = try decoder.decode(Routine.self, from: payload)
      case "Provider": _ = try decoder.decode(ProviderConfig.self, from: payload)
      case "RoutineRun": _ = try decoder.decode(RoutineRun.self, from: payload)
      case "Attachment": _ = try decoder.decode(Attachment.self, from: payload)
      default: throw WorkspaceError.invalidStore
      }
    } catch let error as WorkspaceError {
      throw error
    } catch {
      throw WorkspaceError.invalidStore
    }
  }

  private static func setMigratedSchemaVersionAndValidate(
    at url: URL, model: NSManagedObjectModel, sourceVersion: Int64
  ) throws {
    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
    let store = try coordinator.addPersistentStore(
      ofType: NSSQLiteStoreType, configurationName: nil, at: url,
      options: [NSMigratePersistentStoresAutomaticallyOption: false])
    defer { try? coordinator.remove(store) }
    let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
    context.persistentStoreCoordinator = coordinator
    try context.performAndWait {
      let request = NSFetchRequest<NSManagedObject>(entityName: "Metadata")
      request.predicate = NSPredicate(format: "id == %@", "workspace")
      request.fetchLimit = 1
      guard let metadata = try context.fetch(request).first else {
        throw WorkspaceError.invalidStore
      }
      guard metadata.value(forKey: "schemaVersion") as? Int64 == sourceVersion else {
        throw WorkspaceError.unsupportedSchema
      }
      metadata.setValue(Int64(4), forKey: "schemaVersion")
      var entities = [
        "Bot", "Conversation", "Draft", "Message", "Generation", "Routine", "Provider",
      ]
      if sourceVersion >= 2 { entities.append("RoutineRun") }
      if sourceVersion >= 3 { entities.append("Attachment") }
      for entity in entities {
        let request = NSFetchRequest<NSManagedObject>(entityName: entity)
        for record in try context.fetch(request) {
          guard record.value(forKey: "payload") is Data else { throw WorkspaceError.invalidStore }
        }
      }
      let messages = NSFetchRequest<NSManagedObject>(entityName: "Message")
      for record in try context.fetch(messages) {
        guard let payload = record.value(forKey: "payload") as? Data,
          let message = try? JSONDecoder().decode(Message.self, from: payload)
        else { throw WorkspaceError.invalidStore }
        record.setValue(message.role.rawValue, forKey: "messageRole")
      }
      try context.save()
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

  static func modelV2() -> NSManagedObjectModel {
    let model = NSManagedObjectModel()
    model.versionIdentifiers = ["WorkspaceCore.v2"]
    var entities: [NSEntityDescription] = []
    for name in [
      "Bot", "Conversation", "Draft", "Message", "Generation", "Routine", "RoutineRun",
      "Provider", "Metadata",
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
      } else if name == "RoutineRun" {
        attributes += [
          attribute("routineID", .stringAttributeType),
          attribute("createdAt", .dateAttributeType),
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
                property: attributes.first { $0.name == "conversationID" }!,
                collationType: .binary),
              NSFetchIndexElementDescription(
                property: attributes.first { $0.name == "sequence" }!, collationType: .binary),
            ])
        ]
      } else if name == "RoutineRun" {
        entity.indexes = [
          NSFetchIndexDescription(
            name: "routineRunRoutineCreatedAt",
            elements: [
              NSFetchIndexElementDescription(
                property: attributes.first { $0.name == "routineID" }!, collationType: .binary),
              NSFetchIndexElementDescription(
                property: attributes.first { $0.name == "createdAt" }!, collationType: .binary),
            ])
        ]
      }
      entities.append(entity)
    }
    model.entities = entities
    return model
  }
  static func modelV3() -> NSManagedObjectModel {
    let model = NSManagedObjectModel()
    model.versionIdentifiers = ["WorkspaceCore.v3"]
    var entities: [NSEntityDescription] = []
    for name in [
      "Bot", "Conversation", "Draft", "Message", "Generation", "Routine", "RoutineRun",
      "Provider", "Attachment", "Metadata",
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
      } else if name == "RoutineRun" {
        attributes += [
          attribute("routineID", .stringAttributeType),
          attribute("createdAt", .dateAttributeType),
        ]
      } else if name == "Attachment" {
        let content = attribute("content", .binaryDataAttributeType)
        content.allowsExternalBinaryDataStorage = true
        attributes += [content]
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
      } else if name == "RoutineRun" {
        entity.indexes = [
          NSFetchIndexDescription(
            name: "routineRunRoutineCreatedAt",
            elements: [
              NSFetchIndexElementDescription(
                property: attributes.first { $0.name == "routineID" }!, collationType: .binary),
              NSFetchIndexElementDescription(
                property: attributes.first { $0.name == "createdAt" }!, collationType: .binary),
            ])
        ]
      }
      entities.append(entity)
    }
    model.entities = entities
    return model
  }
  /// v4 is structurally derived from frozen v3 and adds an indexed message role query field.
  static func modelV4() -> NSManagedObjectModel {
    let model = modelV3().copy() as! NSManagedObjectModel
    model.versionIdentifiers = ["WorkspaceCore.v4"]
    guard let message = model.entitiesByName["Message"] else { return model }
    let role = attribute("messageRole", .stringAttributeType)
    role.defaultValue = ""
    message.properties.append(role)
    message.indexes.append(
      NSFetchIndexDescription(
        name: "messageConversationRoleSequence",
        elements: [
          NSFetchIndexElementDescription(
            property: message.attributesByName["conversationID"]!, collationType: .binary),
          NSFetchIndexElementDescription(property: role, collationType: .binary),
          NSFetchIndexElementDescription(
            property: message.attributesByName["sequence"]!, collationType: .binary),
        ]))
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
