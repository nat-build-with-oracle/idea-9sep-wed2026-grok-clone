import Foundation

/// Saved widths are preferences, not permission to squeeze the transcript below its minimum.
struct WorkspaceLayout: Equatable {
  let sidebarWidth: Double
  let inspectorWidth: Double
  let showsInspector: Bool

  init(containerWidth: Double, preferences: WorkspacePreferences, pickerOpen: Bool) {
    let preferences = preferences.sanitized()
    let width = containerWidth.isFinite ? max(0, containerWidth) : 760
    sidebarWidth =
      preferences.sidebarVisible
      ? min(preferences.sidebarWidth, max(240, width - 425)) : 0
    inspectorWidth = preferences.inspectorWidth
    showsInspector =
      preferences.inspectorPreferred && !pickerOpen
      && width >= sidebarWidth + inspectorWidth + 426
  }
}

/// A settings save never overwrites divider adjustments made while the form was open.
struct AppearanceSettingsDraft: Equatable {
  var appearance: WorkspaceAppearance
  var sidebarVisible: Bool
  var inspectorPreferred: Bool

  init(_ preferences: WorkspacePreferences) {
    appearance = preferences.appearance
    sidebarVisible = preferences.sidebarVisible
    inspectorPreferred = preferences.inspectorPreferred
  }

  func applying(to preferences: WorkspacePreferences) -> WorkspacePreferences {
    var result = preferences
    result.appearance = appearance
    result.sidebarVisible = sidebarVisible
    result.inspectorPreferred = inspectorPreferred
    return result.sanitized()
  }
}
