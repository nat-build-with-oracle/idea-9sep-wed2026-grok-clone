import SwiftUI

struct PrototypePanel: View {
  @ObservedObject var store: PreviewWorkspace
  let panel: PreviewWorkspace.Panel
  @State private var name = ""
  @State private var description = ""
  @State private var color = "green"
  @State private var shape: AvatarKind = .circle
  @State private var interval = 180
  @State private var prompt = ""
  @State private var error: String?

  private var title: String {
    switch panel {
    case .newBot: "Create a Bot"
    case .settings: "Settings"
    case .templates: "Marketplace"
    case .routine: "Add a routine"
    case .profile: "Your profile"
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack {
        Text(title).font(.system(size: 23, weight: .semibold))
        Spacer()
        ShellIconButton(symbol: "xmark", label: "Close \(title)") { store.panel = nil }
      }
      switch panel {
      case .newBot: newBotForm
      case .settings: settings
      case .templates: templates
      case .routine: routineForm
      case .profile: profileForm
      }
      if let error { Text(error).foregroundStyle(ShellTheme.warning).font(.system(size: 12)) }
    }
    .padding(26).frame(width: 440)
    .background(ShellTheme.sidebar).foregroundStyle(ShellTheme.foreground)
    .disabled(store.isSaving)
    .onAppear { if panel == .profile { name = store.name } }
  }

