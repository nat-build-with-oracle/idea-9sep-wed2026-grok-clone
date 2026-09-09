import SwiftUI

struct AppearanceSettingsSection: View {
  @ObservedObject var store: PreviewWorkspace
  @State private var draft = AppearanceSettingsDraft(WorkspacePreferences())
  @State private var baseline = AppearanceSettingsDraft(WorkspacePreferences())
  @State private var loaded = false

  private var isDirty: Bool { loaded && draft != baseline }

  var body: some View {
    GroupBox("Appearance and layout") {
      VStack(alignment: .leading, spacing: 12) {
        Picker("Appearance", selection: $draft.appearance) {
          ForEach(WorkspaceAppearance.allCases) { appearance in
            Text(appearance.title).tag(appearance)
          }
        }.accessibilityIdentifier("workspace-appearance")
        Toggle("Show sidebar", isOn: $draft.sidebarVisible)
          .accessibilityIdentifier("preference-sidebar")
        Toggle("Show conversation details when space permits", isOn: $draft.inspectorPreferred)
          .accessibilityIdentifier("preference-inspector")
        Text(
          "Save applies to all app windows and is kept on this Mac. Divider widths are saved when adjusted. These preferences are not included in workspace exports."
        )
        .font(.caption).foregroundStyle(ShellTheme.secondary)
        .fixedSize(horizontal: false, vertical: true)
        HStack {
          Button("Cancel Changes") { reload() }
            .disabled(!isDirty)
            .accessibilityIdentifier("cancel-appearance-settings")
          Spacer()
          Button("Save Appearance") {
            store.preferences = draft.applying(to: store.preferences)
            reload()
          }
          .disabled(!isDirty)
          .accessibilityIdentifier("save-appearance-settings")
        }
      }.padding(8)
    }
    .accessibilityIdentifier("appearance-settings")
    .onAppear { if !loaded { reload() } }
    .onChange(of: draft) { _, _ in store.appearanceSettingsDirty = isDirty }
    .onChange(of: store.preferences) { _, _ in if !isDirty { reload() } }
  }

  private func reload() {
    draft = AppearanceSettingsDraft(store.preferences)
    baseline = draft
    loaded = true
    store.appearanceSettingsDirty = false
  }
}
