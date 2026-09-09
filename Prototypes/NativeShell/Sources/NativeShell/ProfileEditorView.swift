import Combine
import SwiftUI
import WorkspaceCore

/// Let the application delegate own dirty/save/flush checks during quit, even with a sheet open.
private struct ProfileSheetWindowPolicy: NSViewRepresentable {
  func makeNSView(context: Context) -> ProfileSheetPolicyView { ProfileSheetPolicyView() }
  func updateNSView(_ nsView: ProfileSheetPolicyView, context: Context) {}
}

final class ProfileSheetPolicyView: NSView {
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    window?.preventsApplicationTerminationWhenModal = false
  }
}

enum ProfileEditTarget: Equatable, Identifiable {
  case bot(UUID)
  case group(UUID)

  var id: String {
    switch self {
    case .bot(let id): "bot-\(id.uuidString)"
    case .group(let id): "group-\(id.uuidString)"
    }
  }
}

enum ProfileEditSnapshot: Equatable {
  case bot(BotProfile)
  case group(GroupProfile)
}

@MainActor
protocol ProfileEditingWorkspace: AnyObject {
  var bots: [PreviewBot] { get }
  var profileEditorDirty: Bool { get set }
  var profileEditorSaveTask: Task<Void, Never>? { get set }
  func loadProfile(for target: ProfileEditTarget) async throws -> ProfileEditSnapshot
  func startProfileSave(
    for target: ProfileEditTarget, expected: ProfileEditSnapshot,
    replacement: ProfileEditSnapshot
  ) throws -> Task<Void, Error>
}

extension PreviewWorkspace: ProfileEditingWorkspace {}

/// Owns a detached edit buffer. It never derives identity from the workspace's current selection,
/// so navigating elsewhere while this sheet is open cannot redirect a save.
@MainActor
final class ProfileEditorController: ObservableObject {
  @Published private(set) var baseline: ProfileEditSnapshot?
  @Published private(set) var isLoading = false
  @Published private(set) var isSaving = false
  @Published private(set) var errorMessage: String?
  @Published private(set) var isDirty = false
  @Published var isConfirmingDiscard = false
  @Published var isConfirmingReload = false
  @Published private(set) var shouldDismiss = false

  @Published private(set) var name = ""
  @Published private(set) var descriptionText = ""
  @Published private(set) var color = "green"
  @Published private(set) var shape: AvatarKind = .circle
  @Published private(set) var memberIDs: [UUID] = []

  let target: ProfileEditTarget
  private let service: any ProfileEditingWorkspace
  private var operationGeneration = 0
  private var formVersion = 0
  private var task: Task<Void, Never>?
  private var removedHiddenMemberIDs: Set<UUID> = []

  convenience init(store: PreviewWorkspace, target: ProfileEditTarget) {
    self.init(service: store, target: target)
  }

  init(service: any ProfileEditingWorkspace, target: ProfileEditTarget) {
    self.service = service
    self.target = target
  }

  var title: String {
    switch target {
    case .bot: "Edit Bot"
    case .group: "Edit Group"
    }
  }

  var canSave: Bool {
    baseline != nil && isDirty && !isLoading && !isSaving && validationMessage == nil
  }

  var validationMessage: String? {
    do {
      _ = try validatedReplacement()
      if case .group = target {
        let known = Dictionary(uniqueKeysWithValues: service.bots.map { ($0.id, $0) })
        guard memberIDs.allSatisfy({ known[$0] != nil }) else {
          return "One or more bots are no longer available. Reload the latest group."
        }
        if memberIDs.contains(where: {
          known[$0]?.isHidden == true && removedHiddenMemberIDs.contains($0)
        }) {
          return "A hidden bot that was removed cannot be added again."
        }
      }
      return nil
    } catch {
      return error.localizedDescription
    }
  }

  var availableMembers: [PreviewBot] {
    service.bots.filter { !$0.isHidden && !memberIDs.contains($0.id) }
  }

  func load() -> Task<Void, Never>? {
    guard baseline == nil else { return nil }
    return performLoad()
  }

  func requestReload() -> Task<Void, Never>? {
    guard !isSaving else { return nil }
    if isDirty {
      isConfirmingReload = true
      return nil
    }
    return performLoad()
  }

  func confirmReload() -> Task<Void, Never>? {
    isConfirmingReload = false
    return performLoad()
  }

  @discardableResult
  private func performLoad() -> Task<Void, Never> {
    operationGeneration += 1
    let generation = operationGeneration
    task?.cancel()
    isLoading = true
    errorMessage = nil
    let task = Task { [weak self] in
      guard let self else { return }
      do {
        let snapshot = try await service.loadProfile(for: target)
        guard !Task.isCancelled, generation == operationGeneration else { return }
        apply(snapshot)
        isLoading = false
      } catch is CancellationError {
        guard generation == operationGeneration else { return }
        isLoading = false
      } catch {
        guard !Task.isCancelled, generation == operationGeneration else { return }
        errorMessage = error.localizedDescription
        isLoading = false
      }
    }
    self.task = task
    return task
  }