  private var newBotForm: some View {
    VStack(alignment: .leading, spacing: 15) {
      BotAvatar(color: color, shape: shape, size: 65).frame(maxWidth: .infinity).padding(
        .vertical, 8)
      TextField("Bot name", text: $name).textFieldStyle(.roundedBorder).accessibilityIdentifier(
        "bot-name")
      TextField("What should this Bot help with?", text: $description, axis: .vertical)
        .textFieldStyle(.roundedBorder).lineLimit(3...5)
      Picker("Shape", selection: $shape) {
        ForEach(AvatarKind.allCases) { kind in Text(kind.rawValue.capitalized).tag(kind) }
      }
      HStack(spacing: 13) {
        Text("Color").foregroundStyle(ShellTheme.secondary)
        ForEach(ShellTheme.colors, id: \.self) { option in
          Button {
            color = option
          } label: {
            Circle().fill(ShellTheme.avatarColor(option)).frame(width: 23, height: 23)
              .overlay(
                Circle().strokeBorder(
                  color == option ? ShellTheme.avatarSelectionRing : .clear, lineWidth: 2))
          }.buttonStyle(.plain).accessibilityLabel("\(option) avatar")
            .accessibilityAddTraits(color == option ? [.isSelected] : [])
        }
      }
      Text(
        store.isPersistent
          ? "This bot is saved on this Mac. Choose a provider in the composer before sending. No computer is connected."
          : "This creates a local preview bot. No provider or computer is connected."
      )
      .foregroundStyle(ShellTheme.secondary).font(.system(size: 12))
      HStack {
        Spacer()
        Button("Cancel") { store.panel = nil }.keyboardShortcut(.cancelAction)
        Button("Create Bot") {
          saveBot(name: name, description: description, color: color, shape: shape)
        }.keyboardShortcut(.defaultAction).disabled(
          name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
        .accessibilityIdentifier("create-bot")
      }
    }
  }

  private var settings: some View {
    VStack(alignment: .leading, spacing: 18) {
      Label(
        store.isPersistent ? "Local Bot Workspace" : "Native feasibility preview",
        systemImage: "macwindow"
      ).font(
        .system(size: 16, weight: .medium))
      Text(
        store.isPersistent
          ? "Your bots, groups, drafts and paused routines are saved on this Mac. AI integration and routine execution are not connected yet."
          : "A SwiftUI interface with a native AppKit text editor. This preview validates layout, input and navigation before production storage and model integration."
      )
      .foregroundStyle(ShellTheme.secondary).fixedSize(horizontal: false, vertical: true)
      Divider()
      LabeledContent("AI provider", value: "Not connected")
      LabeledContent("Computer", value: "Not connected")
      LabeledContent(
        "Storage", value: store.isPersistent ? "Local Core Data workspace" : "This session only")
      LabeledContent("Routines", value: "Not executing")
      Divider()
      Toggle("Show hidden conversations", isOn: $store.showHidden)
      Toggle("Show conversation details", isOn: $store.inspectorPreferred)
      Text(
        "Independent rewrite prototype. Not affiliated with xAI or Cursor. No credentials or private API endpoints are used."
      )
      .font(.system(size: 11)).foregroundStyle(ShellTheme.secondary)
    }
  }

  private var templates: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Start with a focused teammate").font(.system(size: 17, weight: .medium))
      Text(
        "Local templates. Installing one creates a separate Bot, not a live automation."
      )
      .foregroundStyle(ShellTheme.secondary).font(.system(size: 13))
      template(
        "Research Partner",
        description: "Find sources, compare options, and explain the tradeoffs.", color: "blue",
        shape: .circle)
      Divider()
      template(
        "Writing Partner", description: "Turn rough notes into clear drafts, in your voice.",
        color: "magenta", shape: .drop)
      Divider()
      template(
        "Project Coordinator",
        description: "Organize next steps and keep the important work visible.", color: "violet",
        shape: .square)
    }
  }

  private func template(_ title: String, description: String, color: String, shape: AvatarKind)
    -> some View
  {
    HStack(spacing: 12) {
      BotAvatar(color: color, shape: shape, size: 38)
      VStack(alignment: .leading, spacing: 4) {
        Text(title).fontWeight(.medium)
        Text(description).foregroundStyle(ShellTheme.secondary).font(.system(size: 12)).fixedSize(
          horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
      Button("Add") {
        saveBot(name: title, description: description, color: color, shape: shape)
      }.accessibilityLabel("Add \(title)")
    }
  }

  private var routineForm: some View {
    VStack(alignment: .leading, spacing: 16) {
      TextField("Routine name", text: $name).textFieldStyle(.roundedBorder)
      if store.isPersistent {
        TextField("What should the routine do?", text: $prompt, axis: .vertical)
          .textFieldStyle(.roundedBorder).lineLimit(3...5)
      }
      HStack {
        Text("Every")
        TextField("Minutes", value: $interval, format: .number).textFieldStyle(.roundedBorder)
          .frame(width: 85)
        Text("minutes").foregroundStyle(ShellTheme.secondary)
      }
      Text(
        "New routines are paused. The scheduler is not connected yet; nothing runs in the background."
      )
      .foregroundStyle(ShellTheme.secondary).font(.system(size: 13))
      HStack {
        Spacer()
        Button("Cancel") { store.panel = nil }.keyboardShortcut(.cancelAction)
        Button("Add paused routine") {
          store.isSaving = true
          Task {
            defer { store.isSaving = false }
            do {
              try await store.performAddRoutine(name: name, prompt: prompt, interval: interval)
            } catch { self.error = error.localizedDescription }
          }
        }.keyboardShortcut(.defaultAction).disabled(
          name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
  }

  private var profileForm: some View {
    VStack(alignment: .leading, spacing: 16) {
      TextField("Display name", text: $name).textFieldStyle(.roundedBorder)
      Text(
        store.isPersistent
          ? "Your display name is saved on this Mac."
          : "Your display name changes for this preview session only."
      ).font(.system(size: 12))
        .foregroundStyle(ShellTheme.secondary)
      HStack {
        Spacer()
        Button("Cancel") { store.panel = nil }.keyboardShortcut(.cancelAction)
        Button("Save") {
          let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
          guard (1...80).contains(clean.count) else {
            error = PreviewError.invalidName.localizedDescription
            return
          }
          store.saveDisplayName(clean)
          store.panel = nil
        }.keyboardShortcut(.defaultAction)
      }
    }
  }

  private func saveBot(name: String, description: String, color: String, shape: AvatarKind) {
    store.isSaving = true
    Task {
      defer { store.isSaving = false }
      do {
        try await store.performCreateBot(
          name: name, description: description, color: color, shape: shape)
      } catch { self.error = error.localizedDescription }
    }
  }
}
