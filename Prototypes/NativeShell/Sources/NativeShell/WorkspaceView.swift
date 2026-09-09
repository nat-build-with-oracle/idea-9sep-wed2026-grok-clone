import AppKit
import SwiftUI
import WorkspaceCore

struct WorkspaceView: View {
  @ObservedObject var store: PreviewWorkspace

  var body: some View {
    GeometryReader { geometry in
      let layout = WorkspaceLayout(
        containerWidth: Double(geometry.size.width), preferences: store.preferences,
        pickerOpen: store.pickerMode != .closed)
      HStack(spacing: 0) {
        if store.sidebarVisible {
          SidebarView(store: store).frame(width: layout.sidebarWidth)
          PaneDivider(
            width: $store.preferences.sidebarWidth, displayedWidth: layout.sidebarWidth,
            bounds: WorkspacePreferences.sidebarBounds,
            direction: 1)
        }
        Group {
          if store.pickerMode != .closed {
            RecipientPickerView(store: store)
          } else {
            ConversationView(store: store)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        if layout.showsInspector {
          PaneDivider(
            width: $store.preferences.inspectorWidth, displayedWidth: layout.inspectorWidth,
            bounds: WorkspacePreferences.inspectorBounds,
            direction: -1)
          InspectorView(store: store).frame(width: layout.inspectorWidth)
        }
      }
      .background(ShellTheme.background)
    }
    .frame(minWidth: 760, minHeight: 600)
    .foregroundStyle(ShellTheme.foreground)
    .font(.system(size: 15))
    .ignoresSafeArea()
    .sheet(item: $store.panel) { panel in PrototypePanel(store: store, panel: panel) }
    .sheet(item: $store.editTarget) { target in ProfileEditorView(store: store, target: target) }
    .sheet(item: $store.attachmentConfirmationTarget) { target in
      AttachmentConfirmationView(
        conversation: target.conversation, targetBot: target.targetBot,
        targetBots: target.targetBots, requestCount: target.requestCount, isRound: target.isRound,
        apiRoot: target.plan.provider.apiRoot, modelID: target.plan.provider.modelID,
        attachments: target.plan.attachments, contextMessageCount: target.plan.contextMessageCount,
        isSending: store.isConfirmingAttachmentSend, error: store.attachmentConfirmationError,
        onCancel: { store.cancelAttachmentConfirmation() },
        onSend: { store.confirmAttachmentSend() })
    }
    .sheet(item: $store.botDeletionTarget) { _ in BotDeletionView(store: store) }
    .sheet(item: $store.routineDetailTarget) { RoutineDetailView(store: store, target: $0) }
    .sheet(
      item: Binding(
        get: { store.routineDetailTarget == nil ? store.routineEditTarget : nil },
        set: { if store.routineDetailTarget == nil { store.routineEditTarget = $0 } }
      )
    ) { RoutineEditorView(store: store, target: $0) }
    .onChange(of: store.search) { _, _ in Task { await store.searchPersistent() } }
    .onChange(of: store.showHidden) { _, _ in Task { await store.searchPersistent() } }
    .onChange(of: store.visibleReadReceipt, initial: true) { _, _ in
      store.requestVisibleReadReceipt()
    }
    .disabled(store.isLoading || store.isClosing)
    .overlay(alignment: .top) {
      if store.isLoading || store.isClosing {
        ProgressView(store.isClosing ? "Saving workspace…" : "Opening local workspace…").padding(20)
          .background(ShellTheme.sidebar, in: RoundedRectangle(cornerRadius: 12)).padding(.top, 60)
      } else if let error = store.storageError {
        VStack(spacing: 8) {
          Text(error).foregroundStyle(ShellTheme.warning)
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
      if store.attachmentConfirmationTarget != nil {
        store.cancelAttachmentConfirmation()
      } else if store.routineEditTarget != nil {
        // The routine editor owns dirty-discard handling.
      } else if store.routineDetailTarget != nil {
        store.closeRoutine()
      } else if store.botDeletionTarget != nil {
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
  @Binding var width: Double
  let displayedWidth: Double
  let bounds: ClosedRange<Double>
  let direction: Double
  @State private var initialWidth: Double?
  var body: some View {
    Rectangle().fill(ShellTheme.separator).frame(width: 1)
      .overlay {
        Color.clear.frame(width: 7).contentShape(Rectangle())
          .gesture(
            DragGesture(minimumDistance: 1).onChanged { value in
              let initial = initialWidth ?? displayedWidth
              initialWidth = initial
              width = min(
                bounds.upperBound,
                max(bounds.lowerBound, initial + direction * Double(value.translation.width)))
            }.onEnded { _ in initialWidth = nil })
      }
      .accessibilityLabel("Resize pane")
      .accessibilityValue("\(Int(displayedWidth)) points")
      .accessibilityAdjustableAction { adjustment in
        switch adjustment {
        case .increment: width = min(bounds.upperBound, displayedWidth + 20)
        case .decrement: width = max(bounds.lowerBound, displayedWidth - 20)
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
      .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ShellTheme.contrast.opacity(0.08)))
      .padding(.horizontal, 13).padding(.bottom, 9)

      ScrollView {
        LazyVStack(spacing: 5) {
          if store.pickerMode != .closed {
            HStack(spacing: 12) {
              Image(systemName: "plus").font(.system(size: 23)).frame(width: 42, height: 42)
                .background(ShellTheme.contrast.opacity(0.06), in: Circle())
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
            .background(ShellTheme.contrast.opacity(0.04), in: Circle())
            Text("Marketplace")
            Spacer()
          }.frame(height: 39)
        }.buttonStyle(.plain).accessibilityIdentifier("marketplace")
        Button {
          store.panel = .profile
        } label: {
          HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.fill").font(.system(size: 34))
              .foregroundStyle(ShellTheme.profileIcon)
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
  private var unreadCount: Int {
    store.conversationActivity[conversation.id]?.unreadAssistantCount ?? 0
  }
  private var accessibilitySummary: String {
    let timestamp = store.conversationActivity[conversation.id]?.lastMessageAt?.formatted(
      date: .complete, time: .shortened)
    return
      ([store.sidebarPreview(for: conversation), timestamp].compactMap { $0 }
      + [unreadCount == 1 ? "1 unread reply" : "\(unreadCount) unread replies"]).joined(
        separator: ". ")
  }
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
            Text(conversation.title)
              .font(.system(size: 16, weight: unreadCount > 0 ? .semibold : .medium)).lineLimit(1)
            Spacer(minLength: 3)
            if let timestamp = store.sidebarTimestamp(for: conversation) {
              Text(timestamp)
                .font(.system(size: 12)).foregroundStyle(ShellTheme.secondary).lineLimit(1)
            }
          }
          HStack(spacing: 6) {
            Text(store.sidebarPreview(for: conversation))
              .font(.system(size: 14)).foregroundStyle(ShellTheme.secondary).lineLimit(1)
              .frame(maxWidth: .infinity, alignment: .leading)
            if unreadCount > 0 {
              Text(unreadCount > 99 ? "99+" : "\(unreadCount)")
                .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(ShellTheme.bubble, in: Capsule())
                .accessibilityHidden(true)
            }
          }
        }
      }
      .padding(.horizontal, 9).frame(height: 70)
      .contentShape(Rectangle())
      .background(selected ? ShellTheme.selected : .clear, in: RoundedRectangle(cornerRadius: 12))
    }
    .buttonStyle(.plain).accessibilityElement(children: .ignore)
    .accessibilityLabel("Open \(conversation.title)").accessibilityValue(accessibilitySummary)
    .accessibilityIdentifier("conversation-\(conversation.id.uuidString)")
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
      if let error = store.readStatusError {
        HStack(alignment: .top, spacing: 8) {
          Text(error).font(.system(size: 12)).foregroundStyle(ShellTheme.warning)
          Spacer(minLength: 0)
          Button("Retry read status") { store.retryReadStatus() }
            .font(.system(size: 12)).accessibilityIdentifier("retry-read-status")
        }.padding(10).background(ShellTheme.sidebar)
      }
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
      if store.isPersistent, store.current != nil {
        Menu {
          Button("Add Routine…") { store.beginRoutineEditing() }
          ForEach(store.visibleRoutineDefinitions) { routine in
            Button(routine.name) { store.openRoutine(routine.id) }
          }
        } label: {
          Image(systemName: "clock")
        }
        .menuStyle(.borderlessButton).frame(width: 28)
        .accessibilityLabel("Routines").accessibilityIdentifier("routine-menu")
        .disabled(!store.canOpenRoutine)
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
                    ? conversation.kind == .group
                      ? "Your drafts are saved on this Mac. Choose a provider and one or more ordered reply bots below."
                      : "Your drafts are saved on this Mac. Choose a provider below to send a message."
                    : "Try the composer below. This native preview saves messages only for this session; it does not contact an AI provider."
                )
                .foregroundStyle(ShellTheme.secondary).multilineTextAlignment(.center).frame(
                  maxWidth: 340)
              }.frame(maxWidth: .infinity, minHeight: max(250, geometry.size.height - 30))
            }
            Color.clear.frame(height: 1).id("bottom").background {
              GeometryReader { anchor in
                Color.clear.preference(
                  key: BottomPreference.self,
                  value: TranscriptBottom(
                    conversationID: conversation.id,
                    latestSequence: store.currentMessages.last?.sequence ?? 0,
                    latestMessageID: store.currentMessages.last?.id,
                    latestMessageTextByteCount: store.currentMessages.last?.text.utf8.count ?? 0,
                    viewportHeight: geometry.size.height,
                    bottom: anchor.frame(in: .named("transcript")).maxY))
              }
            }
          }.padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 12)
        }
        .defaultScrollAnchor(.bottom)
        .coordinateSpace(name: "transcript")
        .onPreferenceChange(BottomPreference.self) { position in
          guard let position, position.conversationID == conversation.id else { return }
          nearBottom = position.bottom > 0 && position.bottom <= geometry.size.height + 50
          store.recordReadViewport(
            ConversationReadViewport(
              conversationID: position.conversationID, latestSequence: position.latestSequence,
              latestMessageID: position.latestMessageID,
              latestMessageTextByteCount: position.latestMessageTextByteCount,
              isAtLatest: ConversationReadViewport.bottomIsVisible(
                Double(position.bottom), in: Double(position.viewportHeight))))
        }
        .onDisappear {
          if store.readViewport?.conversationID == conversation.id { store.readViewport = nil }
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
      attachments: message.attachmentIDs.compactMap { store.attachmentMetadata[$0] },
      unavailableAttachmentIDs: message.attachmentIDs.filter {
        store.attachmentMetadata[$0] == nil || store.unavailableAttachmentIDs.contains($0)
      },
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
      }.sorted {
        ($0.roundIndex ?? Int.max, $0.id.uuidString)
          < ($1.roundIndex ?? Int.max, $1.id.uuidString)
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
      if !store.currentDraftAttachmentIDs.isEmpty, let conversation = store.current {
        AttachmentChipList(
          attachments: store.currentDraftAttachmentIDs.compactMap { store.attachmentMetadata[$0] },
          unavailableIDs: store.currentDraftAttachmentIDs.filter {
            store.attachmentMetadata[$0] == nil || store.unavailableAttachmentIDs.contains($0)
          },
          onRemove: { store.removeDraftAttachment($0, in: conversation.id) }
        )
        .disabled(
          store.isAttachingFiles || store.isSubmitting || store.attachmentConfirmationTarget != nil
        )
        .accessibilityIdentifier("draft-attachments")
      }
      if store.isAttachingFiles {
        ProgressView("Copying selected text files…").controlSize(.small)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      HStack(alignment: .bottom, spacing: 10) {
        Button {
          if store.isPersistent {
            store.chooseAttachments()
          } else {
            store.notice =
              "The sample preview does not read files. Use BotWorkspace to attach text files."
          }
        } label: {
          Image(systemName: "plus").font(.system(size: 23, weight: .light)).frame(
            width: 33, height: 33
          )
          .background(ShellTheme.contrast.opacity(0.08), in: Circle())
        }.buttonStyle(.plain).foregroundStyle(ShellTheme.secondary).padding(.bottom, 1)
          .disabled(store.isPersistent && !store.canChooseAttachments)
          .accessibilityLabel("Attach text files")
          .accessibilityIdentifier("attach-text-files")
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
                && store.currentDraftAttachmentIDs.isEmpty
                ? Color.gray : ShellTheme.sendButton, in: Circle())
        }.buttonStyle(.plain).disabled(
          (store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && store.currentDraftAttachmentIDs.isEmpty) || store.isSubmitting
            || store.isDeletingBot || store.currentNeedsMembershipRepair || store.isAttachingFiles
            || store.attachmentConfirmationTarget != nil
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
      .overlay(RoundedRectangle(cornerRadius: 27).strokeBorder(ShellTheme.contrast.opacity(0.19)))
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
        let members = store.bots.filter { conversation.memberIDs.contains($0.id) }
        let selected = store.selectedTargetBotIDsForCurrent
        VStack(alignment: .leading, spacing: 5) {
          HStack {
            Text("Reply as")
            Spacer()
            Menu(selected.isEmpty ? "Choose bots" : "\(selected.count) selected") {
              ForEach(members) { bot in
                Button {
                  store.toggleGroupTarget(bot.id, in: conversation.id)
                } label: {
                  Label(
                    bot.name,
                    systemImage: selected.contains(bot.id) ? "checkmark.circle.fill" : "circle")
                }
              }
            }
            .accessibilityLabel("Choose group reply bots")
            .accessibilityValue(selected.isEmpty ? "None selected" : "\(selected.count) selected")
            .accessibilityIdentifier("send-target")
          }
          if !selected.isEmpty {
            ScrollView {
              VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(selected.enumerated()), id: \.element) { index, id in
                  let name = members.first(where: { $0.id == id })?.name ?? "Deleted bot"
                  HStack(spacing: 6) {
                    Text("\(index + 1). \(name)").lineLimit(1).help(name)
                    Spacer(minLength: 4)
                    Button {
                      store.moveGroupTarget(id, in: conversation.id, offset: -1)
                    } label: {
                      Image(systemName: "arrow.up")
                    }
                    .disabled(index == 0).accessibilityLabel("Move \(name) earlier")
                    Button {
                      store.moveGroupTarget(id, in: conversation.id, offset: 1)
                    } label: {
                      Image(systemName: "arrow.down")
                    }
                    .disabled(index == selected.count - 1)
                    .accessibilityLabel("Move \(name) later")
                    Button {
                      store.toggleGroupTarget(id, in: conversation.id)
                    } label: {
                      Image(systemName: "xmark.circle")
                    }
                    .accessibilityLabel("Remove \(name) from group round")
                  }
                  .buttonStyle(.plain)
                  .font(.system(size: 11))
                  .accessibilityElement(children: .contain)
                  .accessibilityIdentifier("selected-round-target-\(index)")
                }
              }
            }
            .frame(height: min(CGFloat(selected.count) * 25, 82))
            Text(
              selected.count > 1
                ? "One ordered request per bot. You will review the full round before sending."
                : "Select more bots to create an ordered group round."
            )
            .font(.system(size: 10)).fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      if let provider = store.selectedProvider {
        Text("To: \(provider.apiRoot.absoluteString) · \(provider.modelID)")
          .font(.system(size: 11)).textSelection(.enabled)
          .accessibilityIdentifier("send-destination")
        Text(
          "Sends draft, bot description, up to 100 recent messages, and the original message if replying. Text files in the draft or context require confirmation for each send, including retries."
        )
        .font(.system(size: 10)).fixedSize(horizontal: false, vertical: true)
      } else {
        Text("No provider selected. Sending keeps your draft; nothing leaves this Mac.")
          .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
      }
    }.foregroundStyle(ShellTheme.secondary).padding(.horizontal, 6)
      .disabled(store.isSubmitting || store.attachmentConfirmationTarget != nil)
  }
}

private struct GenerationStatusView: View {
  @ObservedObject var store: PreviewWorkspace
  let generation: Generation
  private var isRound: Bool {
    store.generations.lazy.filter { $0.userMessageID == generation.userMessageID }.prefix(2).count
      > 1
  }
  private var speakerName: String {
    generation.targetSpeakerNameSnapshot
      ?? store.bots.first { $0.id == generation.targetBotID }?.name
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
          Button(isRound ? "Stop round" : "Stop") {
            action { try await store.cancelReply(generation.id) }
          }
          .accessibilityIdentifier("stop-\(generation.id)")
        } else if generation.routineRunID != nil {
          Text("Routine run · retry unavailable here").font(.caption)
        } else {
          Button("Retry") { store.performRetry(generation.id) }
            .help(
              isRound
                ? "Finish or Stop the round before retrying this member with the selected provider. Other members are not resent."
                : "Retry using the currently selected provider. The original user message and partial reply are retained."
            )
            .disabled(store.selectedProvider == nil || !store.canRetry(generation))
            .accessibilityIdentifier("retry-\(generation.id)")
        }
      }
      if let error = generation.error { Text(error).foregroundStyle(ShellTheme.warning) }
    }.font(.system(size: 12)).foregroundStyle(ShellTheme.secondary)
      .disabled(store.pendingGenerationActions.contains(generation.id))
  }
  private func action(_ work: @escaping @MainActor () async throws -> Void) {
    Task {
      do { try await work() } catch { store.notice = PreviewWorkspace.providerErrorMessage(error) }
    }
  }
}

