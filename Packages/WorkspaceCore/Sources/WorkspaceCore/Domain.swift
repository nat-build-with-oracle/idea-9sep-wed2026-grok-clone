import Foundation

public enum AvatarShape: String, Codable, Sendable, CaseIterable {
  case circle, square, drop, capsule
}

public struct Bot: Codable, Sendable, Equatable, Identifiable {
  public let id: UUID
  public var name: String
  public var description: String
  public var color: String
  public var shape: AvatarShape
  public let createdAt: Date
  public var hiddenAt: Date?
  public var providerConfigID: UUID?

  public init(
    id: UUID = UUID(), name: String, description: String = "", color: String = "green",
    shape: AvatarShape = .circle, createdAt: Date = Date(), hiddenAt: Date? = nil,
    providerConfigID: UUID? = nil
  ) {
    self.id = id
    self.name = name
    self.description = description
    self.color = color
    self.shape = shape
    self.createdAt = createdAt
    self.hiddenAt = hiddenAt
    self.providerConfigID = providerConfigID
  }
}

public struct Conversation: Codable, Sendable, Equatable, Identifiable {
  public enum Kind: String, Codable, Sendable { case direct, group }
  public let id: UUID
  public let kind: Kind
  public var title: String
  public var memberBotIDs: [UUID]
  public let createdAt: Date
  public var lastReadSequence: Int64
  public internal(set) var nextSequence: Int64

  public init(
    id: UUID = UUID(), kind: Kind, title: String, memberBotIDs: [UUID],
    createdAt: Date = Date(), lastReadSequence: Int64 = 0
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.memberBotIDs = memberBotIDs
    self.createdAt = createdAt
    self.lastReadSequence = lastReadSequence
    self.nextSequence = 1
  }
}

public struct Message: Codable, Sendable, Equatable, Identifiable {
  public enum Role: String, Codable, Sendable { case user, assistant, event }
  public let id: UUID
  public let conversationID: UUID
  public let sequence: Int64
  public let role: Role
  public let speakerBotID: UUID?
  public let speakerNameSnapshot: String?
  public var text: String
  public let createdAt: Date
  public let replyToID: UUID?
  public let attachmentIDs: [UUID]
  public let generationID: UUID?
}

public struct Draft: Codable, Sendable, Equatable, Identifiable {
  public var id: UUID { conversationID }
  public let conversationID: UUID
  public var text: String
  public var attachmentIDs: [UUID]
  public var replyToID: UUID?
  public var updatedAt: Date
  public init(
    conversationID: UUID, text: String, attachmentIDs: [UUID] = [],
    replyToID: UUID? = nil, updatedAt: Date = Date()
  ) {
    self.conversationID = conversationID
    self.text = text
    self.attachmentIDs = attachmentIDs
    self.replyToID = replyToID
    self.updatedAt = updatedAt
  }
}

public struct Generation: Codable, Sendable, Equatable, Identifiable {
  public enum State: String, Codable, Sendable, CaseIterable {
    case queued, connecting, streaming, completed, failed, cancelled, interrupted
    public var isTerminal: Bool {
      switch self {
      case .queued, .connecting, .streaming: false
      default: true
      }
    }
  }
  public let id: UUID
  public let conversationID: UUID
  public let userMessageID: UUID
  public var attemptID: UUID
  public let targetBotID: UUID
  public var state: State
  public var lastEventSequence: Int64
  public var error: String?
  public var assistantMessageID: UUID? = nil
  /// Durable provenance for routine-created generations. Legacy and ordinary generations are nil.
  public var routineRunID: UUID? = nil
  /// Stable position within an explicitly ordered multi-bot round. Legacy generations are nil.
  public var roundIndex: Int? = nil
  /// Bot-name attribution captured when the round is committed, before transport begins.
  public var targetSpeakerNameSnapshot: String? = nil
}

public struct Routine: Codable, Sendable, Equatable, Identifiable {
  public enum Trigger: Codable, Sendable, Equatable {
    case interval(minutes: Int)
    case daily(hour: Int, minute: Int)
  }
  public let id: UUID
  public let ownerBotID: UUID
  public var name: String
  public var prompt: String
  public var trigger: Trigger
  public var timezoneID: String
  public var enabled: Bool
  public var nextRunAt: Date?
  /// Credential-free provider snapshot selected for future routine runs.
  public var providerBinding: RoutineProviderBinding?
  /// Stable recurrence identity reserved for schedule edits and occurrence deduplication.
  public var scheduleID: UUID?

  public init(
    id: UUID = UUID(), ownerBotID: UUID, name: String, prompt: String, trigger: Trigger,
    timezoneID: String, enabled: Bool = false, nextRunAt: Date? = nil,
    providerBinding: RoutineProviderBinding? = nil, scheduleID: UUID? = nil
  ) {
    self.id = id
    self.ownerBotID = ownerBotID
    self.name = name
    self.prompt = prompt
    self.trigger = trigger
    self.timezoneID = timezoneID
    self.enabled = enabled
    self.nextRunAt = nextRunAt
    self.providerBinding = providerBinding
    self.scheduleID = scheduleID
  }

