import AppKit
import SwiftUI
import WorkspaceCore

struct WorkspaceView: View {
  @ObservedObject var store: PreviewWorkspace
  @State private var sidebarWidth: CGFloat = 280
  @State private var inspectorWidth: CGFloat = 320

  var body: some View {
    GeometryReader { geometry in
      let sideWidth = store.sidebarVisible ? sidebarWidth : 0
      let showInspector =
        store.inspectorPreferred && store.pickerMode == .closed
        && geometry.size.width >= sideWidth + inspectorWidth + 426
      HStack(spacing: 0) {
        if store.sidebarVisible {
          SidebarView(store: store).frame(width: sidebarWidth)
          PaneDivider(width: $sidebarWidth, bounds: 240...400, direction: 1)
        }
        Group {
          if store.pickerMode != .closed {
            RecipientPickerView(store: store)
          } else {
            ConversationView(store: store)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        if showInspector {
          PaneDivider(width: $inspectorWidth, bounds: 280...440, direction: -1)
          InspectorView(store: store).frame(width: inspectorWidth)
        }
      }
      .background(ShellTheme.background)
    }
    .frame(minWidth: 760, minHeight: 600)
    .foregroundStyle(ShellTheme.foreground)
    .font(.system(size: 15))
    .preferredColorScheme(.dark)
    .ignoresSafeArea()
    .sheet(item: $store.panel) { panel in PrototypePanel(store: store, panel: panel) }
    .sheet(item: $store.editTarget) { target in ProfileEditorView(store: store, target: target) }
    .sheet(item: $store.botDeletionTarget) { _ in BotDeletionView(store: store) }
    .onChange(of: store.search) { _, _ in Task { await store.searchPersistent() } }
    .onChange(of: store.showHidden) { _, _ in Task { await store.searchPersistent() } }
    .disabled(store.isLoading || store.isClosing)
    .overlay(alignment: .top) {
      if store.isLoading || store.isClosing {
        ProgressView(store.isClosing ? "Saving workspace…" : "Opening local workspace…").padding(20)
          .background(ShellTheme.sidebar, in: RoundedRectangle(cornerRadius: 12)).padding(.top, 60)
      } else if let error = store.storageError {
        VStack(spacing: 8) {
          Text(error).foregroundStyle(.orange)
          Text("Your data has not been reset. Unsaved drafts remain in this window.")
            .font(.system(size: 12))
          if store.repository != nil {
            Button("Retry saving drafts") {
              Task {
                do { try await store.recoverStorage() } catch {
                  store.storageError = error.localizedDescription
                }
              }
            }
          } else if let retry = store.retryOpening {
            Button("Retry opening workspace", action: retry)
          }
        }.padding(16).background(ShellTheme.sidebar, in: RoundedRectangle(cornerRadius: 12))
          .padding(.horizontal, 30).padding(.top, 60)
      }
    }
    .onExitCommand {
      if store.botDeletionTarget != nil {
        store.cancelBotDeletion()
      } else if store.editTarget != nil {
        // The editor owns dirty-discard confirmation, including Escape.
      } else if store.panel != nil {
        store.panel = nil
      } else if store.pickerMode != .closed {
        store.pickerMode = .closed
      } else {
        store.notice = nil
      }
    }
  }
}

private struct PaneDivider: View {
  @Binding var width: CGFloat
  let bounds: ClosedRange<CGFloat>
  let direction: CGFloat
  @State private var initialWidth: CGFloat?
  var body: some View {
    Rectangle().fill(ShellTheme.separator).frame(width: 1)
      .overlay {
        Color.clear.frame(width: 7).contentShape(Rectangle())
          .gesture(
            DragGesture(minimumDistance: 1).onChanged { value in
              let initial = initialWidth ?? width
              initialWidth = initial
              width = min(
                bounds.upperBound,
                max(bounds.lowerBound, initial + direction * value.translation.width))
            }.onEnded { _ in initialWidth = nil })
      }
      .accessibilityLabel("Resize pane")
      .accessibilityValue("\(Int(width)) points")
      .accessibilityAdjustableAction { adjustment in
        switch adjustment {
        case .increment: width = min(bounds.upperBound, width + 20)
        case .decrement: width = max(bounds.lowerBound, width - 20)
        @unknown default: break
        }
      }
  }
}

private struct SidebarView: View {
  @ObservedObject var store: PreviewWorkspace
  @FocusState private var searchFocused: Bool
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Spacer()
        ShellIconButton(symbol: "plus", label: "New chat") { store.openPicker() }
          .accessibilityIdentifier("new-chat")
      }.padding(.horizontal, 15).frame(height: 52)

      HStack(spacing: 7) {
        Image(systemName: "magnifyingglass").foregroundStyle(ShellTheme.secondary)
        TextField("Search", text: $store.search).textFieldStyle(.plain)
          .font(.system(size: 16)).focused($searchFocused)
          .accessibilityIdentifier("conversation-search")
        if !store.search.isEmpty {
          Button {
            store.search = ""
          } label: {
            Image(systemName: "xmark.circle.fill")
          }
          .buttonStyle(.plain).accessibilityLabel("Clear search")
        }
      }
      .padding(.horizontal, 11).frame(height: 38)
      .background(ShellTheme.bubble, in: RoundedRectangle(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.08)))
      .padding(.horizontal, 13).padding(.bottom, 9)

