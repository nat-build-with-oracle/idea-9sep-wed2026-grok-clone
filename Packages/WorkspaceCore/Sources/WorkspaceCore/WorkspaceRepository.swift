import Foundation

public struct GenerationEvent: Sendable {
  public enum Kind: Sendable {
    case started
    case delta(String)
    case completed
    case failed(ProviderError)
  }
  public let generationID: UUID
  public let attemptID: UUID
  public let sequence: Int64
  public let kind: Kind
  public let createdAt: Date
  public init(
    generationID: UUID, attemptID: UUID, sequence: Int64, kind: Kind, createdAt: Date = Date()
  ) {
    self.generationID = generationID
    self.attemptID = attemptID
    self.sequence = sequence
    self.kind = kind
    self.createdAt = createdAt
  }
}

public struct SendCommand: Sendable {
  public let conversationID: UUID
  public let userMessageID: UUID
  public let generationID: UUID
  public let attemptID: UUID
  public let targetBotID: UUID
  public let text: String
  public let replyToID: UUID?
  public let attachmentIDs: [UUID]
  public let createdAt: Date
  /// Transient source body used only to decide whether the captured draft may be cleared.
  /// This is intentionally not persisted or sent to a provider.
  public let expectedDraftText: String?

  public init(
    conversationID: UUID, userMessageID: UUID = UUID(), generationID: UUID = UUID(),
    attemptID: UUID = UUID(), targetBotID: UUID, text: String, replyToID: UUID? = nil,
    attachmentIDs: [UUID] = [],
    createdAt: Date = Date(), expectedDraftText: String? = nil
  ) {
    self.conversationID = conversationID
    self.userMessageID = userMessageID
    self.generationID = generationID
    self.attemptID = attemptID
    self.targetBotID = targetBotID
    self.text = text
    self.replyToID = replyToID
    self.attachmentIDs = attachmentIDs
    self.createdAt = createdAt
    self.expectedDraftText = expectedDraftText
  }
}

public struct SendRoundCommand: Sendable {
  public struct Target: Sendable {
    public let targetBotID: UUID
    public let generationID: UUID
    public let attemptID: UUID

    public init(
      targetBotID: UUID, generationID: UUID = UUID(), attemptID: UUID = UUID()
    ) {
      self.targetBotID = targetBotID
      self.generationID = generationID
      self.attemptID = attemptID
    }
  }

  public let conversationID: UUID
  public let userMessageID: UUID
  public let text: String
  public let replyToID: UUID?
  public let attachmentIDs: [UUID]
  public let createdAt: Date
  public let targets: [Target]
  /// Transient source body used only to decide whether the captured draft may be cleared.
  /// This is intentionally not persisted or sent to a provider.
  public let expectedDraftText: String?

  public init(
    conversationID: UUID, userMessageID: UUID = UUID(), targets: [Target], text: String,
    replyToID: UUID? = nil, attachmentIDs: [UUID] = [], createdAt: Date = Date(),
    expectedDraftText: String? = nil
  ) {
    self.conversationID = conversationID
    self.userMessageID = userMessageID
    self.text = text
    self.replyToID = replyToID
    self.attachmentIDs = attachmentIDs
    self.createdAt = createdAt
    self.targets = targets
    self.expectedDraftText = expectedDraftText
  }
}

