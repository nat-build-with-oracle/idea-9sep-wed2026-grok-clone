import AppKit
import Foundation
import UniformTypeIdentifiers
import WorkspaceCore

/// Explicit, user-directed ingress for an existing Codex login.
/// The selected file is read once, bounded, parsed by WorkspaceCore, and never retained.
@MainActor
enum CodexAuthFileImporter {
  static func chooseCredential() async throws -> CodexSessionCredential? {
    let panel = NSOpenPanel()
    panel.title = "Import Codex login for this session"
    panel.message =
      "Choose the auth.json maintained by Codex. BotWorkspace reads it once and does not modify or copy it."
    panel.prompt = "Import"
    panel.allowedContentTypes = [.json]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.resolvesAliases = true

    let response = await withCheckedContinuation { continuation in
      panel.begin { continuation.resume(returning: $0) }
    }
    guard response == .OK, let url = panel.url else { return nil }
    do {
      return try readCredential(from: url)
    } catch let error as ProviderError {
      throw error
    } catch {
      throw ProviderError.invalidCodexLogin
    }
  }

  static func readCredential(from url: URL) throws -> CodexSessionCredential {
    let accessed = url.startAccessingSecurityScopedResource()
    defer { if accessed { url.stopAccessingSecurityScopedResource() } }

    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true else { throw ProviderError.invalidCodexLogin }
    if let size = values.fileSize, size > CodexSessionCredential.maximumFileBytes {
      throw ProviderError.invalidCodexLogin
    }

    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: CodexSessionCredential.maximumFileBytes + 1) ?? Data()
    guard data.count <= CodexSessionCredential.maximumFileBytes else {
      throw ProviderError.invalidCodexLogin
    }
    return try CodexSessionCredential(authFileData: data)
  }
}
