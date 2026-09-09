import Foundation

/// Explicit destination for an isolated smoke fixture; production always uses NSSavePanel.
@MainActor struct SmokeWorkspaceExportDestination: WorkspaceExportDestinationChoosing {
  let url: URL
  func choose() async -> URL? { url }
  func cancel() {}
}