  func setName(_ value: String) {
    name = value
    formChanged()
  }

  func setDescription(_ value: String) {
    descriptionText = value
    formChanged()
  }

  func setColor(_ value: String) {
    color = value
    formChanged()
  }

  func setShape(_ value: AvatarKind) {
    shape = value
    formChanged()
  }

  func removeMember(_ id: UUID) {
    guard let index = memberIDs.firstIndex(of: id) else { return }
    if service.bots.first(where: { $0.id == id })?.isHidden == true {
      removedHiddenMemberIDs.insert(id)
    }
    memberIDs.remove(at: index)
    formChanged()
  }

  func addMember(_ id: UUID) {
    guard memberIDs.count < 6, !memberIDs.contains(id),
      let bot = service.bots.first(where: { $0.id == id }), !bot.isHidden
    else { return }
    memberIDs.append(id)
    formChanged()
  }

  func moveMember(from offsets: IndexSet, to destination: Int) {
    memberIDs.move(fromOffsets: offsets, toOffset: destination)
    formChanged()
  }

  func save() -> Task<Void, Never>? {
    guard let expected = baseline, canSave, !shouldDismiss else { return nil }
    let submitted: ProfileEditSnapshot
    do {
      submitted = try validatedReplacement()
      if let validationMessage { throw ProfileEditorError.invalid(validationMessage) }
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }

    let saving: Task<Void, Error>
    do {
      saving = try service.startProfileSave(
        for: target, expected: expected, replacement: submitted)
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
    operationGeneration += 1
    let generation = operationGeneration
    let submittedVersion = formVersion
    isSaving = true
    errorMessage = nil
    let task = Task { [weak self] in
      guard let self else { return }
      do {
        try await saving.value
        guard !Task.isCancelled, generation == operationGeneration else { return }
        if submittedVersion == formVersion {
          apply(submitted)
          shouldDismiss = true
        } else {
          baseline = submitted
          updateDirty()
          errorMessage = "Saved. Newer edits remain in this form."
        }
      } catch is CancellationError {
      } catch {
        guard !Task.isCancelled, generation == operationGeneration else { return }
        errorMessage = error.localizedDescription
      }
      guard generation == operationGeneration else { return }
      isSaving = false
    }
    self.task = task
    service.profileEditorSaveTask = task
    return task
  }

  func requestCancel() {
    guard !isSaving else { return }
    if isDirty {
      isConfirmingDiscard = true
    } else {
      invalidatePendingLoad()
      shouldDismiss = true
    }
  }

  func confirmDiscard() {
    isConfirmingDiscard = false
    invalidatePendingLoad()
    shouldDismiss = true
  }

  func disappear() {
    if !isSaving { invalidatePendingLoad() }
    service.profileEditorDirty = false
  }

  private func apply(_ snapshot: ProfileEditSnapshot) {
    baseline = snapshot
    removedHiddenMemberIDs = []
    switch snapshot {
    case .bot(let profile):
      name = profile.name
      descriptionText = profile.description
      color = profile.color
      shape = AvatarKind(rawValue: profile.shape.rawValue) ?? .circle
      memberIDs = []
    case .group(let profile):
      name = profile.title
      descriptionText = ""
      color = "green"
      shape = .circle
      memberIDs = profile.memberBotIDs
    }
    formVersion += 1
    updateDirty()
  }

  private func formChanged() {
    formVersion += 1
    errorMessage = nil
    updateDirty()
  }

  private func invalidatePendingLoad() {
    operationGeneration += 1
    task?.cancel()
    if isLoading { isLoading = false }
  }

  private func updateDirty() {
    guard let baseline else {
      isDirty = false
      service.profileEditorDirty = false
      return
    }
    isDirty = replacement() != baseline
    service.profileEditorDirty = isDirty
  }

  private func replacement() -> ProfileEditSnapshot {
    switch target {
    case .bot:
      return .bot(
        BotProfile(
          name: name, description: descriptionText, color: color,
          shape: AvatarShape(rawValue: shape.rawValue) ?? .circle))
    case .group:
      return .group(GroupProfile(title: name, memberBotIDs: memberIDs))
    }
  }

  private func validatedReplacement() throws -> ProfileEditSnapshot {
    switch replacement() {
    case .bot(let profile): return .bot(try profile.validated())
    case .group(let profile): return .group(try profile.validated())
    }
  }
}

private enum ProfileEditorError: LocalizedError {
  case invalid(String)
  var errorDescription: String? {
    switch self {
    case .invalid(let message): message
    }
  }
}

struct ProfileEditorView: View {
  @ObservedObject private var store: PreviewWorkspace
  @StateObject private var controller: ProfileEditorController
  @Environment(\.dismiss) private var dismiss
  @FocusState private var firstFieldFocused: Bool

