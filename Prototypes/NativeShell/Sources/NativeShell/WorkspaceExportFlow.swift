import Foundation
import WorkspaceCore

enum WorkspaceExportFlowError: Error, LocalizedError {
  case workspaceChanged, failed

  var errorDescription: String? {
    switch self {
    case .workspaceChanged: "The workspace changed. Export again from the current workspace."
    case .failed:
      "Export did not complete. Check the destination, available space and workspace save status, then try again."
    }
  }
}

extension PreviewWorkspace {
  var canExportWorkspace: Bool {
    isPersistent && repository != nil && !isLoading && !isClosing && !isExporting
      && !isDeletingBot && botDeletionTarget == nil
  }

  func exportWorkspace() {
    guard canExportWorkspace else { return }
    performWorkspaceExport(destination: NativeWorkspaceExportDestination())
  }

  @discardableResult
  func performWorkspaceExport(
    destination: any WorkspaceExportDestinationChoosing,
    maxBytes: Int = WorkspaceExportDocument.defaultMaxEncodedBytes,
    write: @escaping @Sendable (Data, URL) async throws -> Void = {
      try await WorkspaceExportFileWriter.write($0, to: $1)
    }
  ) -> Task<Void, Never>? {
    guard canExportWorkspace, let repository else { return nil }
    let context = replyContextGeneration
    // Claim synchronously; another menu/button action cannot start a second panel.
    isExporting = true
    exportStatus = nil
    exportError = nil
    var selectionCancelled = false
    cancelExportSelection = {
      selectionCancelled = true
      destination.cancel()
    }
    exportTask = Task {
      defer {
        cancelExportSelection = nil
        isExporting = false
        isExportWriting = false
        exportTask = nil
      }
      // Quit/connect can cancel synchronously before this task first presents a panel.
      guard !selectionCancelled, !isClosing, context == replyContextGeneration else { return }
      guard let url = await destination.choose(), !selectionCancelled else { return }
      cancelExportSelection = nil
      do {
        try Task.checkCancellation()
        guard !isClosing, context == replyContextGeneration else {
          throw WorkspaceExportFlowError.workspaceChanged
        }
        try await flushDrafts()
        guard context == replyContextGeneration else {
          throw WorkspaceExportFlowError.workspaceChanged
        }
        let document = try await repository.exportSnapshot()
        let data = try await Task.detached(priority: .utility) {
          try document.encoded(maxBytes: maxBytes)
        }.value
        try Task.checkCancellation()
        guard context == replyContextGeneration else {
          throw WorkspaceExportFlowError.workspaceChanged
        }
        // After accepting this immutable snapshot, quit waits for this write to finish.
        isExportWriting = true
        try await write(data, url)
        guard context == replyContextGeneration else { return }
        exportStatus =
          "Exported \(document.summary.conversationCount) conversations and \(document.summary.messageCount) messages. Stored credentials excluded."
      } catch {
        guard context == replyContextGeneration else { return }
        // Filesystem errors can include paths; never display arbitrary transport/filesystem errors.
        if let known = error as? WorkspaceExportError {
          exportError = known.localizedDescription
        } else if let known = error as? WorkspaceExportFlowError {
          exportError = known.localizedDescription
        } else {
          exportError = WorkspaceExportFlowError.failed.localizedDescription
        }
      }
    }
    return exportTask
  }
}
