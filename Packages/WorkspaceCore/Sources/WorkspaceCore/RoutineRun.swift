import Foundation

/// Credential-free, immutable provider metadata captured when a routine is configured.
public struct RoutineProviderBinding: Codable, Sendable, Equatable {
  public let providerID: UUID
  public let kind: ProviderKind
  public let apiRoot: URL
  public let modelID: String
  public let allowsLoopbackHTTP: Bool

  public init(
    providerID: UUID, kind: ProviderKind, apiRoot: URL, modelID: String,
    allowsLoopbackHTTP: Bool
  ) {
    self.providerID = providerID
    self.kind = kind
    self.apiRoot = apiRoot
    self.modelID = modelID
    self.allowsLoopbackHTTP = allowsLoopbackHTTP
  }

  public init(_ provider: ProviderConfig) {
    self.init(
      providerID: provider.id, kind: provider.kind, apiRoot: provider.apiRoot,
      modelID: provider.modelID, allowsLoopbackHTTP: provider.allowsLoopbackHTTP)
  }

  public func matches(_ provider: ProviderConfig) -> Bool {
    self == RoutineProviderBinding(provider)
  }
}

/// Immutable execution input plus mutable lifecycle state for one routine occurrence.
public struct RoutineRun: Codable, Sendable, Equatable, Identifiable {
  public enum Status: String, Codable, Sendable, CaseIterable {
    case queued, running, completed, failed, cancelled, interrupted, blocked, skipped

    public var isTerminal: Bool {
      switch self {
      case .queued, .running: false
      default: true
      }
    }
  }

  /// Persisted failures are an allowlist; arbitrary provider bodies and credential material cannot
  /// enter run history.
  public enum Failure: String, Codable, Sendable, Equatable {
    case missingProvider, providerChanged, missingCredential, invalidCredential, loginRequired
    case unavailable, rateLimited, invalidResponse, unsupportedContent, outputLimit
    case storageUnavailable, invalidSchedule, cancelled, interrupted, supersededOccurrence
  }

  public let id: UUID
  public let routineID: UUID
  public let ownerBotID: UUID
  public let conversationID: UUID
  public let name: String
  public let prompt: String
  public let providerBinding: RoutineProviderBinding?
  public let occurrenceID: String?
  public let scheduledAt: Date?
  public let createdAt: Date
  public let generationID: UUID?
  public var status: Status
  public var startedAt: Date?
  public var endedAt: Date?
  public var error: Failure?
  public let skippedCount: Int
  public let firstSkippedAt: Date?
  public let lastSkippedAt: Date?

  public init(
    id: UUID = UUID(), routineID: UUID, ownerBotID: UUID, conversationID: UUID, name: String,
    prompt: String, providerBinding: RoutineProviderBinding?, occurrenceID: String? = nil,
    scheduledAt: Date? = nil, createdAt: Date = Date(), generationID: UUID?,
    status: Status = .queued, startedAt: Date? = nil, endedAt: Date? = nil,
    error: Failure? = nil,
    skippedCount: Int = 0, firstSkippedAt: Date? = nil, lastSkippedAt: Date? = nil
  ) {
    self.id = id
    self.routineID = routineID
    self.ownerBotID = ownerBotID
    self.conversationID = conversationID
    self.name = name
    self.prompt = prompt
    self.providerBinding = providerBinding
    self.occurrenceID = occurrenceID
    self.scheduledAt = scheduledAt
    self.createdAt = createdAt
    self.generationID = generationID
    self.status = status
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.error = error
    self.skippedCount = skippedCount
    self.firstSkippedAt = firstSkippedAt
    self.lastSkippedAt = lastSkippedAt
  }
}