public enum WorkspaceMutation: Sendable {
  /// Caller retains both IDs across retries. They must differ and must not already exist.
  case createBot(Bot, conversationID: UUID)
  case updateBot(Bot)
  /// Atomically replaces only editable bot fields when they still match `expected`.
  case editBot(id: UUID, expected: BotProfile, replacement: BotProfile)
  case setHidden(botID: UUID, at: Date?)
  /// Deletes only after the persisted destructive impact still matches the confirmed plan.
  case deleteBot(expected: BotDeletionPlan)
  case createGroup(Conversation)
  case updateGroup(id: UUID, title: String, members: [UUID])
  /// Atomically replaces only editable group fields when they still match `expected`.
  case editGroup(id: UUID, expected: GroupProfile, replacement: GroupProfile)
  case saveDraft(Draft)
  case saveDraftWithAttachments(Draft, attachments: [AttachmentContent])
  /// Commits user message, initial generation, sequence allocation and draft clear in one save.
  /// Transport is deliberately outside the repository; this does not itself contact any provider.
  case beginGeneration(SendCommand)
  /// Atomically commits one user message and one ordered queued generation per target.
  case beginGenerationRound(SendRoundCommand)
  case cancelGeneration(id: UUID, attemptID: UUID)
  /// Atomically cancels the nonterminal ordinary generations linked to one user round.
  case cancelGenerationRound(userMessageID: UUID)
  case applyGenerationEvent(GenerationEvent)
  case retryGeneration(id: UUID, attemptID: UUID)
  case interruptPendingGenerations
  case createRoutine(Routine)
  case saveRoutine(Routine)
  case editRoutine(expected: Routine, replacement: Routine)
  case deleteRoutine(expected: Routine, expectedRunIDs: Set<UUID>? = nil)
  /// Stops future claims only after the displayed definition/history still match.
  case pauseRoutineForDeletion(expected: Routine, expectedRunIDs: Set<UUID>)
  case claimRoutineRun(
    expected: Routine, run: RoutineRun, skipped: RoutineRun?, nextRunAt: Date?)
  case beginRoutineGeneration(runID: UUID, command: SendCommand)
  case finishRoutineRun(
    id: UUID, status: RoutineRun.Status, at: Date, error: RoutineRun.Failure?)
  case cancelRoutineRun(id: UUID, at: Date)
  case saveProvider(ProviderConfig)
  case markRead(conversationID: UUID, throughSequence: Int64)
}

public protocol WorkspaceRepository: Sendable {
  func snapshot() async throws -> WorkspaceSnapshot
  func exportSnapshot() async throws -> WorkspaceExportDocument
  func botDeletionPlan(botID: UUID) async throws -> BotDeletionPlan
  func routineRuns(routineID: UUID?, limit: Int) async throws -> [RoutineRun]
  func routineDeletionPlan(routineID: UUID) async throws -> RoutineDeletionPlan
  func routineRun(id: UUID) async throws -> RoutineRun
  func attachments(ids: [UUID]) async throws -> [Attachment]
  func attachmentContent(id: UUID) async throws -> AttachmentContent
  @discardableResult func apply(_ mutation: WorkspaceMutation, expectedRevision: Int64?)
    async throws -> Int64
  func messages(conversationID: UUID, beforeSequence: Int64?, limit: Int) async throws
    -> MessagePage
  func search(_ query: String, includeHidden: Bool) async throws -> [Conversation]
  func message(id: UUID) async throws -> Message
}

extension WorkspaceRepository {
  public func exportSnapshot() async throws -> WorkspaceExportDocument {
    throw WorkspaceExportError.unsupportedRepository
  }

  public func botDeletionPlan(botID: UUID) async throws -> BotDeletionPlan {
    throw BotDeletionError.unsupportedRepository
  }

  public func routineRuns(routineID: UUID?, limit: Int) async throws -> [RoutineRun] {
    throw WorkspaceError.storeUnavailable
  }

  public func routineRuns(routineID: UUID? = nil) async throws -> [RoutineRun] {
    try await routineRuns(routineID: routineID, limit: 100)
  }

  public func routineDeletionPlan(routineID: UUID) async throws -> RoutineDeletionPlan {
    throw WorkspaceError.storeUnavailable
  }

  public func routineRun(id: UUID) async throws -> RoutineRun {
    throw WorkspaceError.storeUnavailable
  }

  public func attachments(ids: [UUID]) async throws -> [Attachment] {
    throw AttachmentError.unsupportedRepository
  }

  public func attachmentContent(id: UUID) async throws -> AttachmentContent {
    throw AttachmentError.unsupportedRepository
  }

  public func message(id: UUID) async throws -> Message {
    let snapshot = try await snapshot()
    for conversation in snapshot.conversations {
      var cursor: Int64?
      repeat {
        let page = try await messages(
          conversationID: conversation.id, beforeSequence: cursor, limit: 500)
        if let message = page.messages.first(where: { $0.id == id }) { return message }
        cursor = page.beforeSequence
      } while cursor != nil
    }
    throw WorkspaceError.missingRecord
  }
  @discardableResult public func apply(_ mutation: WorkspaceMutation) async throws -> Int64 {
    try await apply(mutation, expectedRevision: nil)
  }
  public func messages(conversationID: UUID, limit: Int = 100) async throws -> MessagePage {
    try await messages(conversationID: conversationID, beforeSequence: nil, limit: limit)
  }
}
