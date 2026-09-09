import SwiftUI
import WorkspaceCore

/// Edits provider metadata while keeping credentials inside the workspace's credential service.
/// This view never reads a saved credential back into SwiftUI state.
struct ProviderSettingsView: View {
  private struct FieldValues: Equatable {
    var kind: ProviderKind
    var name: String
    var apiRoot: String
    var modelID: String
    var allowsLoopbackHTTP: Bool
    var credentialLifetime: CredentialLifetime
  }

  @ObservedObject var store: PreviewWorkspace
  @StateObject private var discovery: ModelDiscoveryController
  @State private var modelFilter = ""

  @State private var editingProviderID: UUID?
  @State private var kind: ProviderKind = .chatCompletions
  @State private var name = ""
  @State private var apiRoot = "https://api.openai.com/v1"
  @State private var modelID = ""
  @State private var replacementSecret = ""
  @State private var codexCredential: CodexSessionCredential?
  @State private var codexImportGeneration = 0
  @State private var isImportingCodexLogin = false
  @State private var allowsLoopbackHTTP = false
  @State private var credentialLifetime: CredentialLifetime = .keychain
  @State private var selectedPreset: ProviderPreset?
  @State private var pendingPreset: ProviderPreset?
  @State private var isConfirmingPreset = false
  @State private var errorMessage: String?
  @State private var hasLoadedInitialSelection = false
  @State private var baseline = FieldValues(
    kind: .chatCompletions, name: "", apiRoot: "https://api.openai.com/v1", modelID: "",
    allowsLoopbackHTTP: false,
    credentialLifetime: .keychain)
  @State private var pendingProviderID: UUID?
  @State private var isConfirmingDiscard = false

  init(store: PreviewWorkspace, discovery: ModelDiscoveryController = ModelDiscoveryController()) {
    self.store = store
    _discovery = StateObject(wrappedValue: discovery)
  }

  private var editingProvider: ProviderConfig? {
    editingProviderID.flatMap { id in store.providers.first { $0.id == id } }
  }

  private var isNewProvider: Bool { editingProviderID == nil }