  private enum CodingKeys: String, CodingKey {
    case id, ownerBotID, name, prompt, trigger, timezoneID, enabled, nextRunAt, providerBinding,
      scheduleID
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(UUID.self, forKey: .id)
    ownerBotID = try values.decode(UUID.self, forKey: .ownerBotID)
    name = try values.decode(String.self, forKey: .name)
    prompt = try values.decode(String.self, forKey: .prompt)
    trigger = try values.decode(Trigger.self, forKey: .trigger)
    timezoneID = try values.decode(String.self, forKey: .timezoneID)
    enabled = try values.decode(Bool.self, forKey: .enabled)
    nextRunAt = try values.decodeIfPresent(Date.self, forKey: .nextRunAt)
    providerBinding = try values.decodeIfPresent(
      RoutineProviderBinding.self, forKey: .providerBinding)
    scheduleID = try values.decodeIfPresent(UUID.self, forKey: .scheduleID)
  }
}

/// Configuration metadata only. No credential value belongs in this type or the repository.
public enum ProviderKind: String, Codable, Sendable, CaseIterable {
  case chatCompletions, codexResponses
}

public struct ProviderConfig: Codable, Sendable, Equatable, Identifiable {
  public let id: UUID
  public var name: String
  public var apiRoot: URL
  public var modelID: String
  public var credentialReference: String
  public var allowsLoopbackHTTP: Bool
  public var kind: ProviderKind

  public init(
    id: UUID = UUID(), name: String, apiRoot: URL, modelID: String,
    credentialReference: String, allowsLoopbackHTTP: Bool = false,
    kind: ProviderKind = .chatCompletions
  ) {
    self.id = id
    self.name = name
    self.apiRoot = apiRoot
    self.modelID = modelID
    self.credentialReference = credentialReference
    self.allowsLoopbackHTTP = allowsLoopbackHTTP
    self.kind = kind
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, apiRoot, modelID, credentialReference, allowsLoopbackHTTP, kind
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(UUID.self, forKey: .id)
    name = try values.decode(String.self, forKey: .name)
    apiRoot = try values.decode(URL.self, forKey: .apiRoot)
    modelID = try values.decode(String.self, forKey: .modelID)
    credentialReference = try values.decode(String.self, forKey: .credentialReference)
    allowsLoopbackHTTP = try values.decode(Bool.self, forKey: .allowsLoopbackHTTP)
    kind = try values.decodeIfPresent(ProviderKind.self, forKey: .kind) ?? .chatCompletions
  }
}

/// Sidebar-ready activity derived from the latest message only, without loading a transcript.
public struct ConversationActivity: Sendable, Equatable {
  public let conversationID: UUID
  public let latestSequence: Int64
  public let latestMessageID: UUID?
  public let latestMessageTextByteCount: Int
  public let lastMessagePreview: String?
  public let lastMessageAt: Date?
  public let unreadAssistantCount: Int

  public init(
    conversationID: UUID, latestSequence: Int64, latestMessageID: UUID? = nil,
    latestMessageTextByteCount: Int = 0, lastMessagePreview: String?, lastMessageAt: Date?,
    unreadAssistantCount: Int
  ) {
    self.conversationID = conversationID
    self.latestSequence = latestSequence
    self.latestMessageID = latestMessageID
    self.latestMessageTextByteCount = latestMessageTextByteCount
    self.lastMessagePreview = lastMessagePreview
    self.lastMessageAt = lastMessageAt
    self.unreadAssistantCount = unreadAssistantCount
  }
}

/// Messages are intentionally paginated separately: a workspace snapshot never loads a transcript.
public struct WorkspaceSnapshot: Sendable, Equatable {
  public let revision: Int64
  public let bots: [Bot]
  public let conversations: [Conversation]
  public let drafts: [Draft]
  public let generations: [Generation]
  public let routines: [Routine]
  public let providers: [ProviderConfig]
  public let conversationActivity: [ConversationActivity]

  public init(
    revision: Int64, bots: [Bot], conversations: [Conversation], drafts: [Draft],
    generations: [Generation], routines: [Routine], providers: [ProviderConfig],
    conversationActivity: [ConversationActivity] = []
  ) {
    self.revision = revision
    self.bots = bots
    self.conversations = conversations
    self.drafts = drafts
    self.generations = generations
    self.routines = routines
    self.providers = providers
    self.conversationActivity = conversationActivity
  }
}

public struct MessagePage: Sendable, Equatable {
  /// Ascending sequence order; `beforeSequence` is an exclusive keyset cursor.
  public let messages: [Message]
  public let hasMore: Bool
  public var beforeSequence: Int64? { hasMore ? messages.first?.sequence : nil }
}