      ScrollView {
        LazyVStack(spacing: 5) {
          if store.pickerMode != .closed {
            HStack(spacing: 12) {
              Image(systemName: "plus").font(.system(size: 23)).frame(width: 42, height: 42)
                .background(.white.opacity(0.06), in: Circle())
              Text(store.pickerMode == .group ? "New group chat" : "New chat").fontWeight(.medium)
              Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).frame(height: 70)
            .background(ShellTheme.selected, in: RoundedRectangle(cornerRadius: 12))
          }
          ForEach(store.visibleConversations) { conversation in
            ConversationRow(store: store, conversation: conversation)
          }
          if store.visibleConversations.isEmpty {
            VStack(spacing: 6) {
              Text("No conversations found").foregroundStyle(ShellTheme.foreground)
              Text("Try another name or message.").foregroundStyle(ShellTheme.secondary).font(
                .system(size: 13))
            }.padding(.vertical, 24)
          }
        }.padding(.horizontal, 13)
      }
      .scrollIndicators(.hidden)

      VStack(spacing: 8) {
        Button {
          store.panel = .templates
        } label: {
          HStack(spacing: 12) {
            Image(systemName: "square.grid.2x2").font(.system(size: 17)).frame(
              width: 34, height: 34
            )
            .background(.white.opacity(0.04), in: Circle())
            Text("Marketplace")
            Spacer()
          }.frame(height: 39)
        }.buttonStyle(.plain).accessibilityIdentifier("marketplace")
        Button {
          store.panel = .profile
        } label: {
          HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.fill").font(.system(size: 34))
              .foregroundStyle(Color(hex: 0x7aaef0))
            Text(store.name).lineLimit(1)
            Spacer(minLength: 0)
          }.frame(height: 42)
        }.buttonStyle(.plain).accessibilityIdentifier("profile")
        HStack(spacing: 5) {
          Circle().fill(Color.orange.opacity(0.85)).frame(width: 5, height: 5)
          Text(
            store.isPersistent
              ? "Saved on this Mac · \(store.selectedProvider == nil ? "choose a provider" : "provider configured")"
              : "Sample workspace · not connected"
          ).font(.system(size: 10))
          Spacer(minLength: 0)
        }.foregroundStyle(ShellTheme.secondary)
      }.padding(.horizontal, 21).padding(.top, 15).padding(.bottom, 15)
    }
    .background(ShellTheme.sidebar)
    .onChange(of: store.searchFocusRequest) { _, _ in searchFocused = true }
  }
}

