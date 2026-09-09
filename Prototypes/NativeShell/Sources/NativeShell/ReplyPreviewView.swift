import SwiftUI

struct ReplyPresentation: Equatable {
  enum State: Equatable { case loading, available, unavailable }

  let senderName: String
  let excerpt: String
  let state: State

  init(_ preview: ReplyPreview) {
    if preview.isLoading {
      senderName = ""
      excerpt = ""
      state = .loading
    } else if preview.isAvailable {
      senderName = preview.speakerName
      excerpt = preview.excerpt
      state = .available
    } else {
      senderName = ""
      excerpt = ""
      state = .unavailable
    }
  }

  static let loading = ReplyPresentation(senderName: "", excerpt: "", state: .loading)

  private init(senderName: String, excerpt: String, state: State) {
    self.senderName = senderName
    self.excerpt = excerpt
    self.state = state
  }

  var accessibilityLabel: String {
    switch state {
    case .loading: "Loading original message"
    case .available: "Reply to \(senderName): \(excerpt)"
    case .unavailable: "Original message unavailable"
    }
  }
}

struct ReplyPreviewView: View {
  let presentation: ReplyPresentation
  var onOpen: (() -> Void)?
  var onCancel: (() -> Void)?
  var isOpening = false

  var body: some View {
    HStack(alignment: .top, spacing: 9) {
      Button {
        onOpen?()
      } label: {
        VStack(alignment: .leading, spacing: 2) {
          Text(title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
          if presentation.state == .available {
            Text(presentation.excerpt).font(.system(size: 12)).foregroundStyle(
              ShellTheme.secondary
            ).lineLimit(2)
          } else if presentation.state == .unavailable {
            Text("It may have been removed or is not loaded.").font(.system(size: 12))
              .foregroundStyle(ShellTheme.secondary).lineLimit(2)
          }
        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(presentation.state != .available || onOpen == nil || isOpening)
      .accessibilityLabel(presentation.accessibilityLabel)
      if presentation.state == .loading {
        ProgressView().controlSize(.small).accessibilityHidden(true)
      } else if isOpening {
        ProgressView().controlSize(.small).accessibilityLabel("Opening original message")
      }
      if let onCancel {
        Button(action: onCancel) {
          Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
            .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain).accessibilityLabel("Cancel reply")
        .accessibilityIdentifier("cancel-reply")
      }
    }
    .fixedSize(horizontal: false, vertical: true)
    .padding(.leading, 20).padding(.trailing, 11).padding(.vertical, 8)
    .background(ShellTheme.contrast.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
    .overlay(alignment: .leading) {
      RoundedRectangle(cornerRadius: 1.5).fill(Color(hex: 0x16be8b)).frame(width: 3)
        .padding(.leading, 11).padding(.vertical, 8).accessibilityHidden(true)
    }
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ShellTheme.contrast.opacity(0.08)))
  }

  private var title: String {
    switch presentation.state {
    case .loading: "Loading original message…"
    case .available: presentation.senderName
    case .unavailable: "Original message unavailable"
    }
  }
}
