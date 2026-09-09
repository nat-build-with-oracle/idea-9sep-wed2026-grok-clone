import SwiftUI

struct WorkspaceExportSection: View {
  @ObservedObject var store: PreviewWorkspace

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      Text("Workspace export").font(.headline)
      Text(
        "Save a JSON snapshot of all saved conversations, prompts, drafts, exact stored text-attachment bytes, routine history and provider endpoints, including hidden bots. Stored credentials are excluded; secrets pasted into workspace content, attachments or configuration are not removed. Review before sharing."
      )
      .font(.caption).foregroundStyle(ShellTheme.secondary)
      .fixedSize(horizontal: false, vertical: true)
      Text(
        "JSON with base64 attachment payloads · No import/restore yet · Unsaved profile/provider edits are not included"
      )
      .font(.caption).foregroundStyle(ShellTheme.secondary)
      .fixedSize(horizontal: false, vertical: true)
      HStack {
        Button("Export Workspace…") { store.exportWorkspace() }
          .disabled(!store.canExportWorkspace)
          .accessibilityIdentifier("workspace.export")
        if store.isExporting {
          ProgressView().controlSize(.small)
          Text("Exporting…").font(.caption)
        }
      }
      if let status = store.exportStatus {
        Text(status).font(.caption).textSelection(.enabled)
      }
      if let error = store.exportError {
        Text(error).font(.caption).foregroundStyle(ShellTheme.warning).textSelection(.enabled)
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}
