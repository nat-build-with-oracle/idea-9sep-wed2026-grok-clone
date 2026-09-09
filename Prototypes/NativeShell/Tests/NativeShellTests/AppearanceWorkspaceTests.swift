import Combine
import Foundation
import XCTest

@testable import NativeShell

@MainActor final class AppearanceWorkspaceTests: XCTestCase {
  func testInjectedPreferencesLoadAndVisibilityMutationsPersistAcrossWorkspaceInstances() throws {
    let suite = "AppearanceWorkspaceTests-\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let storage = WorkspacePreferencesStorage(defaults: defaults)
    var saved = WorkspacePreferences()
    saved.appearance = .light
    saved.sidebarWidth = 390
    storage.save(saved)
    let first = PreviewWorkspace(seed: false, preferencesStorage: storage)
    XCTAssertEqual(first.preferences, saved)
    first.sidebarVisible = false
    first.inspectorPreferred = false
    first.preferences.inspectorWidth = 410
    let second = PreviewWorkspace(
      seed: false, preferencesStorage: WorkspacePreferencesStorage(defaults: defaults))
    XCTAssertEqual(second.preferences.appearance, .light)
    XCTAssertEqual(second.preferences.sidebarWidth, 390)
    XCTAssertEqual(second.preferences.inspectorWidth, 410)
    XCTAssertFalse(second.sidebarVisible)
    XCTAssertFalse(second.inspectorPreferred)
    XCTAssertTrue(second.conversations.isEmpty)
    XCTAssertNil(second.repository)
  }

  func testDefaultWorkspacesDoNotSharePreferences() {
    let first = PreviewWorkspace(seed: false)
    first.preferences.appearance = .light
    first.sidebarVisible = false
    let second = PreviewWorkspace(seed: false)
    XCTAssertEqual(second.preferences, WorkspacePreferences())
  }

  func testComputedVisibilityStillPublishesWorkspaceChanges() {
    let workspace = PreviewWorkspace(seed: false)
    var changes = 0
    let subscription = workspace.objectWillChange.sink { changes += 1 }
    workspace.sidebarVisible = false
    workspace.inspectorPreferred = false
    workspace.preferences.appearance = .system
    XCTAssertEqual(changes, 3)
    withExtendedLifetime(subscription) {}
  }

  func testAppearanceDraftIsDetachedAndAppliesWithoutOverwritingLiveDividerWidths() {
    let workspace = PreviewWorkspace(seed: false)
    var draft = AppearanceSettingsDraft(workspace.preferences)
    draft.appearance = .light
    draft.sidebarVisible = false
    XCTAssertEqual(workspace.preferences.appearance, .dark)
    XCTAssertTrue(workspace.sidebarVisible)
    workspace.preferences.sidebarWidth = 380
    workspace.preferences.inspectorWidth = 430
    workspace.preferences = draft.applying(to: workspace.preferences)
    XCTAssertEqual(workspace.preferences.appearance, .light)
    XCTAssertFalse(workspace.sidebarVisible)
    XCTAssertEqual(workspace.preferences.sidebarWidth, 380)
    XCTAssertEqual(workspace.preferences.inspectorWidth, 430)
  }

  func testDiscardedAppearanceDraftDoesNotChangeSavedPreferencesOrDraft() {
    let workspace = PreviewWorkspace(seed: true)
    let preferences = workspace.preferences
    let conversations = workspace.conversations
    workspace.draft = "Keep this unsent draft"
    var edited = AppearanceSettingsDraft(preferences)
    edited.appearance = .system
    edited.inspectorPreferred = false
    edited = AppearanceSettingsDraft(workspace.preferences)
    XCTAssertEqual(edited, AppearanceSettingsDraft(preferences))
    XCTAssertEqual(workspace.preferencesStorage.load(), preferences)
    XCTAssertEqual(workspace.conversations.map(\.id), conversations.map(\.id))
    XCTAssertEqual(workspace.draft, "Keep this unsent draft")
  }

  func testMinimumWindowConstrainsWideSavedSidebarWithoutChangingPreference() {
    var preferences = WorkspacePreferences()
    preferences.sidebarWidth = 400
    let layout = WorkspaceLayout(containerWidth: 760, preferences: preferences, pickerOpen: false)
    XCTAssertEqual(layout.sidebarWidth, 335)
    XCTAssertFalse(layout.showsInspector)
    XCTAssertEqual(760 - layout.sidebarWidth - 1, 424)
    XCTAssertEqual(preferences.sidebarWidth, 400)
    XCTAssertTrue(preferences.inspectorPreferred)
  }

  func testInspectorReturnsAfterWideningAndPickerDoesNotEraseVisibilityPreference() {
    let preferences = WorkspacePreferences()
    XCTAssertFalse(
      WorkspaceLayout(containerWidth: 760, preferences: preferences, pickerOpen: false)
        .showsInspector)
    XCTAssertTrue(
      WorkspaceLayout(containerWidth: 1280, preferences: preferences, pickerOpen: false)
        .showsInspector)
    XCTAssertFalse(
      WorkspaceLayout(containerWidth: 1280, preferences: preferences, pickerOpen: true)
        .showsInspector)
    XCTAssertTrue(preferences.inspectorPreferred)
  }

  func testHiddenSidebarUsesNoWidthAndExplicitHiddenInspectorStaysHidden() {
    var preferences = WorkspacePreferences()
    preferences.sidebarVisible = false
    var layout = WorkspaceLayout(containerWidth: 800, preferences: preferences, pickerOpen: false)
    XCTAssertEqual(layout.sidebarWidth, 0)
    XCTAssertTrue(layout.showsInspector)
    preferences.inspectorPreferred = false
    layout = WorkspaceLayout(containerWidth: 1440, preferences: preferences, pickerOpen: false)
    XCTAssertFalse(layout.showsInspector)
  }

  func testLayoutSanitizesNonfiniteInputs() {
    var preferences = WorkspacePreferences()
    preferences.sidebarWidth = .infinity
    preferences.inspectorWidth = .nan
    let layout = WorkspaceLayout(containerWidth: .nan, preferences: preferences, pickerOpen: false)
    XCTAssertEqual(layout.sidebarWidth, 280)
    XCTAssertEqual(layout.inspectorWidth, 320)
    XCTAssertFalse(layout.showsInspector)
  }
}