public enum WorkspaceError: Error, Sendable, Equatable, LocalizedError {
  case invalidName, invalidDescription, invalidMembers, invalidAvatar, invalidRoutine
  case invalidProvider, invalidDraft, missingRecord, identityConflict, staleRevision, editConflict
  case invalidPage, unsupportedSchema, invalidStore, storeUnavailable, storeClosed, storeInUse

  public var errorDescription: String? {
    switch self {
    case .invalidName: "Use a name between 1 and 80 characters."
    case .invalidDescription: "Descriptions can contain at most 8,000 characters."
    case .invalidMembers: "Choose two to six different available bots."
    case .invalidAvatar: "Choose one of the supported avatar colors."
    case .invalidRoutine: "Check the routine prompt, interval, local time, and time zone."
    case .invalidProvider: "Use a valid HTTPS API root, model, and credential reference."
    case .invalidDraft: "The draft is empty or references unavailable content."
    case .missingRecord: "This workspace item is no longer available."
    case .identityConflict: "This identity already belongs to a workspace item."
    case .staleRevision: "The workspace changed. Refresh before trying again."
    case .editConflict: "This profile changed. Review the latest values before saving again."
    case .invalidPage: "Choose a page size between 1 and 500."
    case .unsupportedSchema: "This workspace version is not supported. Its data has not been reset."
    case .invalidStore: "The workspace could not be read. Its data has not been reset."
    case .storeUnavailable:
      "The workspace could not be saved. Check available storage and permissions."
    case .storeClosed: "The workspace is closed."
    case .storeInUse: "This workspace is already open. Use its existing window."
    }
  }
}

enum DomainValidation {
  static func name(_ value: String) throws -> String {
    let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (1...80).contains(clean.count) else { throw WorkspaceError.invalidName }
    return clean
  }
  static func bot(_ value: Bot) throws -> Bot {
    var bot = value
    let profile = try botProfile(BotProfile(bot))
    bot.name = profile.name
    bot.description = profile.description
    bot.color = profile.color
    bot.shape = profile.shape
    return bot
  }
  static func botProfile(_ value: BotProfile) throws -> BotProfile {
    var profile = value
    profile.name = try name(profile.name)
    guard profile.description.count <= 8_000 else {
      throw WorkspaceError.invalidDescription
    }
    guard ["green", "magenta", "gray", "violet", "blue", "orange"].contains(profile.color)
    else {
      throw WorkspaceError.invalidAvatar
    }
    return profile
  }
  static func groupProfile(_ value: GroupProfile) throws -> GroupProfile {
    var profile = value
    profile.title = try name(profile.title)
    guard (2...6).contains(profile.memberBotIDs.count),
      Set(profile.memberBotIDs).count == profile.memberBotIDs.count
    else {
      throw WorkspaceError.invalidMembers
    }
    return profile
  }
  static func routine(_ value: Routine) throws -> Routine {
    var routine = value
    routine.name = try name(routine.name)
    guard !routine.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      routine.prompt.count <= 32_000, TimeZone(identifier: routine.timezoneID) != nil
    else {
      throw WorkspaceError.invalidRoutine
    }
    switch routine.trigger {
    case .interval(let minutes):
      guard (5...525_600).contains(minutes) else { throw WorkspaceError.invalidRoutine }
    case .daily(let hour, let minute):
      guard (0...23).contains(hour), (0...59).contains(minute) else {
        throw WorkspaceError.invalidRoutine
      }
    }
    if let next = routine.nextRunAt {
      guard next.timeIntervalSinceReferenceDate.isFinite else {
        throw WorkspaceError.invalidRoutine
      }
    }
    if let binding = routine.providerBinding {
      let validationReference =
        binding.kind == .codexResponses
        ? CodexSessionCredential.makeReference() : "routine-binding-validation"
      let candidate = ProviderConfig(
        id: binding.providerID, name: "Routine provider", apiRoot: binding.apiRoot,
        modelID: binding.modelID, credentialReference: validationReference,
        allowsLoopbackHTTP: binding.allowsLoopbackHTTP, kind: binding.kind)
      let validated = try provider(candidate)
      guard binding.matches(validated) else { throw WorkspaceError.invalidRoutine }
    }
    return routine
  }
  static func provider(_ value: ProviderConfig) throws -> ProviderConfig {
    var provider = value
    provider.name = try name(provider.name)
    guard let url = URLComponents(url: provider.apiRoot, resolvingAgainstBaseURL: false),
      let host = url.host?.lowercased(), !host.isEmpty,
      url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
      url.scheme == "https"
        || (url.scheme == "http" && provider.allowsLoopbackHTTP
          && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)),
      !provider.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      (1...200).contains(provider.credentialReference.count)
    else { throw WorkspaceError.invalidProvider }
    switch provider.kind {
    case .chatCompletions:
      guard !CodexSessionCredential.isReference(provider.credentialReference) else {
        throw WorkspaceError.invalidProvider
      }
    case .codexResponses:
      try CodexResponsesProvider.validateConfiguration(provider)
    }
    return provider
  }
}