  private var cleanName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var cleanRoot: String {
    apiRoot.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var cleanModel: String {
    modelID.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var canSave: Bool {
    guard !store.isProviderSaving, !isImportingCodexLogin, !cleanName.isEmpty,
      !cleanModel.isEmpty
    else { return false }
    let changesKind = editingProvider.map { $0.kind != kind } ?? false
    switch kind {
    case .chatCompletions:
      return !cleanRoot.isEmpty
        && (!isNewProvider && !changesKind || !replacementSecret.isEmpty)
    case .codexResponses:
      return !isNewProvider && !changesKind || codexCredential != nil
    }
  }

  private var destinationHost: String? {
    guard let components = URLComponents(string: cleanRoot), let host = components.host,
      !host.isEmpty
    else {
      return nil
    }
    return host
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        introduction
        WorkspaceExportSection(store: store)
        AppearanceSettingsSection(store: store)
        Toggle("Show hidden conversations in this session", isOn: $store.showHidden)
        configurationPicker
        if isNewProvider { templatePicker }
        providerFields
        destinationDisclosure
        credentialDisclosure
      }
      .padding(28)
      .frame(maxWidth: 720, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .top)
    }
    .background(ShellTheme.background)
    .foregroundStyle(ShellTheme.foreground)
    .frame(minWidth: 520, minHeight: 620)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      VStack(spacing: 0) {
        Divider()
        actionRow.padding(.horizontal, 28).padding(.vertical, 16)
      }.background(ShellTheme.sidebar)
    }
    .disabled(store.isProviderSaving || store.isClosing)
    .onAppear { loadInitialSelectionIfNeeded() }
    .onChange(of: editingProviderID) { _, newValue in
      loadProvider(newValue)
    }
    .onChange(of: kind) { _, _ in updateDirtyState() }
    .onChange(of: name) { _, _ in updateDirtyState() }
    .onChange(of: apiRoot) { _, _ in
      resetDiscovery()
      updateDirtyState()
    }
    .onChange(of: modelID) { _, _ in updateDirtyState() }
    .onChange(of: replacementSecret) { _, _ in updateDirtyState() }
    .onChange(of: allowsLoopbackHTTP) { _, _ in
      resetDiscovery()
      updateDirtyState()
    }
    .onChange(of: credentialLifetime) { _, _ in
      replacementSecret = ""
      updateDirtyState()
    }
    .onDisappear {
      resetDiscovery()
      clearEnteredCredentials()
      store.providerSettingsDirty = false
    }
    .alert("Discard unsaved provider changes?", isPresented: $isConfirmingDiscard) {
      Button("Keep Editing", role: .cancel) { pendingProviderID = nil }
      Button("Discard Changes", role: .destructive) {
        let destination = pendingProviderID
        pendingProviderID = nil
        store.providerSettingsDirty = false
        editingProviderID = destination
      }
    } message: {
      Text("Changing configurations will discard the edits and any credential entered here.")
    }
    .alert("Replace this form with a setup template?", isPresented: $isConfirmingPreset) {
      Button("Keep Editing", role: .cancel) { pendingPreset = nil }
      Button("Replace Form", role: .destructive) {
        if let pendingPreset { applyPreset(pendingPreset) }
        pendingPreset = nil
      }
    } message: {
      Text(
        "The name, endpoint, model and HTTP choice will be replaced. Any entered credential is cleared; no connection is made."
      )
    }
  }

  private var introduction: some View {
    VStack(alignment: .leading, spacing: 7) {
      Text("Model Provider")
        .font(.system(size: 24, weight: .semibold))
      Text(
        "Add an OpenAI-compatible endpoint or use an explicitly imported Codex login with the experimental fixed-destination text adapter."
      )
      .font(.system(size: 13))
      .foregroundStyle(ShellTheme.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var templatePicker: some View {
    VStack(alignment: .leading, spacing: 8) {
      Picker(
        "Setup template",
        selection: Binding(
          get: { selectedPreset },
          set: { preset in
            guard let preset, preset != selectedPreset else { return }
            if store.providerSettingsDirty {
              pendingPreset = preset
              isConfirmingPreset = true
            } else {
              applyPreset(preset)
            }
          })
      ) {
        Text("Choose a template (optional)").tag(Optional<ProviderPreset>.none)
        ForEach(ProviderPreset.allCases) { preset in
          Text(preset.name).tag(Optional(preset))
        }
      }
      .accessibilityIdentifier("provider-setup-template")
      if let selectedPreset {
        Text(selectedPreset.guidance)
          .font(.caption).foregroundStyle(ShellTheme.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Text("Template values remain editable. Review the actual destination below before saving.")
          .font(.caption2).foregroundStyle(ShellTheme.secondary)
      }
    }
  }

  private var configurationPicker: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Configuration").font(.headline)
      Picker("Configuration to edit", selection: providerSelection) {
        Text("New configuration").tag(Optional<UUID>.none)
        ForEach(store.providers) { provider in
          Text(provider.name).tag(Optional(provider.id))
        }
      }
      .labelsHidden()
      .accessibilityLabel("Configuration to edit")
      .accessibilityIdentifier("provider-configuration-picker")

      if let editingProvider {
        Text(
          store.selectedProviderID == editingProvider.id
            ? "This configuration is selected for new replies."
            : "Saving selects this configuration for new replies."
        )
        .font(.system(size: 12))
        .foregroundStyle(ShellTheme.secondary)
      } else {
        Text("Create a configuration and select it for new replies.")
          .font(.system(size: 12))
          .foregroundStyle(ShellTheme.secondary)
      }
    }
  }

  private var providerFields: some View {
    GroupBox("Connection") {
      VStack(alignment: .leading, spacing: 14) {
        fieldLabel("Provider type", detail: providerKindDetail)
        Picker("Provider type", selection: kindSelection) {
          Text("OpenAI-compatible API").tag(ProviderKind.chatCompletions)
          Text("Codex login (experimental)").tag(ProviderKind.codexResponses)
        }
        .labelsHidden()
        .accessibilityLabel("Provider type")
        .accessibilityIdentifier("provider-kind")

        fieldLabel("Name", detail: "A local label, such as Work account")
        TextField("Provider name", text: $name)
          .textFieldStyle(.roundedBorder)
          .accessibilityLabel("Provider name")
          .accessibilityIdentifier("provider-name")

        if kind == .codexResponses {
          fieldLabel("Fixed destination", detail: "This experimental adapter cannot be redirected")
          Text(CodexResponsesProvider.apiRoot.absoluteString)
            .textSelection(.enabled)
            .accessibilityIdentifier("provider-codex-fixed-root")
        } else {
          fieldLabel("API base URL", detail: "HTTPS is required unless local HTTP is enabled below")
          TextField("https://api.example.com/v1", text: $apiRoot)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("API base URL")
            .accessibilityIdentifier("provider-api-root")
        }

        fieldLabel("Model", detail: "The exact model identifier accepted by the provider")
        TextField("Model identifier", text: $modelID)
          .textFieldStyle(.roundedBorder)
          .accessibilityLabel("Model identifier")
          .accessibilityIdentifier("provider-model-id")

        if kind == .chatCompletions {
          modelDiscovery

          Picker("Credential storage", selection: $credentialLifetime) {
            ForEach(CredentialLifetime.allCases) { lifetime in
              Text(lifetime.name).tag(lifetime)
            }
          }
          .accessibilityIdentifier("provider-credential-storage")

          fieldLabel(
            editingProvider == nil ? "Credential" : "Replacement credential",
            detail: editingProvider == nil
              ? "Required for a new configuration"
              : "Leave blank to keep the key for the same API root and storage mode; otherwise re-enter it"
          )
          SecureField("Provider credential", text: $replacementSecret)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel(
              editingProvider == nil ? "Provider credential" : "Replacement provider credential"
            )
            .accessibilityIdentifier("provider-secret")

          Toggle("Allow HTTP for loopback development servers", isOn: $allowsLoopbackHTTP)
            .toggleStyle(.checkbox)
            .accessibilityIdentifier("provider-loopback-http")
          Text(
            "This exception applies only to a loopback address such as localhost. Remote providers still require HTTPS."
          )
          .font(.system(size: 11))
          .foregroundStyle(ShellTheme.secondary)
          .fixedSize(horizontal: false, vertical: true)
        } else {
          codexImportControls
        }
      }
      .padding(8)
    }
  }

  private var providerKindDetail: String {
    switch kind {
    case .chatCompletions: "Uses an API key with the endpoint you enter"
    case .codexResponses: "Text-only, fixed-origin, session-only, and not a public API guarantee"
    }
  }

  private var kindSelection: Binding<ProviderKind> {
    Binding(
      get: { kind },
      set: { newKind in
        guard newKind != kind else { return }
        kind = newKind
        clearEnteredCredentials()
        resetDiscovery()
        selectedPreset = nil
        allowsLoopbackHTTP = false
        credentialLifetime = newKind == .codexResponses ? .session : .keychain
        if newKind == .codexResponses {
          apiRoot = CodexResponsesProvider.apiRoot.absoluteString
          if cleanModel.isEmpty { modelID = "gpt-5.6-luna" }
        } else if cleanRoot == CodexResponsesProvider.apiRoot.absoluteString {
          apiRoot = "https://api.openai.com/v1"
        }
        errorMessage = nil
        updateDirtyState()
      })
  }

  private var codexImportControls: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack {
        Button(codexCredential == nil ? "Import Codex auth.json…" : "Replace imported login…") {
          importCodexLogin()
        }
        .disabled(isImportingCodexLogin)
        .accessibilityIdentifier("provider-import-codex-login")
        if isImportingCodexLogin {
          ProgressView().controlSize(.small).accessibilityLabel("Waiting for Codex auth file")
        }
        if codexCredential != nil {
          Label("Imported for this session", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
            .accessibilityIdentifier("provider-codex-imported-status")
        }
      }
      Text(
        "Choose the auth.json maintained by Codex. Only the access token and account ID are retained in memory. The raw file, refresh token, path, and account details are not saved or displayed."
      )
      .font(.caption).foregroundStyle(ShellTheme.secondary)
      .fixedSize(horizontal: false, vertical: true)
      if editingProvider != nil, codexCredential == nil {
        Text(
          "The saved configuration contains no login. If this app was restarted or the token expired, import a current file before sending."
        )
        .font(.caption2).foregroundStyle(ShellTheme.warning)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func importCodexLogin() {
    guard !isImportingCodexLogin else { return }
    errorMessage = nil
    codexImportGeneration += 1
    let generation = codexImportGeneration
    isImportingCodexLogin = true
    Task {
      defer {
        if codexImportGeneration == generation { isImportingCodexLogin = false }
      }
      do {
        guard let imported = try await CodexAuthFileImporter.chooseCredential() else { return }
        guard codexImportGeneration == generation, kind == .codexResponses else { return }
        codexCredential = imported
        updateDirtyState()
      } catch {
        guard codexImportGeneration == generation, kind == .codexResponses else { return }
        codexCredential = nil
        errorMessage = PreviewWorkspace.providerErrorMessage(error)
        updateDirtyState()
      }
    }
  }

  private var canDiscoverModels: Bool {
    guard let root = URL(string: cleanRoot) else { return false }
    return
      (try? LocalRouterModelCatalog.endpoint(
        apiRoot: root, allowsLoopbackHTTP: allowsLoopbackHTTP)) != nil
  }

  private var matchingModels: [String] {
    discovery.models.filter {
      modelFilter.isEmpty || $0.localizedCaseInsensitiveContains(modelFilter)
    }
  }

  private var modelDiscovery: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Button(discovery.hasLoaded ? "Refresh local models" : "Discover local models") {
          discovery.discover(apiRoot: cleanRoot, allowsLoopbackHTTP: allowsLoopbackHTTP)
        }
        .disabled(!canDiscoverModels || discovery.isLoading)
        .accessibilityIdentifier("provider-discover-models")
        if discovery.isLoading {
          ProgressView().controlSize(.small).accessibilityLabel("Discovering local router models")
          Button("Cancel") { resetDiscovery() }
            .accessibilityIdentifier("provider-cancel-discovery")
        }
      }
      Text(
        "Local 9router only. Sends GET /models with no key or chat content. A model list does not verify account access or a successful reply."
      )
      .font(.caption).foregroundStyle(ShellTheme.secondary)
      .fixedSize(horizontal: false, vertical: true)
      if let error = discovery.errorMessage {
        Text(error).font(.caption).foregroundStyle(ShellTheme.warning)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("provider-model-discovery-error")
      }
      if discovery.hasLoaded {
        if discovery.models.isEmpty {
          Text(
            "The router advertised no models. Configure an upstream or enter a model ID manually."
          )
          .font(.caption).foregroundStyle(ShellTheme.secondary)
        } else {
          TextField("Filter discovered model IDs", text: $modelFilter)
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("provider-model-filter")
          Menu("Choose discovered model") {
            ForEach(Array(matchingModels.prefix(80)), id: \.self) { model in
              Button(model) { modelID = model }
            }
          }
          .disabled(matchingModels.isEmpty)
          .accessibilityIdentifier("provider-discovered-models")
          Text(
            "\(matchingModels.count) of \(discovery.models.count) IDs match; menu shows at most 80. Qualified IDs are used unchanged. Your typed model is kept until you choose one."
          )
          .font(.caption2).foregroundStyle(ShellTheme.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  private func resetDiscovery() {
    discovery.reset()
    modelFilter = ""
  }

  private var destinationDisclosure: some View {
    GroupBox("What is sent") {
      VStack(alignment: .leading, spacing: 9) {
        Label(destinationDescription, systemImage: "network")
          .accessibilityIdentifier("provider-destination-disclosure")
        Label(
          "Up to 100 prior messages, the current draft, and the selected bot's description.",
          systemImage: "text.bubble"
        )
        Label("Attachments are not sent.", systemImage: "paperclip")
        Text(
          "The provider may retain submitted content according to its own terms and privacy policy. Review those policies before sending sensitive information."
        )
        .font(.system(size: 12))
        .foregroundStyle(ShellTheme.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      .font(.system(size: 13))
      .padding(8)
    }
    .accessibilityIdentifier("provider-context-disclosure")
  }

  private var credentialDisclosure: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("Credential protection", systemImage: "key.fill")
        .font(.headline)
      Text(
        kind == .codexResponses
          ? "The imported Codex login is kept only in this app process. It is never written to Keychain or workspace storage. Quitting requires an explicit re-import. This app never refreshes or logs out the Codex account."
          : credentialLifetime.guidance
      )
      .font(.system(size: 12))
      .foregroundStyle(ShellTheme.secondary)
      .fixedSize(horizontal: false, vertical: true)
      Text(
        "Saving records the configuration; it does not verify the connection. Connection status is known only after a reply request succeeds."
      )
      .font(.system(size: 12))
      .foregroundStyle(ShellTheme.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var actionRow: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let errorMessage {
        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(ShellTheme.warning)
          .font(.system(size: 12))
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("provider-settings-error")
      }

      HStack {
        Spacer()
        if store.isProviderSaving {
          ProgressView().controlSize(.small).accessibilityLabel("Saving provider configuration")
        }
        Button(editingProvider == nil ? "Save and use" : "Save changes and use") {
          save()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!canSave)
        .accessibilityIdentifier("provider-save")
      }
    }
  }

  private var destinationDescription: String {
    let model = cleanModel.isEmpty ? "the entered model" : cleanModel
    if kind == .codexResponses {
      return
        "Text-only reply requests will be sent to chatgpt.com using \(model). Tools are disabled; failures never fall back to another endpoint."
    }
    guard let destinationHost else {
      return "Enter a valid API base URL to review the destination for \(model)."
    }
    return "Reply requests will be sent to \(destinationHost) using \(model)."
  }

  private var providerSelection: Binding<UUID?> {
    Binding(
      get: { editingProviderID },
      set: { requestedID in
        guard requestedID != editingProviderID else { return }
        if store.providerSettingsDirty {
          pendingProviderID = requestedID
          isConfirmingDiscard = true
        } else {
          editingProviderID = requestedID
        }
      })
  }

  private func fieldLabel(_ title: String, detail: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).font(.system(size: 13, weight: .medium))
      Text(detail).font(.system(size: 11)).foregroundStyle(ShellTheme.secondary)
    }
  }

  private func loadInitialSelectionIfNeeded() {
    guard !hasLoadedInitialSelection else { return }
    hasLoadedInitialSelection = true
    let initialID =
      store.selectedProviderID.flatMap { selectedID in
        store.providers.contains { $0.id == selectedID } ? selectedID : nil
      } ?? store.providers.first?.id
    editingProviderID = initialID
    loadProvider(initialID)
  }

  private func loadProvider(_ id: UUID?) {
    resetDiscovery()
    selectedPreset = nil
    clearEnteredCredentials()
    errorMessage = nil
    guard let id, let provider = store.providers.first(where: { $0.id == id }) else {
      kind = .chatCompletions
      name = ""
      apiRoot = "https://api.openai.com/v1"
      modelID = ""
      allowsLoopbackHTTP = false
      credentialLifetime = .keychain
      baseline = currentFieldValues
      store.providerSettingsDirty = false
      return
    }
    kind = provider.kind
    name = provider.name
    apiRoot = provider.apiRoot.absoluteString
    modelID = provider.modelID
    allowsLoopbackHTTP = provider.allowsLoopbackHTTP
    credentialLifetime = CredentialLifetime.forReference(provider.credentialReference)
    baseline = currentFieldValues
    store.providerSettingsDirty = false
  }

  private var currentFieldValues: FieldValues {
    FieldValues(
      kind: kind, name: name, apiRoot: apiRoot, modelID: modelID,
      allowsLoopbackHTTP: allowsLoopbackHTTP,
      credentialLifetime: credentialLifetime)
  }

  private func applyPreset(_ preset: ProviderPreset) {
    resetDiscovery()
    kind = .chatCompletions
    selectedPreset = preset
    name = preset == .custom ? "" : preset.name
    apiRoot = preset.apiRoot
    modelID = preset.suggestedModel
    // Even a local template needs an explicit HTTP opt-in. Never carry entered keys across roots.
    allowsLoopbackHTTP = false
    clearEnteredCredentials()
    errorMessage = nil
    updateDirtyState()
  }

  private func updateDirtyState() {
    store.providerSettingsDirty =
      currentFieldValues != baseline || !replacementSecret.isEmpty || codexCredential != nil
  }

  private func clearEnteredCredentials() {
    codexImportGeneration += 1
    isImportingCodexLogin = false
    replacementSecret = ""
    codexCredential = nil
  }

  private func save() {
    guard canSave else { return }
    errorMessage = nil
    let providerID = editingProviderID
    let submittedName = name
    let submittedRoot = apiRoot
    let submittedModel = modelID
    let submittedSecret = replacementSecret
    let submittedLoopback = allowsLoopbackHTTP
    let submittedLifetime = credentialLifetime
    let submittedKind = kind
    let submittedCodexCredential = codexCredential

    Task {
      do {
        let savedID = try await store.saveProvider(
          id: providerID,
          name: submittedName,
          apiRoot: submittedRoot,
          modelID: submittedModel,
          secret: submittedSecret,
          allowsLoopbackHTTP: submittedLoopback,
          credentialLifetime: submittedLifetime,
          kind: submittedKind,
          codexCredential: submittedCodexCredential
        )
        clearEnteredCredentials()
        editingProviderID = savedID
        store.selectedProviderID = savedID
        loadProvider(savedID)
        store.providerSettingsDirty = false
      } catch {
        errorMessage = PreviewWorkspace.providerErrorMessage(error)
      }
    }
  }
}
