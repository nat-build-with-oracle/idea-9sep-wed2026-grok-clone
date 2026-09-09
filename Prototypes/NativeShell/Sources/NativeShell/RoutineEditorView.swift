import Combine
import SwiftUI
import WorkspaceCore

struct RoutineEditTarget: Equatable, Identifiable {
  let id: UUID
  let routineID: UUID?
  let allowedOwnerIDs: [UUID]
  let preferredOwnerID: UUID?

  init(
    id: UUID = UUID(), routineID: UUID? = nil, allowedOwnerIDs: [UUID] = [],
    preferredOwnerID: UUID? = nil
  ) {
    self.id = id
    self.routineID = routineID
    self.allowedOwnerIDs = allowedOwnerIDs
    self.preferredOwnerID = preferredOwnerID
  }
}

@MainActor
protocol RoutineEditingWorkspace: AnyObject {
  var bots: [PreviewBot] { get }
  var providers: [ProviderConfig] { get }
  var routineEditorDirty: Bool { get set }
  var routineEditorSaveTask: Task<Void, Never>? { get set }
  func loadRoutineForEditing(id: UUID) async throws -> Routine
  func startRoutineSave(
    expected: Routine?, replacement: Routine, authorizedTransmission: Bool
  ) throws -> Task<Void, Error>
}

extension PreviewWorkspace: RoutineEditingWorkspace {}

@MainActor
final class RoutineEditorController: ObservableObject {
  enum TriggerKind: String, CaseIterable, Identifiable {
    case interval, daily
    var id: String { rawValue }
  }

  @Published private(set) var baseline: Routine?
  @Published private(set) var hasLoaded = false
  @Published private(set) var isLoading = false
  @Published private(set) var isSaving = false
  @Published private(set) var errorMessage: String?
  @Published private(set) var isDirty = false
  @Published var isConfirmingDiscard = false
  @Published var isConfirmingReload = false
  @Published private(set) var shouldDismiss = false

  @Published private(set) var ownerID: UUID?
  @Published private(set) var name = ""
  @Published private(set) var prompt = ""
  @Published private(set) var triggerKind = TriggerKind.interval
  @Published private(set) var intervalMinutes = 60
  @Published private(set) var dailyHour = 9
  @Published private(set) var dailyMinute = 0
  @Published private(set) var timezoneID = TimeZone.current.identifier
  @Published private(set) var enabled = false
  @Published private(set) var providerID: UUID?
  @Published private(set) var authorizedTransmission = false

  let target: RoutineEditTarget
  private let service: any RoutineEditingWorkspace
  private let now: @MainActor @Sendable () -> Date
  private var initialForm: FormState?
  private var operationGeneration = 0
  private var formVersion = 0
  private var task: Task<Void, Never>?
  private var authorizedDisclosure: TransmissionDisclosure?
  private var observedProviderBinding: RoutineProviderBinding?

  convenience init(store: PreviewWorkspace, target: RoutineEditTarget) {
    self.init(service: store, target: target)
  }

  init(
    service: any RoutineEditingWorkspace, target: RoutineEditTarget,
    now: @escaping @MainActor @Sendable () -> Date = Date.init
  ) {
    self.service = service
    self.target = target
    self.now = now
  }

  var title: String { target.routineID == nil ? "New Routine" : "Edit Routine" }

  var availableOwners: [PreviewBot] {
    if let baseline {
      return service.bots.filter { $0.id == baseline.ownerBotID }
    }
    let allowed = Set(target.allowedOwnerIDs)
    return service.bots.filter { !$0.isHidden && allowed.contains($0.id) }
  }

