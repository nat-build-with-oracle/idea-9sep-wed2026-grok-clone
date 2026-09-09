import AppKit
import Darwin
import UniformTypeIdentifiers

@MainActor protocol WorkspaceExportDestinationChoosing {
  func choose() async -> URL?
  func cancel()
}

@MainActor final class NativeWorkspaceExportDestination: WorkspaceExportDestinationChoosing {
  private let panel = NSSavePanel()

  init() {
    panel.title = "Export Workspace"
    panel.message =
      "Includes saved conversations, prompts, drafts and provider endpoints. Stored credentials are excluded. Review content before sharing."
    panel.allowedContentTypes = [.json]
    panel.allowsOtherFileTypes = false
    panel.nameFieldStringValue = "BotWorkspace-export.json"
    panel.canCreateDirectories = true
    // Quit cancels a pending choice, or joins an already accepted export asynchronously.
    panel.preventsApplicationTerminationWhenModal = false
  }

  func choose() async -> URL? {
    await withCheckedContinuation { continuation in
      let completion: (NSApplication.ModalResponse) -> Void = { [panel] response in
        let url = response == .OK ? panel.url : nil
        panel.orderOut(nil)
        continuation.resume(returning: url)
      }
      if let window = NSApp.keyWindow, window.attachedSheet == nil {
        panel.beginSheetModal(for: window, completionHandler: completion)
      } else {
        panel.begin(completionHandler: completion)
      }
    }
  }

  func cancel() { panel.cancel(nil) }
}

enum WorkspaceExportFileError: Error { case invalidDestination }

enum WorkspaceExportFileWriter {
  /// One-shot, explicit destination only. Atomic replacement is not a crash-durability guarantee.
  static func write(_ data: Data, to url: URL) async throws {
    try await Task.detached(priority: .utility) {
      guard url.isFileURL, url.pathExtension.lowercased() == "json" else {
        throw WorkspaceExportFileError.invalidDestination
      }
      // Save Panel supplies an implicit sandbox extension. A false return does not invalidate
      // that grant (or a sandbox-container URL); the actual write still checks OS permissions.
      let scoped = url.startAccessingSecurityScopedResource()
      defer { if scoped { url.stopAccessingSecurityScopedResource() } }
      try inspectDestination(url)
      try Task.checkCancellation()
      try data.write(to: url, options: .atomic)
    }.value
  }

  private static func inspectDestination(_ url: URL) throws {
    var info = stat()
    try url.withUnsafeFileSystemRepresentation { path in
      guard let path else { throw WorkspaceExportFileError.invalidDestination }
      // lstat does not follow the final symbolic link, including a dangling one. Only a
      // genuinely absent target is allowed; permission/inspection errors fail closed.
      if lstat(path, &info) == -1 {
        let code = errno
        guard code == ENOENT else {
          throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return
      }
      guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
        throw WorkspaceExportFileError.invalidDestination
      }
    }
    // This path precheck is not a descriptor-based defense against concurrent attackers
    // in shared/untrusted folders. Foundation performs the selected file's replacement.
  }
}