private struct ConversationRow: View {
  @ObservedObject var store: PreviewWorkspace
  let conversation: PreviewConversation
  private var bot: PreviewBot? { store.bots.first { $0.id == conversation.memberIDs.first } }
  private var selected: Bool { store.selectedID == conversation.id && store.pickerMode == .closed }
  var body: some View {
    Button {
      store.select(conversation.id)
    } label: {
      HStack(spacing: 10) {
        if conversation.kind == .group {
          Image(systemName: "person.2.fill").font(.system(size: 19))
            .frame(width: 42, height: 42).background(ShellTheme.bubble, in: Circle())
        } else {
          BotAvatar(color: bot?.color ?? "green", shape: bot?.shape ?? .circle)
        }
        VStack(alignment: .leading, spacing: 4) {
          HStack(alignment: .firstTextBaseline) {
            Text(conversation.title).font(.system(size: 16, weight: .medium)).lineLimit(1)
            Spacer(minLength: 3)
            if !store.isPersistent {
              Text(conversation.id == store.conversations.first?.id ? "9:06 PM" : "Yesterday")
                .font(.system(size: 12)).foregroundStyle(ShellTheme.secondary).lineLimit(1)
            }
          }
          Text(store.messages[conversation.id]?.last?.text ?? "Start a conversation")
            .font(.system(size: 14)).foregroundStyle(ShellTheme.secondary).lineLimit(1)
        }
      }
      .padding(.horizontal, 9).frame(height: 70)
      .contentShape(Rectangle())
      .background(selected ? ShellTheme.selected : .clear, in: RoundedRectangle(cornerRadius: 12))
    }
    .buttonStyle(.plain).accessibilityLabel("Open \(conversation.title)")
    .accessibilityAddTraits(selected ? [.isSelected] : [])
    .contextMenu {
      Button(conversation.kind == .direct ? "Edit Bot…" : "Edit Group…") {
        store.beginEditing(conversation)
      }
      .disabled(store.editTarget != nil || store.isProfileSaving)
      if conversation.kind == .direct {
        Button(bot?.isHidden == true ? "Unhide conversation" : "Hide from sidebar") {
          Task { await store.performToggleHidden(conversation) }
        }
        if let bot, store.isPersistent {
          Button("Delete Bot…", role: .destructive) { store.beginBotDeletion(bot.id) }
            .disabled(!store.canBeginBotDeletion)
        }
      }
      Button("Copy conversation name") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(conversation.title, forType: .string)
      }
    }
  }
}

private struct ConversationView: View {
  @ObservedObject var store: PreviewWorkspace
  @State private var editorHeight: CGFloat = 36
  @State private var nearBottom = true
  var body: some View {
    VStack(spacing: 0) {
      header
      Rectangle().fill(ShellTheme.separator).frame(height: 1)
      if let conversation = store.current {
        transcript(conversation)
        composer
      } else {
        Spacer()
        Text("Choose a conversation").font(.title2)
        Text("Or create your first bot with the + button.").foregroundStyle(ShellTheme.secondary)
          .padding(.top, 5)
        Spacer()
      }
    }
  }

  private var header: some View {
    HStack(spacing: 8) {
      if !store.sidebarVisible {
        ShellIconButton(symbol: "sidebar.left", label: "Show sidebar") {
          store.sidebarVisible = true
        }
      }
      if store.current?.kind == .group {
        Image(systemName: "person.2.fill").frame(width: 26)
      } else if let bot = store.currentBot {
        BotAvatar(color: bot.color, shape: bot.shape, size: 26)
      }
      Text(store.current?.title ?? "Bot Workspace").font(.system(size: 16, weight: .medium))
      Spacer()
      if let conversation = store.current {
        ShellIconButton(
          symbol: "pencil", label: conversation.kind == .direct ? "Edit Bot" : "Edit Group"
        ) {
          store.beginEditing(conversation)
        }
        .accessibilityIdentifier("edit-conversation-profile")
        .disabled(store.editTarget != nil || store.isProfileSaving)
      }
      ShellIconButton(symbol: "sidebar.right", label: "Toggle conversation details") {
        store.inspectorPreferred.toggle()
      }
      .accessibilityIdentifier("toggle-inspector")
    }.padding(.horizontal, 18).frame(height: 52)
  }

