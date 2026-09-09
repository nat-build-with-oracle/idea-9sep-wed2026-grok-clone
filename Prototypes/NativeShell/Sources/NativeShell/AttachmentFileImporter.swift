import AppKit
import Darwin
import Foundation
import UniformTypeIdentifiers
import WorkspaceCore

@MainActor
protocol AttachmentFileChoosing: AnyObject {
  func choose() async -> [URL]?
  func cancel()
}

/// Presents an explicit file chooser. Reading and validation happen separately so callers can
/// perform that bounded work away from the main actor.
@MainActor
final class NativeAttachmentFileChooser: AttachmentFileChoosing {
  private var panel: NSOpenPanel?
  private var continuation: CheckedContinuation<[URL]?, Never>?
  private var cancelNextChoice = false

  func choose() async -> [URL]? {
    if cancelNextChoice {
      cancelNextChoice = false
      return nil
    }
    guard panel == nil, continuation == nil else { return nil }

    let panel = NSOpenPanel()
    panel.title = "Copy text attachments into this workspace"
    panel.message =
      "Choose up to 32 local UTF-8 text files. BotWorkspace copies at most 10 MiB per file and 25 MiB total into its managed workspace. It does not search for files or credentials."
    panel.prompt = "Copy Attachments"
    panel.allowedContentTypes = [.text]
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.resolvesAliases = false

    return await withCheckedContinuation { continuation in
      self.panel = panel
      self.continuation = continuation
      panel.begin { [self] response in
        guard self.panel === panel else { return }
        self.panel = nil
        let pending = self.continuation
        self.continuation = nil
        pending?.resume(returning: response == .OK ? panel.urls : nil)
      }
    }
  }

  func cancel() {
    guard panel != nil || continuation != nil else {
      cancelNextChoice = true
      return
    }

    let activePanel = panel
    panel = nil
    let pending = continuation
    continuation = nil
    activePanel?.cancel(nil)
    pending?.resume(returning: nil)
  }
}

enum AttachmentFileImportError: Error, Sendable, Equatable, LocalizedError {
  case invalidSelection
  case unsupportedTextType
  case unavailable
  case notRegularFile
  case duplicateSelection
  case fileChanged
  case cancelled
  case readFailed

  var errorDescription: String? {
    switch self {
    case .invalidSelection: "Choose local files with safe names."
    case .unsupportedTextType: "Attachments must use a supported plain-text file type."
    case .unavailable: "A selected attachment is no longer available."
    case .notRegularFile: "Attachments must be regular files, not links, folders, or devices."
    case .duplicateSelection: "Choose each attachment file only once."
    case .fileChanged: "A selected attachment changed while it was being copied."
    case .cancelled: "Attachment copying was cancelled."
    case .readFailed: "A selected attachment could not be read safely."
    }
  }
}

