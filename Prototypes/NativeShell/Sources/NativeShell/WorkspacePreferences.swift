import CoreFoundation
import Foundation

enum WorkspaceAppearance: String, CaseIterable, Codable, Sendable, Identifiable {
  case dark
  case light
  case system

  var id: String { rawValue }

  var title: String {
    switch self {
    case .dark: "Dark"
    case .light: "Light"
    case .system: "Follow System"
    }
  }
}

struct WorkspacePreferences: Equatable, Sendable {
  static let sidebarBounds = 240.0...400.0
  static let inspectorBounds = 280.0...440.0

  var appearance: WorkspaceAppearance
  var sidebarWidth: Double
  var inspectorWidth: Double
  var sidebarVisible: Bool
  var inspectorPreferred: Bool

  init(
    appearance: WorkspaceAppearance = .dark,
    sidebarWidth: Double = 280,
    inspectorWidth: Double = 320,
    sidebarVisible: Bool = true,
    inspectorPreferred: Bool = true
  ) {
    self.appearance = appearance
    self.sidebarWidth = sidebarWidth
    self.inspectorWidth = inspectorWidth
    self.sidebarVisible = sidebarVisible
    self.inspectorPreferred = inspectorPreferred
  }

  func sanitized() -> Self {
    let defaults = Self()
    return Self(
      appearance: appearance,
      sidebarWidth: Self.sanitize(
        sidebarWidth, bounds: Self.sidebarBounds, fallback: defaults.sidebarWidth),
      inspectorWidth: Self.sanitize(
        inspectorWidth, bounds: Self.inspectorBounds, fallback: defaults.inspectorWidth),
      sidebarVisible: sidebarVisible,
      inspectorPreferred: inspectorPreferred)
  }

  private static func sanitize(
    _ value: Double, bounds: ClosedRange<Double>, fallback: Double
  ) -> Double {
    guard value.isFinite else { return fallback }
    return min(max(value, bounds.lowerBound), bounds.upperBound)
  }
}

@MainActor
final class WorkspacePreferencesStorage {
  private enum Field {
    static let storageKey = "local.independent.BotWorkspace.workspace-preferences.v1"
    static let version = "version"
    static let appearance = "appearance"
    static let sidebarWidth = "sidebarWidth"
    static let inspectorWidth = "inspectorWidth"
    static let sidebarVisible = "sidebarVisible"
    static let inspectorPreferred = "inspectorPreferred"
  }

  private let defaults: UserDefaults?
  private var memoryValue = WorkspacePreferences()

  init(defaults: UserDefaults? = nil) { self.defaults = defaults }

  func load() -> WorkspacePreferences {
    guard let defaults, let stored = defaults.dictionary(forKey: Field.storageKey) else {
      return memoryValue
    }

    let fallback = WorkspacePreferences()
    return WorkspacePreferences(
      appearance: appearance(stored[Field.appearance]) ?? fallback.appearance,
      sidebarWidth: number(stored[Field.sidebarWidth]) ?? fallback.sidebarWidth,
      inspectorWidth: number(stored[Field.inspectorWidth]) ?? fallback.inspectorWidth,
      sidebarVisible: boolean(stored[Field.sidebarVisible]) ?? fallback.sidebarVisible,
      inspectorPreferred: boolean(stored[Field.inspectorPreferred]) ?? fallback.inspectorPreferred
    ).sanitized()
  }

  func save(_ preferences: WorkspacePreferences) {
    let value = preferences.sanitized()
    guard let defaults else {
      memoryValue = value
      return
    }
    defaults.set(
      [
        Field.version: 1,
        Field.appearance: value.appearance.rawValue,
        Field.sidebarWidth: value.sidebarWidth,
        Field.inspectorWidth: value.inspectorWidth,
        Field.sidebarVisible: value.sidebarVisible,
        Field.inspectorPreferred: value.inspectorPreferred,
      ], forKey: Field.storageKey)
  }

  private func appearance(_ value: Any?) -> WorkspaceAppearance? {
    guard let rawValue = value as? String else { return nil }
    return WorkspaceAppearance(rawValue: rawValue)
  }

  private func number(_ value: Any?) -> Double? {
    guard let value = value as? NSNumber,
      CFGetTypeID(value) != CFBooleanGetTypeID()
    else { return nil }
    return value.doubleValue
  }

  private func boolean(_ value: Any?) -> Bool? {
    guard let value = value as? NSNumber,
      CFGetTypeID(value) == CFBooleanGetTypeID()
    else { return nil }
    return value.boolValue
  }
}