  private func transcript(_ conversation: PreviewConversation) -> some View {
    GeometryReader { geometry in
      ScrollViewReader { reader in
        ScrollView {
          LazyVStack(spacing: 22) {
            if store.hasOlderMessages {
              Button("Load earlier messages") { Task { await store.loadOlderMessages() } }
                .font(.system(size: 12))
            }
            ForEach(store.currentMessages) { message in
              messageRow(message, conversationID: conversation.id)
            }
            if store.currentMessages.isEmpty {
              VStack(spacing: 15) {
                if conversation.kind == .group {
                  Image(systemName: "person.2.fill").font(.system(size: 42))
                    .foregroundStyle(ShellTheme.secondary).accessibilityHidden(true)
                } else {
                  BotAvatar(
                    color: store.currentBot?.color ?? "green",
                    shape: store.currentBot?.shape ?? .circle, size: 62)
                }
                Text("A new conversation").font(.system(size: 21, weight: .medium))
                Text(
                  store.isPersistent
                    ? "Your drafts are saved on this Mac. Choose a provider below to send a message. Only the selected bot will reply."
                    : "Try the composer below. This native preview saves messages only for this session; it does not contact an AI provider."
                )
                .foregroundStyle(ShellTheme.secondary).multilineTextAlignment(.center).frame(
                  maxWidth: 340)
              }.frame(maxWidth: .infinity, minHeight: max(250, geometry.size.height - 30))
            }
            Color.clear.frame(height: 1).id("bottom").background {
              GeometryReader { anchor in
                Color.clear.preference(
                  key: BottomPreference.self, value: anchor.frame(in: .named("transcript")).maxY)
              }
            }
          }.padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 12)
        }
        .defaultScrollAnchor(.bottom)
        .coordinateSpace(name: "transcript")
        .onPreferenceChange(BottomPreference.self) { bottom in
          nearBottom = bottom <= geometry.size.height + 50
        }
        .overlay(alignment: .bottom) {
          if !nearBottom {
            Button {
              reader.scrollTo("bottom", anchor: .bottom)
            } label: {
              Label("Jump to latest", systemImage: "arrow.down")
                .font(.system(size: 12)).padding(.horizontal, 13).padding(.vertical, 7)
            }.buttonStyle(.plain).background(ShellTheme.selected, in: Capsule()).padding(.bottom, 8)
          }
        }
        .onChange(of: conversation.id) { _, _ in reader.scrollTo("bottom", anchor: .bottom) }
        .onChange(of: store.currentMessages.count) { _, _ in
          if nearBottom { reader.scrollTo("bottom", anchor: .bottom) }
        }
        .onChange(of: store.currentMessages.last?.text) { _, _ in
          if nearBottom { reader.scrollTo("bottom", anchor: .bottom) }
        }
        .onChange(of: store.transcriptJumpRequest?.requestID) { _, _ in
          guard let request = store.transcriptJumpRequest,
            request.conversationID == conversation.id
          else { return }
          reader.scrollTo(request.messageID, anchor: .center)
        }
      }
    }
  }

  @ViewBuilder
  private func messageRow(_ message: PreviewMessage, conversationID: UUID) -> some View {
    MessageBubble(
      message: message,
      reference: store.replyPreview(for: message),
      isJumpingToReply: store.isJumpingToReply,
      onReply: { Task { await store.beginReply(to: message.id, in: conversationID) } },
      onJumpToReference: { messageID in
        Task { await store.jumpToReply(messageID: messageID, in: conversationID) }
      }
    ).id(message.id)
    ForEach(
      store.generations.filter {
        $0.userMessageID == message.id && $0.state != .completed
      }
    ) { generation in
      GenerationStatusView(store: store, generation: generation)
    }
  }

  private var composer: some View {
    VStack(spacing: 8) {
      if store.currentNeedsMembershipRepair, let conversation = store.current {
        VStack(alignment: .leading, spacing: 6) {
          Text("Group needs repair").font(.headline)
          Text("History and drafts are kept. Choose at least two available members before sending.")
            .font(.caption).fixedSize(horizontal: false, vertical: true)
          Button("Edit Group…") { store.beginEditing(conversation) }
            .disabled(store.isDeletingBot || store.editTarget != nil)
        }.frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityIdentifier("group-membership-repair")
      }
      if store.isPersistent { providerControls }
      if let reply = store.currentReply, let conversation = store.current {
        ReplyPreviewView(
          presentation: ReplyPresentation(reply),
          onOpen: reply.isAvailable
            ? {
              Task { await store.jumpToReply(messageID: reply.id, in: conversation.id) }
            } : nil,
          onCancel: { store.clearReply(in: conversation.id) },
          isOpening: store.isJumpingToReply
        )
        .accessibilityIdentifier("composer-reply-preview")
      }
      if let notice = store.notice {
        HStack(alignment: .top, spacing: 8) {
          Text(notice).font(.system(size: 12)).foregroundStyle(ShellTheme.secondary)
          Spacer(minLength: 0)
          Button {
            store.notice = nil
          } label: {
            Image(systemName: "xmark")
          }
          .buttonStyle(.plain).accessibilityLabel("Dismiss notice")
        }.padding(.horizontal, 8).accessibilityIdentifier("workspace-notice")
      }
      HStack(alignment: .bottom, spacing: 10) {
        Button {
          store.notice =
            "File attachments are planned for the production app. This feasibility preview does not read files."
        } label: {
          Image(systemName: "plus").font(.system(size: 23, weight: .light)).frame(
            width: 33, height: 33
          )
          .background(.white.opacity(0.08), in: Circle())
        }.buttonStyle(.plain).foregroundStyle(ShellTheme.secondary).padding(.bottom, 1)
          .accessibilityLabel("Attachment availability")
        ZStack(alignment: .topLeading) {
          if store.draft.isEmpty {
            Text("Message \(store.current?.title ?? "Bot")").font(.system(size: 16))
              .foregroundStyle(ShellTheme.secondary).padding(.top, 8).allowsHitTesting(false)
          }
          NativeComposer(
            text: Binding(get: { store.draft }, set: { store.draft = $0 }), height: $editorHeight,
            focusRequest: store.composerFocusRequest
          ) { send() }
          .frame(height: editorHeight)
        }
        Button {
          send()
        } label: {
          Image(systemName: "arrow.up").font(.system(size: 17, weight: .semibold))
            .frame(width: 33, height: 33).foregroundStyle(ShellTheme.background)
            .background(
              store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? Color.gray : Color.white, in: Circle())
        }.buttonStyle(.plain).disabled(
          store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isSubmitting
            || store.isDeletingBot || store.currentNeedsMembershipRepair
        )
        .padding(.bottom, 1).help(
          store.isPersistent
            ? "Send to selected provider (Return)" : "Add preview message (Return)"
        )
        .accessibilityLabel(
          store.isPersistent ? "Send message" : "Add preview message"
        ).accessibilityIdentifier("send-message")
      }
      .padding(.horizontal, 9).padding(.vertical, 7)
      .background(ShellTheme.composer, in: RoundedRectangle(cornerRadius: 27))
      .overlay(RoundedRectangle(cornerRadius: 27).strokeBorder(.white.opacity(0.19)))
    }.padding(.horizontal, 22).padding(.top, 8).padding(.bottom, 20)
  }

  private func send() {
    store.performSend()
  }

  private var providerControls: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Picker("Provider", selection: $store.selectedProviderID) {
          Text("Choose provider").tag(Optional<UUID>.none)
          ForEach(store.providers) { Text($0.name).tag(Optional($0.id)) }
        }.accessibilityIdentifier("send-provider")
        Button {
          store.openSettings()
        } label: {
          Image(systemName: "gearshape")
        }
        .buttonStyle(.plain).accessibilityLabel("Configure model provider")
      }
      if let conversation = store.current, conversation.kind == .group {
        Picker(
          "Reply as",
          selection: Binding<UUID?>(
            get: { store.selectedTargetBotIDs[conversation.id] },
            set: { store.selectedTargetBotIDs[conversation.id] = $0 }
          )
        ) {
          Text("Choose one bot").tag(Optional<UUID>.none)
          ForEach(store.bots.filter { conversation.memberIDs.contains($0.id) }) {
            Text($0.name).tag(Optional($0.id))
          }
        }.accessibilityIdentifier("send-target")
      }
      if let provider = store.selectedProvider {
        Text("To: \(provider.apiRoot.absoluteString) · \(provider.modelID)")
          .font(.system(size: 11)).textSelection(.enabled)
          .accessibilityIdentifier("send-destination")
        Text(
          "Sends draft, bot description, up to 100 recent messages, and the original message if replying. No attachments."
        )
        .font(.system(size: 10)).fixedSize(horizontal: false, vertical: true)
      } else {
        Text("No provider selected. Sending keeps your draft; nothing leaves this Mac.")
          .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
      }
    }.foregroundStyle(ShellTheme.secondary).padding(.horizontal, 6)
      .disabled(store.isSubmitting)
  }
}

