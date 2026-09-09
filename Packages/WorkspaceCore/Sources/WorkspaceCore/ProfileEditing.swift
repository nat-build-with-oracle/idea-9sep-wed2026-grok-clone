import Foundation

/// The editable portion of a bot. Identity and operational fields are deliberately excluded so
/// unrelated visibility or provider changes do not conflict with profile editing.
public struct BotProfile: Sendable, Equatable {
  public var name: String
  public var description: String
  public var color: String
  public var shape: AvatarShape

  public init(name: String, description: String, color: String, shape: AvatarShape) {
    self.name = name
    self.description = description
    self.color = color
    self.shape = shape
  }

  public init(_ bot: Bot) {
    self.init(
      name: bot.name, description: bot.description, color: bot.color, shape: bot.shape)
  }

  public func validated() throws -> Self {
    try DomainValidation.botProfile(self)
  }
}

/// The editable portion of a group. Transcript sequence and read state are deliberately excluded.
public struct GroupProfile: Sendable, Equatable {
  public var title: String
  public var memberBotIDs: [UUID]

  public init(title: String, memberBotIDs: [UUID]) {
    self.title = title
    self.memberBotIDs = memberBotIDs
  }

  public init(_ conversation: Conversation) {
    self.init(title: conversation.title, memberBotIDs: conversation.memberBotIDs)
  }

  public func validated() throws -> Self {
    try DomainValidation.groupProfile(self)
  }
}