  init(store: PreviewWorkspace, target: ProfileEditTarget) {
    self.store = store
    _controller = StateObject(
      wrappedValue: ProfileEditorController(store: store, target: target))
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        HStack {
          Text(controller.title).font(.system(size: 24, weight: .semibold))
            .accessibilityAddTraits(.isHeader)
          Spacer()
          Button {
            controller.requestCancel()
          } label: {
            Image(systemName: "xmark.circle.fill")
          }
          .buttonStyle(.plain).foregroundStyle(ShellTheme.secondary)
          .disabled(controller.isSaving || store.isClosing)
          .accessibilityLabel("Close profile editor")
          .accessibilityIdentifier("profile-close")
        }
        if controller.isLoading && controller.baseline == nil {
          ProgressView("Loading profile…")
            .frame(maxWidth: .infinity, minHeight: 260)
        } else if controller.baseline != nil {
          switch controller.target {
          case .bot: botForm
          case .group: groupForm
          }
        }
        if let validation = controller.validationMessage, controller.baseline != nil {
          Label(validation, systemImage: "exclamationmark.triangle.fill")
            .font(.caption).foregroundStyle(ShellTheme.warning)
            .accessibilityIdentifier("profile-validation-error")
        }
        if let error = controller.errorMessage {
          VStack(alignment: .leading, spacing: 8) {
            Text(error).foregroundStyle(ShellTheme.warning)
              .accessibilityIdentifier("profile-save-error")
            Button("Reload latest") { _ = controller.requestReload() }
              .accessibilityIdentifier("profile-reload-latest")
          }
        }
        Text(
          "Existing messages keep their recorded speaker names. Group membership changes apply only to future replies; queued replies are not rewritten."
        )
        .font(.caption).foregroundStyle(ShellTheme.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .frame(minWidth: 480, idealWidth: 520, maxWidth: 600, minHeight: 420, idealHeight: 500)
    .background(ShellTheme.background)
    .background(ProfileSheetWindowPolicy())
    .foregroundStyle(ShellTheme.foreground)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      VStack(spacing: 0) {
        Divider()
        HStack {
          if controller.isSaving { ProgressView().controlSize(.small) }
          Spacer()
          Button("Cancel") { controller.requestCancel() }
            .keyboardShortcut(.cancelAction)
            .disabled(controller.isSaving || store.isClosing)
            .accessibilityIdentifier("profile-cancel")
          Button("Save") { _ = controller.save() }
            .keyboardShortcut(.defaultAction)
            .disabled(!controller.canSave)
            .accessibilityIdentifier("profile-save")
        }.padding(.horizontal, 24).padding(.vertical, 14)
      }.background(ShellTheme.sidebar)
    }
    .interactiveDismissDisabled(true)
    .onAppear { _ = controller.load() }
    .onChange(of: controller.baseline) { _, value in
      if value != nil { firstFieldFocused = true }
    }
    .onChange(of: controller.shouldDismiss) { _, value in
      guard value else { return }
      store.profileEditorDirty = false
      store.composerFocusRequest += 1
      dismiss()
    }
    .onDisappear { controller.disappear() }
    .onExitCommand { controller.requestCancel() }
    .alert("Discard unsaved profile changes?", isPresented: $controller.isConfirmingDiscard) {
      Button("Keep Editing", role: .cancel) {}
      Button("Discard Changes", role: .destructive) { controller.confirmDiscard() }
    } message: {
      Text("Your unsaved profile changes will be lost.")
    }
    .alert("Reload the latest profile?", isPresented: $controller.isConfirmingReload) {
      Button("Keep Editing", role: .cancel) {}
      Button("Reload", role: .destructive) { _ = controller.confirmReload() }
    } message: {
      Text("Reloading discards the edits in this form.")
    }
  }

