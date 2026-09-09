import SwiftUI
import WorkspaceCore

/// Edits provider metadata while keeping credentials inside the workspace's credential service.
/// This view never reads a saved credential back into SwiftUI state.
struct ProviderSettingsView: View {
  private struct FieldValues: Equatable {
    var name: String
    var apiRoot: String
    var modelID: String
    var allowsLoopbackHTTP: Bool
  }

  @ObservedObject var store: PreviewWorkspace

  @State private var editingProviderID: UUID?
  @State private var name = ""
  @State private var apiRoot = "https://api.openai.com/v1"
  @State private var modelID = ""
  @State private var replacementSecret = ""
  @State private var allowsLoopbackHTTP = false
  @State private var errorMessage: String?
  @State private var hasLoadedInitialSelection = false
  @State private var baseline = FieldValues(
    name: "", apiRoot: "https://api.openai.com/v1", modelID: "", allowsLoopbackHTTP: false)
  @State private var pendingProviderID: UUID?
  @State private var isConfirmingDiscard = false

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
    !store.isProviderSaving && !cleanName.isEmpty && !cleanRoot.isEmpty && !cleanModel.isEmpty
      && (!isNewProvider || !replacementSecret.isEmpty)
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
        DisclosureGroup("Workspace preferences") {
          VStack(alignment: .leading, spacing: 10) {
            Toggle("Show hidden conversations", isOn: $store.showHidden)
            Toggle("Show conversation details", isOn: $store.inspectorPreferred)
            Text("These display preferences apply to this session.")
              .font(.caption).foregroundStyle(ShellTheme.secondary)
          }.padding(.top, 8).frame(maxWidth: .infinity, alignment: .leading)
        }
        configurationPicker
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
    .preferredColorScheme(.dark)
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
    .onChange(of: name) { _, _ in updateDirtyState() }
    .onChange(of: apiRoot) { _, _ in updateDirtyState() }
    .onChange(of: modelID) { _, _ in updateDirtyState() }
    .onChange(of: replacementSecret) { _, _ in updateDirtyState() }
    .onChange(of: allowsLoopbackHTTP) { _, _ in updateDirtyState() }
    .onDisappear {
      replacementSecret = ""
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
  }

  private var introduction: some View {
    VStack(alignment: .leading, spacing: 7) {
      Text("Model Provider")
        .font(.system(size: 24, weight: .semibold))
      Text(
        "Add an OpenAI-compatible chat endpoint. Saving stores configuration metadata in the workspace and the credential in the protected macOS Keychain."
      )
      .font(.system(size: 13))
      .foregroundStyle(ShellTheme.secondary)
      .fixedSize(horizontal: false, vertical: true)
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
        fieldLabel("Name", detail: "A local label, such as Work account")
        TextField("Provider name", text: $name)
          .textFieldStyle(.roundedBorder)
          .accessibilityLabel("Provider name")
          .accessibilityIdentifier("provider-name")

        fieldLabel("API base URL", detail: "HTTPS is required unless local HTTP is enabled below")
        TextField("https://api.example.com/v1", text: $apiRoot)
          .textFieldStyle(.roundedBorder)
          .accessibilityLabel("API base URL")
          .accessibilityIdentifier("provider-api-root")

        fieldLabel("Model", detail: "The exact model identifier accepted by the provider")
        TextField("Model identifier", text: $modelID)
          .textFieldStyle(.roundedBorder)
          .accessibilityLabel("Model identifier")
          .accessibilityIdentifier("provider-model-id")

        fieldLabel(
          editingProvider == nil ? "Credential" : "Replacement credential",
          detail: editingProvider == nil
            ? "Required for a new configuration"
            : "Leave blank to keep the key for the same API root; re-enter it if the destination changes"
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
      }
      .padding(8)
    }
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
        "The credential is written to the protected macOS Keychain and is never displayed here. A locally built app may need an authorized signing profile to use the protected Keychain. There is no plaintext fallback."
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
          .foregroundStyle(.orange)
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
    replacementSecret = ""
    errorMessage = nil
    guard let id, let provider = store.providers.first(where: { $0.id == id }) else {
      name = ""
      apiRoot = "https://api.openai.com/v1"
      modelID = ""
      allowsLoopbackHTTP = false
      baseline = currentFieldValues
      store.providerSettingsDirty = false
      return
    }
    name = provider.name
    apiRoot = provider.apiRoot.absoluteString
    modelID = provider.modelID
    allowsLoopbackHTTP = provider.allowsLoopbackHTTP
    baseline = currentFieldValues
    store.providerSettingsDirty = false
  }

  private var currentFieldValues: FieldValues {
    FieldValues(
      name: name, apiRoot: apiRoot, modelID: modelID, allowsLoopbackHTTP: allowsLoopbackHTTP)
  }

  private func updateDirtyState() {
    store.providerSettingsDirty = currentFieldValues != baseline || !replacementSecret.isEmpty
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

    Task {
      do {
        let savedID = try await store.saveProvider(
          id: providerID,
          name: submittedName,
          apiRoot: submittedRoot,
          modelID: submittedModel,
          secret: submittedSecret,
          allowsLoopbackHTTP: submittedLoopback
        )
        replacementSecret = ""
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