/// Reads only URLs explicitly returned by the chooser. The managed result contains the original
/// basename and exact bytes, never the selected path. `O_NOFOLLOW` protects the final path
/// component; this reader does not claim to protect every ancestor from concurrent replacement.
nonisolated enum AttachmentFileImporter {
  private static let chunkBytes = 64 * 1_024

  private static let explicitlySupportedExtensions: Set<String> = [
    "c", "cc", "conf", "cpp", "css", "csv", "go", "h", "hpp", "html", "ini", "java",
    "js", "json", "jsx", "kt", "log", "md", "mjs", "mm", "php", "plist", "properties",
    "py", "rb", "rs", "sh", "sql", "swift", "text", "toml", "ts", "tsx", "txt", "xml",
    "yaml", "yml",
  ]

  private static let explicitlyRejectedExtensions: Set<String> = [
    "7z", "aiff", "app", "avi", "bin", "bmp", "dmg", "doc", "docx", "exe", "gif", "gz",
    "heic", "jpeg", "jpg", "m4a", "mov", "mp3", "mp4", "numbers", "pages", "pdf", "png",
    "ppt", "pptx", "rar", "rtf", "tar", "tiff", "wav", "webp", "xls", "xlsx", "zip",
  ]

  static func read(urls: [URL], conversationID: UUID) throws -> [AttachmentContent] {
    guard urls.count <= AttachmentLimits.maxCount else {
      throw AttachmentError.tooManyAttachments
    }
    guard !Task.isCancelled else { throw AttachmentFileImportError.cancelled }

    var identities = Set<String>()
    for url in urls {
      guard url.isFileURL else { throw AttachmentFileImportError.invalidSelection }
      let identity = url.standardizedFileURL.path
      guard identities.insert(identity).inserted else {
        throw AttachmentFileImportError.duplicateSelection
      }
    }

    var result: [AttachmentContent] = []
    result.reserveCapacity(urls.count)
    var totalBytes = 0

    for url in urls {
      guard !Task.isCancelled else { throw AttachmentFileImportError.cancelled }
      let accessed = url.startAccessingSecurityScopedResource()
      defer { if accessed { url.stopAccessingSecurityScopedResource() } }

      let originalName = url.lastPathComponent
      try validateTypeAndName(url: url, originalName: originalName)
      let data = try readBoundedFile(
        url, remainingDraftBytes: AttachmentLimits.maxDraftBytes - totalBytes)
      guard data.count <= AttachmentLimits.maxFileBytes else {
        throw AttachmentError.fileTooLarge
      }
      guard totalBytes <= AttachmentLimits.maxDraftBytes - data.count else {
        throw AttachmentError.draftTooLarge
      }
      totalBytes += data.count
      result.append(
        try AttachmentContent(
          conversationID: conversationID, originalName: originalName, data: data))
    }
    return result
  }

  private static func validateTypeAndName(url: URL, originalName: String) throws {
    guard originalName == originalName.trimmingCharacters(in: .whitespacesAndNewlines),
      !originalName.isEmpty, originalName != ".", originalName != "..",
      !originalName.contains("/"), !originalName.contains("\\"), originalName.utf8.count <= 255,
      !originalName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else { throw AttachmentFileImportError.invalidSelection }

    let pathExtension = url.pathExtension.lowercased()
    if explicitlyRejectedExtensions.contains(pathExtension) {
      throw AttachmentFileImportError.unsupportedTextType
    }
    if explicitlySupportedExtensions.contains(pathExtension) { return }
    if !pathExtension.isEmpty,
      let type = UTType(filenameExtension: pathExtension), type.conforms(to: .text)
    {
      return
    }

    let extensionlessTextNames: Set<String> = [
      "authors", "changelog", "copying", "license", "makefile", "notice", "readme",
    ]
    guard pathExtension.isEmpty,
      extensionlessTextNames.contains(originalName.lowercased())
    else { throw AttachmentFileImportError.unsupportedTextType }
  }

  private static func readBoundedFile(_ url: URL, remainingDraftBytes: Int) throws -> Data {
    let descriptor: Int32 = url.withUnsafeFileSystemRepresentation { path in
      guard let path else { return -1 }
      return Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    }
    guard descriptor >= 0 else {
      switch errno {
      case ELOOP: throw AttachmentFileImportError.notRegularFile
      case ENOENT, ENOTDIR: throw AttachmentFileImportError.unavailable
      default: throw AttachmentFileImportError.readFailed
      }
    }
    defer { Darwin.close(descriptor) }

    var before = stat()
    guard fstat(descriptor, &before) == 0 else { throw AttachmentFileImportError.readFailed }
    guard (before.st_mode & S_IFMT) == S_IFREG else {
      throw AttachmentFileImportError.notRegularFile
    }
    guard before.st_size >= 0, before.st_size <= AttachmentLimits.maxFileBytes else {
      throw AttachmentError.fileTooLarge
    }
    guard before.st_size <= remainingDraftBytes else { throw AttachmentError.draftTooLarge }

    var data = Data()
    data.reserveCapacity(Int(before.st_size))
    var buffer = [UInt8](repeating: 0, count: chunkBytes)
    let readLimit = min(AttachmentLimits.maxFileBytes, remainingDraftBytes)
    while data.count <= readLimit {
      guard !Task.isCancelled else { throw AttachmentFileImportError.cancelled }
      let requestedBytes = min(buffer.count, readLimit - data.count + 1)
      let count = buffer.withUnsafeMutableBytes { bytes in
        Darwin.read(descriptor, bytes.baseAddress, requestedBytes)
      }
      if count > 0 {
        data.append(buffer, count: count)
        if data.count > readLimit {
          if readLimit == AttachmentLimits.maxFileBytes { throw AttachmentError.fileTooLarge }
          throw AttachmentError.draftTooLarge
        }
      } else if count == 0 {
        break
      } else if errno != EINTR {
        throw AttachmentFileImportError.readFailed
      }
    }

    var after = stat()
    guard fstat(descriptor, &after) == 0 else { throw AttachmentFileImportError.readFailed }
    guard sameFileSnapshot(before, after), data.count == Int(after.st_size) else {
      throw AttachmentFileImportError.fileChanged
    }
    return data
  }

  private static func sameFileSnapshot(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_size == rhs.st_size
      && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
      && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
      && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
      && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
  }
}