  private var botForm: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 18) {
        BotAvatar(color: controller.color, shape: controller.shape, size: 68)
        VStack(alignment: .leading, spacing: 4) {
          Text("Avatar preview").font(.headline)
          Text("Choose an original shape and color for this bot.")
            .font(.caption).foregroundStyle(ShellTheme.secondary)
        }
      }
      field("Name", text: nameBinding, identifier: "profile-bot-name")
        .focused($firstFieldFocused)
      VStack(alignment: .leading, spacing: 6) {
        Text("Description")
        TextEditor(text: descriptionBinding)
          .font(.body).scrollContentBackground(.hidden).frame(minHeight: 100, maxHeight: 170)
          .padding(7).background(ShellTheme.bubble, in: RoundedRectangle(cornerRadius: 8))
          .accessibilityIdentifier("profile-bot-description")
        Text("\(controller.descriptionText.count) / 8,000 characters")
          .font(.caption2).foregroundStyle(ShellTheme.secondary)
      }
      VStack(alignment: .leading, spacing: 8) {
        Text("Color")
        HStack(spacing: 10) {
          ForEach(ShellTheme.colors, id: \.self) { color in
            Button {
              controller.setColor(color)
            } label: {
              Circle().fill(ShellTheme.avatarColor(color)).frame(width: 28, height: 28)
                .overlay {
                  if controller.color == color {
                    Image(systemName: "checkmark").font(.caption.bold())
                      .foregroundStyle(ShellTheme.avatarSelectionRing)
                  }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(color.capitalized) avatar color")
            .accessibilityAddTraits(controller.color == color ? .isSelected : [])
            .accessibilityIdentifier("profile-color-\(color)")
          }
        }
      }
      Picker("Shape", selection: shapeBinding) {
        ForEach(AvatarKind.allCases) { shape in
          Text(shape.rawValue.capitalized).tag(shape)
        }
      }
      .accessibilityIdentifier("profile-bot-shape")
    }.disabled(controller.isLoading || controller.isSaving || store.isClosing)
  }

  private var groupForm: some View {
    VStack(alignment: .leading, spacing: 16) {
      field("Group name", text: nameBinding, identifier: "profile-group-name")
        .focused($firstFieldFocused)
      HStack {
        Text("Members").font(.headline)
        Spacer()
        Menu("Add member") {
          if controller.availableMembers.isEmpty {
            Text("No available bots")
          } else {
            ForEach(controller.availableMembers) { bot in
              Button(bot.name) { controller.addMember(bot.id) }
            }
          }
        }
        .disabled(controller.memberIDs.count >= 6 || controller.availableMembers.isEmpty)
        .accessibilityIdentifier("profile-add-member")
      }
      VStack(spacing: 6) {
        ForEach(Array(controller.memberIDs.enumerated()), id: \.element) { index, id in
          let bot = store.bots.first(where: { $0.id == id })
          HStack(spacing: 10) {
            BotAvatar(color: bot?.color ?? "gray", shape: bot?.shape ?? .circle, size: 32)
            Text(bot?.name ?? "Unavailable bot").lineLimit(1)
            if bot?.isHidden == true {
              Text("Hidden").font(.caption2).padding(.horizontal, 7).padding(.vertical, 3)
                .background(ShellTheme.selected, in: Capsule())
            }
            Spacer()
            VStack(spacing: 2) {
              Button {
                controller.moveMember(from: IndexSet(integer: index), to: index - 1)
              } label: {
                Image(systemName: "chevron.up")
              }
              .buttonStyle(.plain).disabled(index == 0)
              .accessibilityLabel("Move \(bot?.name ?? "unavailable bot") up")
              .accessibilityIdentifier("profile-move-member-up-\(index)")
              Button {
                controller.moveMember(from: IndexSet(integer: index), to: index + 2)
              } label: {
                Image(systemName: "chevron.down")
              }
              .buttonStyle(.plain).disabled(index == controller.memberIDs.count - 1)
              .accessibilityLabel("Move \(bot?.name ?? "unavailable bot") down")
              .accessibilityIdentifier("profile-move-member-down-\(index)")
            }
            Button {
              controller.removeMember(id)
            } label: {
              Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(bot?.name ?? "unavailable bot")")
            .accessibilityIdentifier("profile-remove-member-\(index)")
          }
          .padding(9).background(ShellTheme.bubble, in: RoundedRectangle(cornerRadius: 9))
          .accessibilityElement(children: .contain)
        }
      }
      .accessibilityIdentifier("profile-group-members")
      Text(
        "Keep 2–6 different bots. Hidden bots already in this group may be retained, but cannot be newly added."
      )
      .font(.caption).foregroundStyle(ShellTheme.secondary)
    }.disabled(controller.isLoading || controller.isSaving || store.isClosing)
  }

  private func field(_ label: String, text: Binding<String>, identifier: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(label)
      TextField(label, text: text).textFieldStyle(.roundedBorder)
        .accessibilityIdentifier(identifier)
    }
  }

  private var nameBinding: Binding<String> {
    Binding(get: { controller.name }, set: { controller.setName($0) })
  }

  private var descriptionBinding: Binding<String> {
    Binding(get: { controller.descriptionText }, set: { controller.setDescription($0) })
  }

  private var shapeBinding: Binding<AvatarKind> {
    Binding(get: { controller.shape }, set: { controller.setShape($0) })
  }
}