private struct GenerationStatusView: View {
  @ObservedObject var store: PreviewWorkspace
  let generation: Generation
  private var speakerName: String {
    store.bots.first { $0.id == generation.targetBotID }?.name
      ?? store.messages[generation.conversationID]?.first {
        $0.id == generation.assistantMessageID
      }?.speakerName ?? "Deleted bot"
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack {
        Text(
          "\(speakerName) · \(generation.state.rawValue.capitalized)"
        )
        Spacer()
        if !generation.state.isTerminal {
          Button("Stop") { action { try await store.cancelReply(generation.id) } }
            .accessibilityIdentifier("stop-\(generation.id)")
        } else {
          Button("Retry") { action { try await store.retryReply(generation.id) } }
            .help(
              "Retry using the currently selected provider. The original user message and partial reply are retained."
            )
            .disabled(store.selectedProvider == nil || !store.canRetry(generation))
            .accessibilityIdentifier("retry-\(generation.id)")
        }
      }
      if let error = generation.error { Text(error).foregroundStyle(.orange) }
    }.font(.system(size: 12)).foregroundStyle(ShellTheme.secondary)
      .disabled(store.pendingGenerationActions.contains(generation.id))
  }
  private func action(_ work: @escaping @MainActor () async throws -> Void) {
    Task {
      do { try await work() } catch { store.notice = PreviewWorkspace.providerErrorMessage(error) }
    }
  }
}