private struct TranscriptBottom: Equatable {
  let conversationID: UUID
  let latestSequence: Int64
  let latestMessageID: UUID?
  let latestMessageTextByteCount: Int
  let viewportHeight: CGFloat
  let bottom: CGFloat
}

private struct BottomPreference: PreferenceKey {
  static let defaultValue: TranscriptBottom? = nil
  static func reduce(value: inout TranscriptBottom?, nextValue: () -> TranscriptBottom?) {
    if let next = nextValue() { value = next }
  }
}

private struct MessageBubble: View {
  let message: PreviewMessage
  let attachments: [Attachment]
  let unavailableAttachmentIDs: [UUID]
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
            VStack(alignment: .leading, spacing: 7) {
              if !message.text.isEmpty {
                Text(message.text).font(.system(size: 16)).lineSpacing(4)
                  .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
              }
              if !message.attachmentIDs.isEmpty {
                AttachmentChipList(
                  attachments: attachments, unavailableIDs: unavailableAttachmentIDs
                )
                .accessibilityIdentifier("message-attachments-\(message.id)")
              }
            }
            .padding(.horizontal, 15).padding(.vertical, 11)
            .background(
              message.role == .user ? ShellTheme.userBubble : ShellTheme.bubble,
              in: RoundedRectangle(cornerRadius: 22)
            )
            .frame(maxWidth: 550, alignment: message.role == .user ? .trailing : .leading)
            HStack(spacing: 12) {
              Button("Reply", action: onReply)
                .accessibilityLabel("Reply to message")
                .accessibilityIdentifier("reply-message-\(message.id)")
                .disabled(message.text.isEmpty && message.attachmentIDs.isEmpty)
              Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.text, forType: .string)
              }
              .accessibilityLabel("Copy message text")
              .accessibilityIdentifier("copy-message-\(message.id)")
              .disabled(message.text.isEmpty)
            }
            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(ShellTheme.secondary)
          }
          if message.role != .user { Spacer(minLength: 40) }
        }.frame(maxWidth: .infinity)
      }
    }
  }
}

enum AttachmentPresentation {
  static func storedCount(_ count: Int) -> String {
    "\(count) stored text attachment\(count == 1 ? "" : "s")"
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
          .background(ShellTheme.disconnectedPanel, in: RoundedRectangle(cornerRadius: 9))
          .accessibilityIdentifier("computer-disconnected")
          Text("\(store.currentBot?.name ?? "Group")'s screen")
            .font(.system(size: 13)).foregroundStyle(ShellTheme.secondary)
            .frame(maxWidth: .infinity).padding(.top, 10).padding(.bottom, 22)
          RoutineInspectorSection(store: store)
        }.padding(.horizontal, 19)
      }
      Spacer(minLength: 0)
    }
  }
}
