import Foundation
import XCTest

@testable import NativeShell

@MainActor
final class WorkspacePreferencesTests: XCTestCase {
  private static let storageKey =
    "local.independent.BotWorkspace.workspace-preferences.v1"

  func testAppearanceContractAndDefaults() {
    XCTAssertEqual(WorkspaceAppearance.allCases, [.dark, .light, .system])
    XCTAssertEqual(WorkspaceAppearance.allCases.map(\.id), ["dark", "light", "system"])
    XCTAssertEqual(WorkspaceAppearance.allCases.map(\.title), ["Dark", "Light", "Follow System"])
    XCTAssertEqual(
      WorkspacePreferences(),
      WorkspacePreferences(
        appearance: .dark, sidebarWidth: 280, inspectorWidth: 320,
        sidebarVisible: true, inspectorPreferred: true))
    XCTAssertEqual(WorkspacePreferences.sidebarBounds, 240...400)
    XCTAssertEqual(WorkspacePreferences.inspectorBounds, 280...440)
  }

  func testPersistentLoadReturnsDefaultsWithoutWriting() {
    withDefaults { defaults in
      let before = defaults.dictionaryRepresentation()
      XCTAssertEqual(WorkspacePreferencesStorage(defaults: defaults).load(), WorkspacePreferences())
      let after = defaults.dictionaryRepresentation()
      XCTAssertEqual(before as NSDictionary, after as NSDictionary)
      XCTAssertNil(defaults.object(forKey: Self.storageKey))
    }
  }

  func testRoundTripAcrossStorageInstances() {
    withDefaults { defaults in
      let expected = WorkspacePreferences(
        appearance: .system, sidebarWidth: 365.5, inspectorWidth: 411.25,
        sidebarVisible: false, inspectorPreferred: false)
      WorkspacePreferencesStorage(defaults: defaults).save(expected)
      XCTAssertEqual(WorkspacePreferencesStorage(defaults: defaults).load(), expected)
    }
  }

  func testSanitizedResetsNonFiniteWidthsAndClampsFiniteWidths() {
    XCTAssertEqual(
      WorkspacePreferences(sidebarWidth: .nan, inspectorWidth: .infinity).sanitized(),
      WorkspacePreferences())
    XCTAssertEqual(
      WorkspacePreferences(sidebarWidth: -.infinity, inspectorWidth: -.infinity).sanitized(),
      WorkspacePreferences())
    XCTAssertEqual(
      WorkspacePreferences(sidebarWidth: 1, inspectorWidth: 10_000).sanitized(),
      WorkspacePreferences(sidebarWidth: 240, inspectorWidth: 440))
  }

  func testInvalidFieldsRecoverIndividuallyAndFutureAppearanceDefaults() {
    withDefaults { defaults in
      defaults.set(
        [
          "version": 99,
          "appearance": "future-high-contrast",
          "sidebarWidth": true,
          "inspectorWidth": 401.5,
          "sidebarVisible": 1,
          "inspectorPreferred": false,
        ], forKey: Self.storageKey)

      XCTAssertEqual(
        WorkspacePreferencesStorage(defaults: defaults).load(),
        WorkspacePreferences(
          appearance: .dark, sidebarWidth: 280, inspectorWidth: 401.5,
          sidebarVisible: true, inspectorPreferred: false))
    }
  }

  func testPersistedNonFiniteAndOutOfRangeWidthsAreSanitized() {
    withDefaults { defaults in
      defaults.set(
        [
          "appearance": "light",
          "sidebarWidth": Double.nan,
          "inspectorWidth": 900.0,
          "sidebarVisible": false,
          "inspectorPreferred": true,
        ], forKey: Self.storageKey)

      XCTAssertEqual(
        WorkspacePreferencesStorage(defaults: defaults).load(),
        WorkspacePreferences(
          appearance: .light, sidebarWidth: 280, inspectorWidth: 440,
          sidebarVisible: false, inspectorPreferred: true))
    }
  }

  func testSaveDoesNotRemoveUnrelatedDefaults() {
    withDefaults { defaults in
      defaults.set("leave-me-alone", forKey: "unrelated.preference")
      WorkspacePreferencesStorage(defaults: defaults).save(
        WorkspacePreferences(appearance: .light))
      XCTAssertEqual(defaults.string(forKey: "unrelated.preference"), "leave-me-alone")
      XCTAssertEqual(
        Set((defaults.dictionary(forKey: Self.storageKey) ?? [:]).keys),
        [
          "version", "appearance", "sidebarWidth", "inspectorWidth", "sidebarVisible",
          "inspectorPreferred",
        ])
    }
  }

  func testMemoryOnlyStorageRetainsWithinInstanceAndInstancesAreIsolated() {
    let first = WorkspacePreferencesStorage()
    let second = WorkspacePreferencesStorage()
    let expected = WorkspacePreferences(
      appearance: .system, sidebarWidth: 350, inspectorWidth: 390,
      sidebarVisible: false, inspectorPreferred: false)

    first.save(expected)

    XCTAssertEqual(first.load(), expected)
    XCTAssertEqual(second.load(), WorkspacePreferences())
  }

  private func withDefaults(_ body: (UserDefaults) -> Void) {
    let name = "WorkspacePreferencesTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: name) else {
      XCTFail("Could not create isolated defaults suite")
      return
    }
    defaults.removePersistentDomain(forName: name)
    defer { defaults.removePersistentDomain(forName: name) }
    body(defaults)
  }

}
