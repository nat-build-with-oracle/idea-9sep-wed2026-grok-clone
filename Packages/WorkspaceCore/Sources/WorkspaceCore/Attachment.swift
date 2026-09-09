import CryptoKit
import Foundation

public enum AttachmentLimits {
  public static let maxFileBytes = 10 * 1_024 * 1_024
  public static let maxDraftBytes = 25 * 1_024 * 1_024
  public static let maxCount = 32
}

public enum AttachmentError: Error, Sendable, Equatable, LocalizedError {
  case unsupportedRepository
  case invalidName
  case invalidText
  case fileTooLarge
  case tooManyAttachments
  case draftTooLarge
  case duplicateReference
  case missingAttachment
  case foreignAttachment
  case identityConflict
  case corruptAttachment

  public var errorDescription: String? {
    switch self {
    case .unsupportedRepository: "This workspace does not support attachments."
    case .invalidName: "Choose a safe attachment name."
    case .invalidText: "Attachments must contain valid plain UTF-8 text."
    case .fileTooLarge: "Each attachment can contain at most 10 MiB."
    case .tooManyAttachments: "A draft can contain at most 32 attachments."
    case .draftTooLarge: "Draft attachments can contain at most 25 MiB in total."
    case .duplicateReference: "Each attachment can be included only once."
    case .missingAttachment: "An attachment is no longer available."
    case .foreignAttachment: "An attachment belongs to a different conversation."
    case .identityConflict: "This attachment identity already contains different content."
    case .corruptAttachment: "An attachment could not be verified."
    }
  }
}

public struct Attachment: Codable, Sendable, Equatable, Identifiable {
  public let id: UUID
  public let conversationID: UUID
  public let originalName: String
  public let mediaType: String
  public let byteCount: Int
  public let sha256: String
  public let createdAt: Date

  public init(
    id: UUID, conversationID: UUID, originalName: String, mediaType: String = "text/plain",
    byteCount: Int, sha256: String, createdAt: Date
  ) {
    self.id = id
    self.conversationID = conversationID
    self.originalName = originalName
    self.mediaType = mediaType
    self.byteCount = byteCount
    self.sha256 = sha256
    self.createdAt = createdAt
  }
}

public struct AttachmentContent: Codable, Sendable, Equatable {
  public let attachment: Attachment
  public let data: Data

  public init(
    id: UUID = UUID(), conversationID: UUID, originalName: String, data: Data,
    createdAt: Date = Date()
  ) throws {
    guard data.count <= AttachmentLimits.maxFileBytes else { throw AttachmentError.fileTooLarge }
    let name = try AttachmentValidation.name(originalName)
    try AttachmentValidation.text(data)
    attachment = Attachment(
      id: id, conversationID: conversationID, originalName: name, byteCount: data.count,
      sha256: AttachmentValidation.sha256(data), createdAt: createdAt)
    self.data = data
  }

  public init(attachment: Attachment, data: Data) throws {
    try AttachmentValidation.content(attachment, data: data)
    self.attachment = attachment
    self.data = data
  }
}

enum AttachmentValidation {
  static func name(_ value: String) throws -> String {
    let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty, clean.count <= 255, clean != ".", clean != "..",
      !clean.contains("/"), !clean.contains("\\"),
      !clean.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else { throw AttachmentError.invalidName }
    return clean
  }

  static func text(_ data: Data) throws {
    guard let value = String(data: data, encoding: .utf8) else { throw AttachmentError.invalidText }
    guard
      !value.unicodeScalars.contains(where: { scalar in
        scalar.properties.generalCategory == .control
          && scalar.value != 0x09 && scalar.value != 0x0A && scalar.value != 0x0D
      })
    else { throw AttachmentError.invalidText }
  }

  static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  static func metadata(_ attachment: Attachment) throws {
    guard attachment.originalName == (try name(attachment.originalName)),
      attachment.mediaType == "text/plain", attachment.byteCount >= 0,
      attachment.byteCount <= AttachmentLimits.maxFileBytes,
      attachment.sha256.utf8.count == 64,
      attachment.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else { throw AttachmentError.corruptAttachment }
  }

  static func content(_ attachment: Attachment, data: Data) throws {
    try metadata(attachment)
    guard data.count == attachment.byteCount, sha256(data) == attachment.sha256 else {
      throw AttachmentError.corruptAttachment
    }
    try text(data)
  }

  static func orderedUnique(_ ids: [UUID]) throws {
    guard ids.count <= AttachmentLimits.maxCount else { throw AttachmentError.tooManyAttachments }
    guard Set(ids).count == ids.count else { throw AttachmentError.duplicateReference }
  }
}
