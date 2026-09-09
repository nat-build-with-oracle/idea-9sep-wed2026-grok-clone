import Foundation

/// A credential-free provider description suitable for a portable workspace export.
/// The allowlist is intentional: credential references and transport state are never represented.
public struct WorkspaceExportProvider: Codable, Sendable, Equatable, Identifiable {
  public let id: UUID
  public let name: String
  public let kind: ProviderKind
  public let apiRoot: URL
  public let modelID: String
  public let allowsLoopbackHTTP: Bool

  public init(_ provider: ProviderConfig) {
    id = provider.id
    name = provider.name
    kind = provider.kind
    apiRoot = provider.apiRoot
    modelID = provider.modelID
    allowsLoopbackHTTP = provider.allowsLoopbackHTTP
  }
}

public struct WorkspaceExportSummary: Codable, Sendable, Equatable {
  public let botCount: Int
  public let conversationCount: Int
  public let messageCount: Int
  public let draftCount: Int
  public let generationCount: Int
  public let routineCount: Int
  public let routineRunCount: Int
  public let providerCount: Int

  public init(
    botCount: Int, conversationCount: Int, messageCount: Int, draftCount: Int,
    generationCount: Int, routineCount: Int, routineRunCount: Int, providerCount: Int
  ) {
    self.botCount = botCount
    self.conversationCount = conversationCount
    self.messageCount = messageCount
    self.draftCount = draftCount
    self.generationCount = generationCount
    self.routineCount = routineCount
    self.routineRunCount = routineRunCount
    self.providerCount = providerCount
  }
}

public enum WorkspaceExportError: Error, Sendable, Equatable, LocalizedError {
  case unsupportedRepository
  case unsupportedAttachments
  case invalidByteLimit
  case exceedsByteLimit(limit: Int, actual: Int)

  public var errorDescription: String? {
    switch self {
    case .unsupportedRepository:
      "This workspace does not support export."
    case .unsupportedAttachments:
      "This workspace contains attachments, which this export version cannot include."
    case .invalidByteLimit:
      "Choose a positive export size limit."
    case .exceedsByteLimit(let limit, let actual):
      "The export is \(actual) bytes, exceeding the \(limit)-byte limit."
    }
  }
}

/// Version 2 is a complete, text-only snapshot including routine execution history.
/// It is an export format, not a persistence backup or an import contract.
public struct WorkspaceExportDocument: Codable, Sendable, Equatable {
  public static let currentFormatVersion = 2
  public static let currentSourceSchemaVersion = 2
  public static let defaultMaxEncodedBytes = 100 * 1_024 * 1_024

  public let formatVersion: Int
  public let sourceSchemaVersion: Int
  public let exportedAt: Date
  public let revision: Int64
  public let summary: WorkspaceExportSummary
  public let bots: [Bot]
  public let conversations: [Conversation]
  public let messages: [Message]
  public let drafts: [Draft]
  public let generations: [Generation]
  public let routines: [Routine]
  public let routineRuns: [RoutineRun]
  public let providers: [WorkspaceExportProvider]

  public init(
    exportedAt: Date, revision: Int64, bots: [Bot], conversations: [Conversation],
    messages: [Message], drafts: [Draft], generations: [Generation], routines: [Routine],
    routineRuns: [RoutineRun] = [], providers: [WorkspaceExportProvider]
  ) throws {
    guard messages.allSatisfy(\.attachmentIDs.isEmpty),
      drafts.allSatisfy(\.attachmentIDs.isEmpty)
    else { throw WorkspaceExportError.unsupportedAttachments }

    formatVersion = Self.currentFormatVersion
    sourceSchemaVersion = Self.currentSourceSchemaVersion
    self.exportedAt = exportedAt
    self.revision = revision
    self.bots = bots.sorted { Self.uuidLess($0.id, $1.id) }
    self.conversations = conversations.sorted { Self.uuidLess($0.id, $1.id) }
    self.messages = messages.sorted {
      if $0.conversationID != $1.conversationID {
        return Self.uuidLess($0.conversationID, $1.conversationID)
      }
      if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
      return Self.uuidLess($0.id, $1.id)
    }
    self.drafts = drafts.sorted { Self.uuidLess($0.conversationID, $1.conversationID) }
    self.generations = generations.sorted { Self.uuidLess($0.id, $1.id) }
    self.routines = routines.sorted { Self.uuidLess($0.id, $1.id) }
    self.routineRuns = routineRuns.sorted { Self.uuidLess($0.id, $1.id) }
    self.providers = providers.sorted { Self.uuidLess($0.id, $1.id) }
    summary = WorkspaceExportSummary(
      botCount: bots.count, conversationCount: conversations.count,
      messageCount: messages.count, draftCount: drafts.count,
      generationCount: generations.count, routineCount: routines.count,
      routineRunCount: routineRuns.count, providerCount: providers.count)
  }

  /// Produces canonical JSON with lossless Foundation reference-date seconds and a hard,
  /// non-truncating size bound. The numeric date representation round-trips every persisted bit.
  public func encoded(maxBytes: Int = Self.defaultMaxEncodedBytes) throws -> Data {
    guard maxBytes > 0 else { throw WorkspaceExportError.invalidByteLimit }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(self)
    guard data.count <= maxBytes else {
      throw WorkspaceExportError.exceedsByteLimit(limit: maxBytes, actual: data.count)
    }
    return data
  }

  private static func uuidLess(_ lhs: UUID, _ rhs: UUID) -> Bool {
    lhs.uuidString < rhs.uuidString
  }
}
