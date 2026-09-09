import Foundation

public enum BotDeletionError: Error, Sendable, Equatable, LocalizedError {
  case unsupportedRepository
  case confirmationChanged
  case activeWork
  case unsupportedAttachments

  public var errorDescription: String? {
    switch self {
    case .unsupportedRepository:
      "This workspace does not support deleting bots."
    case .confirmationChanged:
      "The items affected by this deletion changed. Review them before deleting."
    case .activeWork:
      "Wait for affected replies to stop before deleting this bot."
    case .unsupportedAttachments:
      "This bot has attachments that this version cannot safely delete."
    }
  }
}

/// The exact persisted impact presented for confirmation before a bot is deleted.
///
/// Group transcripts and history are deliberately not included in the rows to delete. Only future
/// membership changes: messages retain their recorded speaker attribution.
public struct BotDeletionPlan: Sendable, Equatable, Identifiable {
  public struct AffectedGroup: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let title: String
    public let remainingMemberBotIDs: [UUID]

    public init(id: UUID, title: String, remainingMemberBotIDs: [UUID]) {
      self.id = id
      self.title = title
      self.remainingMemberBotIDs = remainingMemberBotIDs
    }
  }

  public let botID: UUID
  public let name: String
  public let directConversationIDs: [UUID]
  public let messageIDs: [UUID]
  public let draftConversationIDs: [UUID]
  public let generationIDs: [UUID]
  public let routineIDs: [UUID]
  public let affectedGroups: [AffectedGroup]
  /// Non-terminal generations in affected conversations, plus work targeting this bot elsewhere.
  public let activeGenerationIDs: [UUID]
  /// Conversations whose provider work must be cancelled and awaited before deletion.
  public let cancellationConversationIDs: [UUID]

  public var id: UUID { botID }
  public var directConversationCount: Int { directConversationIDs.count }
  public var messageCount: Int { messageIDs.count }
  public var draftCount: Int { draftConversationIDs.count }
  public var generationCount: Int { generationIDs.count }
  public var routineCount: Int { routineIDs.count }
  public var affectedGroupCount: Int { affectedGroups.count }

  /// Compares destructive persisted impact, ignoring cancellation-state transitions. The
  /// coordinator separately rejects newly active work that was not shown for confirmation.
  public func hasSameContent(as other: BotDeletionPlan) -> Bool {
    botID == other.botID && name == other.name
      && directConversationIDs == other.directConversationIDs
      && messageIDs == other.messageIDs
      && draftConversationIDs == other.draftConversationIDs
      && generationIDs == other.generationIDs
      && routineIDs == other.routineIDs
      && affectedGroups == other.affectedGroups
  }

  public init(
    botID: UUID, name: String, directConversationIDs: [UUID], messageIDs: [UUID],
    draftConversationIDs: [UUID], generationIDs: [UUID], routineIDs: [UUID],
    affectedGroups: [AffectedGroup], activeGenerationIDs: [UUID],
    cancellationConversationIDs: [UUID]
  ) {
    self.botID = botID
    self.name = name
    self.directConversationIDs = directConversationIDs
    self.messageIDs = messageIDs
    self.draftConversationIDs = draftConversationIDs
    self.generationIDs = generationIDs
    self.routineIDs = routineIDs
    self.affectedGroups = affectedGroups
    self.activeGenerationIDs = activeGenerationIDs
    self.cancellationConversationIDs = cancellationConversationIDs
  }
}