private struct BottomPreference: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct MessageBubble: View {
  let message: PreviewMessage
  let reference: ReplyPreview?
  let isJumpingToReply: Bool
  let onReply: () -> Void
  let onJumpToReference: (UUID) -> Void
  var body: some View {
    VStack(spacing: 22) {
      if let timestamp = message.timestamp {
        Text(timestamp).font(.system(size: 12)).foregroundStyle(ShellTheme.secondary).padding(
          .top, 6)
      }
      if message.role == .event {
        Text(message.text).font(.system(size: 13)).foregroundStyle(ShellTheme.secondary).padding(
          .vertical, 1)
      } else {
        HStack {
          if message.role == .user { Spacer(minLength: 40) }
          VStack(alignment: .leading, spacing: 5) {
            if let speaker = message.speakerName {
              Text(speaker).font(.system(size: 11, weight: .medium)).foregroundStyle(
                ShellTheme.secondary
              )
              .accessibilityLabel("Reply from \(speaker)")
            }
            if let replyToID = message.replyToID {
              let presentation =
                reference.map {
                  ReplyPresentation($0)
                } ?? .loading
              ReplyPreviewView(
                presentation: presentation,
                onOpen: presentation.state == .available
                  ? { onJumpToReference(replyToID) } : nil,
                isOpening: isJumpingToReply
              )
              .frame(maxWidth: 520, alignment: .leading)
              .accessibilityIdentifier("reply-reference-\(message.id)")
            }
            Text(message.text).font(.system(size: 16)).lineSpacing(4)
              .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
              .padding(.horizontal, 15).padding(.vertical, 11)
              .background(
                message.role == .user ? Color(hex: 0x5a5a5a) : ShellTheme.bubble,
                in: RoundedRectangle(cornerRadius: 22)
              )
              .frame(maxWidth: 550, alignment: message.role == .user ? .trailing : .leading)
            HStack(spacing: 12) {
              Button("Reply", action: onReply)
                .accessibilityLabel("Reply to message")
                .accessibilityIdentifier("reply-message-\(message.id)")
                .disabled(message.text.isEmpty)
              Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.text, forType: .string)
              }
              .accessibilityLabel("Copy message text")
              .accessibilityIdentifier("copy-message-\(message.id)")
            }
            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(ShellTheme.secondary)
          }
          if message.role != .user { Spacer(minLength: 40) }
        }.frame(maxWidth: .infinity)
      }
    }
  }
}