  var availableProviders: [ProviderConfig] {
    service.providers.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  var selectedProvider: ProviderConfig? {
    providerID.flatMap { id in service.providers.first { $0.id == id } }
  }

  var transmissionDisclosureTitle: String {
    enabled ? "Automatic transmission disclosure" : "Paused destination approval"
  }

  var transmissionAuthorizationLabel: String {
    enabled
      ? "I authorize these automatic transmissions"
      : "I approve this prompt and destination binding"
  }

  var transmissionDisclosureText: String {
    let destination =
      selectedProvider?.apiRoot.absoluteString ?? "the selected provider destination"
    let model = selectedProvider?.modelID ?? "the selected model"
    let payload =
      "A run sends this prompt and up to 100 recent messages from the owner's direct conversation to \(destination), model \(model). Provider charges may apply."
    if enabled {
      return
        "\(payload) Automatic runs occur only while this app is open and the Mac is awake; they never run while the app is closed."
    }
    return
      "Saving this paused routine sends nothing. You are approving its prompt and destination binding; Run Now and enabling automatic runs require separate confirmation. \(payload)"
  }

  var requiresTransmissionAuthorization: Bool {
    guard hasLoaded else { return false }
    if enabled { return true }
    guard providerID != nil || baseline?.providerBinding != nil else { return false }
    let currentBinding = selectedProvider.map(RoutineProviderBinding.init)
    return prompt != baseline?.prompt || currentBinding != baseline?.providerBinding
      || ownerID != baseline?.ownerBotID
  }

  var canSave: Bool {
    hasLoaded && isDirty && !isLoading && !isSaving && validationMessage == nil
      && (!requiresTransmissionAuthorization || hasCurrentAuthorization)
  }

  private var hasCurrentAuthorization: Bool {
    authorizedTransmission && authorizedDisclosure == TransmissionDisclosure(self)
  }

  var validationMessage: String? {
    guard hasLoaded else { return nil }
    let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (1...80).contains(cleanName.count) else {
      return WorkspaceError.invalidName.localizedDescription
    }
    let cleanPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanPrompt.isEmpty, prompt.count <= 32_000 else {
      return WorkspaceError.invalidRoutine.localizedDescription
    }
    guard let ownerID else { return "Choose the bot that owns this routine." }
    if let baseline, baseline.ownerBotID != ownerID {
      return "The owner of an existing routine cannot be changed."
    }
    if target.routineID == nil {
      guard target.allowedOwnerIDs.contains(ownerID),
        availableOwners.contains(where: { $0.id == ownerID })
      else { return "Choose an available owner for this routine." }
    }
    switch triggerKind {
    case .interval:
      guard (5...525_600).contains(intervalMinutes) else {
        return WorkspaceError.invalidRoutine.localizedDescription
      }
    case .daily:
      guard (0...23).contains(dailyHour), (0...59).contains(dailyMinute) else {
        return WorkspaceError.invalidRoutine.localizedDescription
      }
    }
    guard timezoneID == "UTC" || TimeZone.knownTimeZoneIdentifiers.contains(timezoneID) else {
      return "Choose a named IANA time zone."
    }
    if let providerID, !service.providers.contains(where: { $0.id == providerID }) {
      return "The selected provider is no longer available."
    }
    if enabled && providerID == nil {
      return "Choose a provider before enabling automatic transmission."
    }
    return nil
  }

  func load() -> Task<Void, Never>? {
    guard !hasLoaded, !isLoading else { return nil }
    if target.routineID == nil {
      applyNew()
      return nil
    }
    return performLoad()
  }

  func requestReload() -> Task<Void, Never>? {
    guard !isSaving, target.routineID != nil else { return nil }
    if isDirty {
      isConfirmingReload = true
      return nil
    }
    return performLoad()
  }

  func confirmReload() -> Task<Void, Never>? {
    isConfirmingReload = false
    guard target.routineID != nil else { return nil }
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
      guard let self, let id = target.routineID else { return }
      do {
        let routine = try await service.loadRoutineForEditing(id: id)
        guard !Task.isCancelled, generation == operationGeneration else { return }
        apply(routine)
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

  func setOwnerID(_ value: UUID?) {
    guard baseline == nil else { return }
    ownerID = value
    formChanged()
  }
  func setName(_ value: String) {
    name = value
    formChanged()
  }
  func setPrompt(_ value: String) {
    prompt = value
    formChanged()
  }
  func setTriggerKind(_ value: TriggerKind) {
    triggerKind = value
    formChanged()
  }
  func setIntervalMinutes(_ value: Int) {
    intervalMinutes = value
    formChanged()
  }
  func setDailyHour(_ value: Int) {
    dailyHour = value
    formChanged()
  }
  func setDailyMinute(_ value: Int) {
    dailyMinute = value
    formChanged()
  }
  func setTimezoneID(_ value: String) {
    timezoneID = value
    formChanged()
  }
  func setEnabled(_ value: Bool) {
    enabled = value
    formChanged()
  }
  func setProviderID(_ value: UUID?) {
    providerID = value
    observedProviderBinding = selectedProvider.map(RoutineProviderBinding.init)
    formChanged()
  }

  func setAuthorizedTransmission(_ value: Bool) {
    authorizedTransmission = value
    authorizedDisclosure = value ? TransmissionDisclosure(self) : nil
    errorMessage = nil
  }

  func providersChanged() {
    let binding = selectedProvider.map(RoutineProviderBinding.init)
    guard binding != observedProviderBinding else { return }
    observedProviderBinding = binding
    formVersion += 1
    authorizedTransmission = false
    authorizedDisclosure = nil
    errorMessage = nil
    updateDirty()
  }

  func save() -> Task<Void, Never>? {
    guard canSave, !shouldDismiss else { return nil }
    let replacement: Routine
    do {
      replacement = try makeReplacement()
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
    let submittedForm = FormState(self)
    let saving: Task<Void, Error>
    do {
      saving = try service.startRoutineSave(
        expected: baseline, replacement: replacement,
        authorizedTransmission: hasCurrentAuthorization)
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
          apply(replacement)
          if isDirty {
            errorMessage = "Saved. The selected provider changed; review and save again."
          } else {
            shouldDismiss = true
          }
        } else {
          baseline = replacement
          initialForm = submittedForm
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
    service.routineEditorSaveTask = task
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
    service.routineEditorDirty = false
  }

  private func applyNew() {
    baseline = nil
    ownerID = target.preferredOwnerID.flatMap { preferred in
      target.allowedOwnerIDs.contains(preferred) ? preferred : nil
    }
    name = ""
    prompt = ""
    triggerKind = .interval
    intervalMinutes = 60
    dailyHour = 9
    dailyMinute = 0
    timezoneID = TimeZone.current.identifier
    enabled = false
    providerID = nil
    observedProviderBinding = nil
    authorizedTransmission = false
    authorizedDisclosure = nil
    hasLoaded = true
    initialForm = FormState(self, providerBinding: nil)
    updateDirty()
  }

  private func apply(_ routine: Routine) {
    baseline = routine
    ownerID = routine.ownerBotID
    name = routine.name
    prompt = routine.prompt
    switch routine.trigger {
    case .interval(let minutes):
      triggerKind = .interval
      intervalMinutes = minutes
    case .daily(let hour, let minute):
      triggerKind = .daily
      dailyHour = hour
      dailyMinute = minute
    }
    timezoneID = routine.timezoneID
    enabled = routine.enabled
    providerID = routine.providerBinding?.providerID
    observedProviderBinding = selectedProvider.map(RoutineProviderBinding.init)
    authorizedTransmission = false
    authorizedDisclosure = nil
    hasLoaded = true
    formVersion += 1
    initialForm = FormState(self, providerBinding: routine.providerBinding)
    updateDirty()
  }

  private func formChanged() {
    formVersion += 1
    authorizedTransmission = false
    authorizedDisclosure = nil
    errorMessage = nil
    updateDirty()
  }

  private func updateDirty() {
    isDirty = hasLoaded && FormState(self) != initialForm
    service.routineEditorDirty = isDirty
  }

  private func invalidatePendingLoad() {
    operationGeneration += 1
    task?.cancel()
    if isLoading { isLoading = false }
  }

  private func trigger() -> Routine.Trigger {
    switch triggerKind {
    case .interval: .interval(minutes: intervalMinutes)
    case .daily: .daily(hour: dailyHour, minute: dailyMinute)
    }
  }

  private func makeReplacement() throws -> Routine {
    if let validationMessage { throw RoutineEditorError.invalid(validationMessage) }
    if requiresTransmissionAuthorization && !hasCurrentAuthorization {
      throw RoutineEditorError.invalid("Authorize the disclosed transmission before saving.")
    }
    let ownerID = try ownerID ?? { throw RoutineEditorError.invalid("Choose an owner.") }()
    let trigger = trigger()
    let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let binding = selectedProvider.map(RoutineProviderBinding.init)
    let scheduleChanged =
      baseline.map {
        $0.trigger != trigger || $0.timezoneID != timezoneID
      } ?? false
    let resumed = baseline.map { !$0.enabled && enabled } ?? enabled
    let scheduleID: UUID?
    let nextRunAt: Date?
    if enabled {
      if let baseline, !scheduleChanged, !resumed {
        scheduleID = baseline.scheduleID
        nextRunAt = baseline.nextRunAt
      } else {
        scheduleID = UUID()
        nextRunAt = try RoutineSchedule.next(
          after: now(), trigger: trigger, timezoneID: timezoneID)
      }
    } else {
      scheduleID = scheduleChanged ? UUID() : baseline?.scheduleID
      nextRunAt = nil
    }
    return Routine(
      id: baseline?.id ?? target.routineID ?? target.id, ownerBotID: ownerID, name: cleanName,
      prompt: prompt, trigger: trigger, timezoneID: timezoneID, enabled: enabled,
      nextRunAt: nextRunAt, providerBinding: binding, scheduleID: scheduleID)
  }

  private struct FormState: Equatable {
    let ownerID: UUID?
    let name: String
    let prompt: String
    let triggerKind: TriggerKind
    let intervalMinutes: Int
    let dailyHour: Int
    let dailyMinute: Int
    let timezoneID: String
    let enabled: Bool
    let providerBinding: RoutineProviderBinding?

    @MainActor init(_ controller: RoutineEditorController) {
      self.init(
        controller,
        providerBinding: controller.selectedProvider.map(RoutineProviderBinding.init))
    }

    @MainActor init(
      _ controller: RoutineEditorController, providerBinding: RoutineProviderBinding?
    ) {
      ownerID = controller.ownerID
      name = controller.name
      prompt = controller.prompt
      triggerKind = controller.triggerKind
      intervalMinutes = controller.intervalMinutes
      dailyHour = controller.dailyHour
      dailyMinute = controller.dailyMinute
      timezoneID = controller.timezoneID
      enabled = controller.enabled
      self.providerBinding = providerBinding
    }

  }

  private struct TransmissionDisclosure: Equatable {
    let ownerID: UUID?
    let prompt: String
    let binding: RoutineProviderBinding?

    @MainActor init(_ controller: RoutineEditorController) {
      ownerID = controller.ownerID
      prompt = controller.prompt
      binding = controller.selectedProvider.map(RoutineProviderBinding.init)
    }
  }
}

private enum RoutineEditorError: LocalizedError {
  case invalid(String)
  var errorDescription: String? {
    switch self {
    case .invalid(let message): message
    }
  }
}

private struct RoutineSheetWindowPolicy: NSViewRepresentable {
  func makeNSView(context: Context) -> RoutineSheetPolicyView { RoutineSheetPolicyView() }
  func updateNSView(_ nsView: RoutineSheetPolicyView, context: Context) {}
}

final class RoutineSheetPolicyView: NSView {
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    window?.preventsApplicationTerminationWhenModal = false
  }
}

struct RoutineEditorView: View {
  @ObservedObject private var store: PreviewWorkspace
  @StateObject private var controller: RoutineEditorController
  @Environment(\.dismiss) private var dismiss
  @FocusState private var nameFocused: Bool

  init(store: PreviewWorkspace, target: RoutineEditTarget) {
    self.store = store
    _controller = StateObject(
      wrappedValue: RoutineEditorController(store: store, target: target))
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        header
        if controller.isLoading && !controller.hasLoaded {
          ProgressView("Loading routine…").frame(maxWidth: .infinity, minHeight: 300)
        } else if controller.hasLoaded {
          form
        }
        if let validation = controller.validationMessage {
          Label(validation, systemImage: "exclamationmark.triangle.fill")
            .font(.caption).foregroundStyle(ShellTheme.warning)
            .accessibilityIdentifier("routine-validation-error")
        }
        if let error = controller.errorMessage {
          VStack(alignment: .leading, spacing: 8) {
            Text(error).foregroundStyle(ShellTheme.warning)
              .accessibilityIdentifier("routine-save-error")
            if controller.target.routineID != nil {
              Button("Reload latest") { _ = controller.requestReload() }
                .accessibilityIdentifier("routine-reload-latest")
            }
          }
        }
      }
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .frame(minWidth: 480, idealWidth: 540, maxWidth: 600, minHeight: 480, idealHeight: 640)
    .background(ShellTheme.background)
    .background(RoutineSheetWindowPolicy())
    .foregroundStyle(ShellTheme.foreground)
    .safeAreaInset(edge: .bottom, spacing: 0) { footer }
    .interactiveDismissDisabled(true)
    .onAppear { _ = controller.load() }
    .onChange(of: controller.hasLoaded) { _, loaded in if loaded { nameFocused = true } }
    .onChange(of: store.providers) { _, _ in controller.providersChanged() }
    .onChange(of: controller.shouldDismiss) { _, value in
      guard value else { return }
      store.routineEditorDirty = false
      store.routineEditTarget = nil
      store.composerFocusRequest += 1
      dismiss()
    }
    .onDisappear { controller.disappear() }
    .onExitCommand { controller.requestCancel() }
    .alert("Discard unsaved routine changes?", isPresented: $controller.isConfirmingDiscard) {
      Button("Keep Editing", role: .cancel) {}
      Button("Discard Changes", role: .destructive) { controller.confirmDiscard() }
    } message: {
      Text("Your unsaved routine changes will be lost.")
    }
    .alert("Reload the latest routine?", isPresented: $controller.isConfirmingReload) {
      Button("Keep Editing", role: .cancel) {}
      Button("Reload", role: .destructive) { _ = controller.confirmReload() }
    } message: {
      Text("Reloading discards the edits in this form.")
    }
  }

  private var header: some View {
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
      .accessibilityLabel("Close routine editor")
      .accessibilityIdentifier("routine-close")
    }
  }

  private var form: some View {
    VStack(alignment: .leading, spacing: 16) {
      field("Name", text: nameBinding, identifier: "routine-name").focused($nameFocused)
      VStack(alignment: .leading, spacing: 6) {
        Text("Prompt")
        TextEditor(text: promptBinding)
          .font(.body).scrollContentBackground(.hidden).frame(minHeight: 110, maxHeight: 220)
          .padding(7).background(ShellTheme.bubble, in: RoundedRectangle(cornerRadius: 8))
          .accessibilityIdentifier("routine-prompt")
        Text("\(controller.prompt.count) / 32,000 characters")
          .font(.caption2).foregroundStyle(ShellTheme.secondary)
      }
      Picker("Owner", selection: ownerBinding) {
        Text("Choose a bot").tag(UUID?.none)
        ForEach(controller.availableOwners) { bot in Text(bot.name).tag(UUID?.some(bot.id)) }
      }
      .disabled(controller.baseline != nil)
      .accessibilityIdentifier("routine-owner")
      Picker("Schedule", selection: triggerBinding) {
        Text("Interval").tag(RoutineEditorController.TriggerKind.interval)
        Text("Daily").tag(RoutineEditorController.TriggerKind.daily)
      }
      .pickerStyle(.segmented).accessibilityIdentifier("routine-trigger")
      if controller.triggerKind == .interval {
        HStack(alignment: .firstTextBaseline) {
          TextField("Minutes", value: intervalBinding, format: .number)
            .textFieldStyle(.roundedBorder).frame(width: 120)
            .accessibilityLabel("Interval in minutes")
            .accessibilityIdentifier("routine-interval-minutes")
          Text("minutes")
          Stepper("", value: intervalBinding, in: 5...525_600)
            .labelsHidden().accessibilityLabel("Adjust interval minutes")
            .accessibilityIdentifier("routine-interval-stepper")
        }
      } else {
        HStack {
          Picker("Hour", selection: hourBinding) {
            ForEach(0..<24, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
          }
          Picker("Minute", selection: minuteBinding) {
            ForEach(0..<60, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
          }
        }.accessibilityIdentifier("routine-daily-time")
      }
      Picker("Time zone", selection: timezoneBinding) {
        ForEach(timeZoneIDs, id: \.self) { Text($0).tag($0) }
      }.accessibilityIdentifier("routine-timezone")
      Picker("Provider", selection: providerBinding) {
        Text("No provider (paused only)").tag(UUID?.none)
        ForEach(controller.availableProviders) { provider in
          Text("\(provider.name) — \(provider.modelID)").tag(UUID?.some(provider.id))
        }
      }.accessibilityIdentifier("routine-provider")
      Toggle("Enable automatic runs", isOn: enabledBinding)
        .toggleStyle(.checkbox).accessibilityIdentifier("routine-enabled")
      if controller.requiresTransmissionAuthorization {
        disclosure
        Toggle(controller.transmissionAuthorizationLabel, isOn: authorizationBinding)
          .toggleStyle(.checkbox).accessibilityIdentifier("routine-authorize-transmission")
      }
    }.disabled(controller.isLoading || controller.isSaving || store.isClosing)
  }

  private var disclosure: some View {
    return VStack(alignment: .leading, spacing: 6) {
      Label(controller.transmissionDisclosureTitle, systemImage: "network")
        .font(.headline)
      Text(controller.transmissionDisclosureText)
        .font(.caption).foregroundStyle(ShellTheme.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(12).background(ShellTheme.bubble, in: RoundedRectangle(cornerRadius: 10))
    .accessibilityIdentifier("routine-transmission-disclosure")
  }

  private var footer: some View {
    VStack(spacing: 0) {
      Divider()
      HStack {
        if controller.isSaving { ProgressView().controlSize(.small) }
        Spacer()
        Button("Cancel") { controller.requestCancel() }
          .keyboardShortcut(.cancelAction).disabled(controller.isSaving || store.isClosing)
          .accessibilityIdentifier("routine-cancel")
        Button("Save") { _ = controller.save() }
          .keyboardShortcut(.defaultAction).disabled(!controller.canSave)
          .accessibilityIdentifier("routine-save")
      }.padding(.horizontal, 24).padding(.vertical, 14)
    }.background(ShellTheme.sidebar)
  }

  private func field(_ label: String, text: Binding<String>, identifier: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(label)
      TextField(label, text: text).textFieldStyle(.roundedBorder)
        .accessibilityIdentifier(identifier)
    }
  }

  private var ownerBinding: Binding<UUID?> {
    Binding(get: { controller.ownerID }, set: { controller.setOwnerID($0) })
  }
  private var nameBinding: Binding<String> {
    Binding(get: { controller.name }, set: { controller.setName($0) })
  }
  private var promptBinding: Binding<String> {
    Binding(get: { controller.prompt }, set: { controller.setPrompt($0) })
  }
  private var triggerBinding: Binding<RoutineEditorController.TriggerKind> {
    Binding(get: { controller.triggerKind }, set: { controller.setTriggerKind($0) })
  }
  private var intervalBinding: Binding<Int> {
    Binding(get: { controller.intervalMinutes }, set: { controller.setIntervalMinutes($0) })
  }
  private var hourBinding: Binding<Int> {
    Binding(get: { controller.dailyHour }, set: { controller.setDailyHour($0) })
  }
  private var minuteBinding: Binding<Int> {
    Binding(get: { controller.dailyMinute }, set: { controller.setDailyMinute($0) })
  }
  private var timezoneBinding: Binding<String> {
    Binding(get: { controller.timezoneID }, set: { controller.setTimezoneID($0) })
  }
  private var providerBinding: Binding<UUID?> {
    Binding(get: { controller.providerID }, set: { controller.setProviderID($0) })
  }
  private var enabledBinding: Binding<Bool> {
    Binding(get: { controller.enabled }, set: { controller.setEnabled($0) })
  }
  private var authorizationBinding: Binding<Bool> {
    Binding(
      get: { controller.authorizedTransmission },
      set: { controller.setAuthorizedTransmission($0) })
  }

  private var timeZoneIDs: [String] {
    ["UTC"] + TimeZone.knownTimeZoneIdentifiers.filter { $0 != "UTC" }
  }
}
