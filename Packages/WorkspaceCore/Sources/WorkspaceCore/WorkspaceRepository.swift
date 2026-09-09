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
  public let createdAt: Date

  public init(
    conversationID: UUID, userMessageID: UUID = UUID(), generationID: UUID = UUID(),
    attemptID: UUID = UUID(), targetBotID: UUID, text: String, replyToID: UUID? = nil,
    createdAt: Date = Date()
  ) {
    self.conversationID = conversationID
    self.userMessageID = userMessageID
    self.generationID = generationID
    self.attemptID = attemptID
    self.targetBotID = targetBotID
    self.text = text
    self.replyToID = replyToID
    self.createdAt = createdAt
  }
}

public enum WorkspaceMutation: Sendable {
  /// Caller retains both IDs across retries. They must differ and must not already exist.
  case createBot(Bot, conversationID: UUID)
  case updateBot(Bot)
  case setHidden(botID: UUID, at: Date?)
  case createGroup(Conversation)
  case updateGroup(id: UUID, title: String, members: [UUID])
  case saveDraft(Draft)
  /// Commits user message, initial generation, sequence allocation and draft clear in one save.
  /// Transport is deliberately outside the repository; this does not itself contact any provider.
  case beginGeneration(SendCommand)
  case cancelGeneration(id: UUID, attemptID: UUID)
  case applyGenerationEvent(GenerationEvent)
  case retryGeneration(id: UUID, attemptID: UUID)
  case interruptPendingGenerations
  case saveRoutine(Routine)
  case saveProvider(ProviderConfig)
  case markRead(conversationID: UUID, throughSequence: Int64)
}

public protocol WorkspaceRepository: Sendable {
  func snapshot() async throws -> WorkspaceSnapshot
  @discardableResult func apply(_ mutation: WorkspaceMutation, expectedRevision: Int64?)
    async throws -> Int64
  func messages(conversationID: UUID, beforeSequence: Int64?, limit: Int) async throws
    -> MessagePage
  func search(_ query: String, includeHidden: Bool) async throws -> [Conversation]
  func message(id: UUID) async throws -> Message
}

extension WorkspaceRepository {
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