private struct InspectorView: View {
  @ObservedObject var store: PreviewWorkspace
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Spacer()
        ShellIconButton(symbol: "gearshape", label: "Settings") { store.openSettings() }
        ShellIconButton(symbol: "chevron.right.2", label: "Hide conversation details") {
          store.inspectorPreferred = false
        }
      }.padding(.horizontal, 15).frame(height: 52)
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          if let conversation = store.current {
            Button {
              store.beginEditing(conversation)
            } label: {
              Label(
                conversation.kind == .direct ? "Edit Bot profile" : "Edit Group members",
                systemImage: "pencil")
            }
            .accessibilityIdentifier("inspector-edit-profile")
            .disabled(store.editTarget != nil || store.isProfileSaving)
            .padding(.bottom, 14)
            if let bot = store.currentBot, !bot.description.isEmpty {
              Text(bot.description).font(.system(size: 12)).foregroundStyle(ShellTheme.secondary)
                .fixedSize(horizontal: false, vertical: true).padding(.bottom, 14)
            } else if conversation.kind == .group {
              Text(
                conversation.memberIDs.compactMap { id in store.bots.first { $0.id == id }?.name }
                  .joined(separator: ", ")
              )
              .font(.system(size: 12)).foregroundStyle(ShellTheme.secondary)
              .fixedSize(horizontal: false, vertical: true).padding(.bottom, 14)
            }
          }
          VStack(spacing: 11) {
            Image(systemName: "desktopcomputer").font(.system(size: 32, weight: .ultraLight))
              .foregroundStyle(ShellTheme.secondary)
            Text("No computer connected").font(.system(size: 13, weight: .medium))
            Text("No live computer service is configured\nfor this workspace.")
              .font(.system(size: 11)).foregroundStyle(ShellTheme.secondary).multilineTextAlignment(
                .center)
          }
          .frame(maxWidth: .infinity).frame(height: 174)
          .background(Color(hex: 0x191919), in: RoundedRectangle(cornerRadius: 9))
          .accessibilityIdentifier("computer-disconnected")
          Text("\(store.currentBot?.name ?? "Group")'s screen")
            .font(.system(size: 13)).foregroundStyle(ShellTheme.secondary)
            .frame(maxWidth: .infinity).padding(.top, 10).padding(.bottom, 22)
          HStack {
            Text("Routines").foregroundStyle(ShellTheme.secondary)
            Spacer()
            ShellIconButton(symbol: "plus", label: "Add routine") { store.panel = .routine }
              .disabled(store.currentBot == nil)
          }.padding(.bottom, 8)
          let routines = store.routines.filter { $0.botID == store.currentBot?.id }
          ForEach(routines) { routine in
            Button {
              store.notice =
                "This routine is paused. Editing and scheduling are not connected yet."
            } label: {
              HStack(alignment: .top, spacing: 12) {
                Image(systemName: "clock").foregroundStyle(Color(hex: 0x16be8b)).font(
                  .system(size: 18)
                ).padding(.top, 5)
                VStack(alignment: .leading, spacing: 4) {
                  Text(routine.name).font(.system(size: 15))
                  Text(
                    routine.intervalMinutes % 60 == 0
                      ? "Every \(routine.intervalMinutes / 60) hours"
                      : "Every \(routine.intervalMinutes) minutes"
                  )
                  .foregroundStyle(ShellTheme.secondary)
                  Text(
                    store.isPersistent
                      ? "Paused · scheduler not connected" : "Paused · sample routine"
                  ).font(.system(size: 10)).foregroundStyle(
                    ShellTheme.secondary)
                }
                Spacer(minLength: 0)
              }.padding(.vertical, 7)
            }.buttonStyle(.plain)
          }
          if routines.isEmpty {
            Text(
              store.current?.kind == .group
                ? "Open a bot conversation to add its routine." : "No routines yet"
            )
            .foregroundStyle(ShellTheme.secondary).font(.system(size: 13))
            .padding(.vertical, 14)
          }
        }.padding(.horizontal, 19)
      }
      Spacer(minLength: 0)
    }
  }
}
