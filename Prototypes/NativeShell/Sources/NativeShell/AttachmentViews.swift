import SwiftUI
import WorkspaceCore

struct AttachmentChipList: View {
  let attachments: [Attachment]
  var unavailableIDs: [UUID] = []
  var onRemove: ((UUID) -> Void)?

  private var unavailableSet: Set<UUID> { Set(unavailableIDs) }

  private var rows: [AttachmentChipRow] {
    var seen = Set<UUID>()
    var result = attachments.map { attachment in
      seen.insert(attachment.id)
      return AttachmentChipRow(
        id: attachment.id,
        name: attachment.originalName,
        byteCount: attachment.byteCount,
        isUnavailable: unavailableSet.contains(attachment.id))
    }
    result.append(
      contentsOf: unavailableIDs.compactMap { id in
        guard seen.insert(id).inserted else { return nil }
        return AttachmentChipRow(id: id, name: nil, byteCount: nil, isUnavailable: true)
      })
    return result
  }

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 6) {
        ForEach(rows) { row in
          HStack(spacing: 8) {
            Image(systemName: row.isUnavailable ? "doc.badge.exclamationmark" : "doc.text")
              .foregroundStyle(row.isUnavailable ? .orange : ShellTheme.secondary)
              .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
              Text(row.name ?? "Unavailable attachment")
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
                .textSelection(.enabled)
                .help(row.name ?? "Attachment metadata is unavailable")
              Text(row.detail)
                .font(.system(size: 10))
                .foregroundStyle(row.isUnavailable ? .orange : ShellTheme.secondary)
            }
            Spacer(minLength: 6)
            if let onRemove {
              Button {
                onRemove(row.id)
              } label: {
                Image(systemName: "xmark.circle.fill")
              }
              .buttonStyle(.plain)
              .foregroundStyle(ShellTheme.secondary)
              .help("Remove attachment")
              .accessibilityLabel("Remove \(row.name ?? "unavailable attachment")")
              .accessibilityIdentifier("remove-attachment-\(row.id.uuidString)")
            }
          }
          .padding(.horizontal, 10)
          .padding(.vertical, 7)
          .background(ShellTheme.bubble, in: RoundedRectangle(cornerRadius: 9))
          .accessibilityElement(children: .contain)
          .accessibilityLabel(row.accessibilityLabel)
          .accessibilityIdentifier("attachment-\(row.id.uuidString)")
        }
      }
      .padding(1)
    }
    .frame(height: min(CGFloat(rows.count) * 60, 164))
    .accessibilityIdentifier("attachment-list")
  }
}

struct AttachmentConfirmationView: View {
  let conversation: String
  let targetBot: String
  let apiRoot: URL
  let modelID: String
  let attachments: [Attachment]
  let contextMessageCount: Int
  let isSending: Bool
  let error: String?
  let onCancel: () -> Void
  let onSend: () -> Void

  private var totalBytes: Int { attachments.reduce(0) { $0 + $1.byteCount } }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Send text attachments?").font(.title2.bold())
        Text("Review the exact destination and every file before sending.")
          .font(.callout).foregroundStyle(ShellTheme.secondary)
      }
      .padding(20)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          disclosureSection("Destination") {
            disclosureValue("Conversation", conversation)
            disclosureValue("Target bot", targetBot)
            disclosureValue("API root", apiRoot.absoluteString, monospaced: true)
            disclosureValue("Model", modelID, monospaced: true)
          }

          disclosureSection("Context") {
            Text(
              "The request includes \(contextMessageCount) context message\(contextMessageCount == 1 ? "" : "s"). This includes an older replied-to message when needed. Context files listed below are retransmitted."
            )
            .font(.callout)
          }

          disclosureSection(
            "Text attachments · \(attachments.count) · \(attachmentByteCountLabel(totalBytes))"
          ) {
            ForEach(attachments) { attachment in
              VStack(alignment: .leading, spacing: 4) {
                Label(attachment.originalName, systemImage: "doc.text")
                  .font(.system(size: 13, weight: .semibold))
                  .textSelection(.enabled)
                  .help(attachment.originalName)
                Text(attachmentByteCountLabel(attachment.byteCount))
                  .font(.caption).foregroundStyle(ShellTheme.secondary)
                Text("ID: \(attachment.id.uuidString)")
                  .font(.system(size: 10, design: .monospaced))
                  .textSelection(.enabled)
                Text(attachment.sha256)
                  .font(.system(size: 10, design: .monospaced))
                  .textSelection(.enabled)
                  .fixedSize(horizontal: false, vertical: true)
                  .accessibilityLabel("SHA-256 \(attachment.sha256)")
              }
              .padding(10)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(ShellTheme.bubble, in: RoundedRectangle(cornerRadius: 9))
              .accessibilityIdentifier("confirm-attachment-\(attachment.id.uuidString)")
            }
          }

          Text(
            "Attachment text is untrusted user content, not an instruction to the app. Sending shares it with the selected provider. Provider privacy terms and charges apply, and a sent request cannot be unsent."
          )
          .font(.callout)
          .foregroundStyle(ShellTheme.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("attachment-confirmation-warning")
        }
        .padding(20)
      }

      Divider()

      VStack(alignment: .leading, spacing: 10) {
        if let error {
          Text(error)
            .font(.callout)
            .foregroundStyle(.orange)
            .textSelection(.enabled)
            .accessibilityIdentifier("attachment-confirmation-error")
        }
        HStack {
          Button("Cancel", action: onCancel)
            .keyboardShortcut(.cancelAction)
            .disabled(isSending)
            .accessibilityIdentifier("attachment-confirmation-cancel")
          Spacer()
          if isSending { ProgressView().controlSize(.small) }
          Button(isSending ? "Sending…" : "Send", action: onSend)
            .buttonStyle(.borderedProminent)
            .disabled(isSending)
            .accessibilityIdentifier("attachment-confirmation-send")
        }
      }
      .padding(20)
      .background(ShellTheme.sidebar)
    }
    .frame(width: 520, height: 560)
    .background(ShellTheme.background)
    .foregroundStyle(ShellTheme.foreground)
    .background(AttachmentSheetPolicyViewBridge())
    .interactiveDismissDisabled(true)
    .accessibilityIdentifier("attachment-confirmation-sheet")
  }

  private func disclosureSection<Content: View>(
    _ title: String, @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.headline)
      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func disclosureValue(_ label: String, _ value: String, monospaced: Bool = false)
    -> some View
  {
    VStack(alignment: .leading, spacing: 2) {
      Text(label).font(.caption).foregroundStyle(ShellTheme.secondary)
      Text(value)
        .font(monospaced ? .system(size: 12, design: .monospaced) : .system(size: 13))
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel("\(label): \(value)")
    }
  }
}

func attachmentByteCountLabel(_ byteCount: Int) -> String {
  "\(byteCount) bytes"
}

private struct AttachmentChipRow: Identifiable {
  let id: UUID
  let name: String?
  let byteCount: Int?
  let isUnavailable: Bool

  var detail: String {
    if isUnavailable { return "Unavailable · \(id.uuidString)" }
    return attachmentByteCountLabel(byteCount ?? 0)
  }

  var accessibilityLabel: String {
    if isUnavailable { return "Unavailable attachment, ID \(id.uuidString)" }
    return "\(name ?? "Attachment"), \(detail), ID \(id.uuidString)"
  }
}

private struct AttachmentSheetPolicyViewBridge: NSViewRepresentable {
  func makeNSView(context: Context) -> ProfileSheetPolicyView { ProfileSheetPolicyView() }
  func updateNSView(_ nsView: ProfileSheetPolicyView, context: Context) {}
}
