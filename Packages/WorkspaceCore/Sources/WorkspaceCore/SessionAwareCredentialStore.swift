import Foundation

public enum CredentialLifetime: String, CaseIterable, Sendable, Identifiable {
  case keychain, session
  public var id: Self { self }
  public var name: String { self == .keychain ? "Protected Keychain" : "This session only" }
  public var guidance: String {
    switch self {
    case .keychain:
      "Stored in the protected macOS Keychain. Requires an authorized signing profile. A failure never switches to session storage automatically."
    case .session:
      "Kept only in this app process's memory, not written to Keychain or workspace storage. After quitting, re-enter the key. Provider settings and chat history still persist."
    }
  }

  private static let sessionPrefix = "session-provider-"
  public static func forReference(_ reference: String) -> Self {
    reference.hasPrefix(sessionPrefix) ? .session : .keychain
  }
  public func makeReference() -> String {
    (self == .session ? Self.sessionPrefix : "provider-") + UUID().uuidString
  }
}

/// Explicit reference-scoped storage; persistent errors never cause an in-memory fallback.
/// The caller chooses a lifetime before creating a reference. No secret is Codable or logged.
public actor SessionAwareCredentialStore: CredentialStore {
  private let persistent: any CredentialStore
  private var sessionValues: [String: Data] = [:]

  public init(persistent: any CredentialStore = KeychainCredentialStore()) {
    self.persistent = persistent
  }

  public func read(_ reference: String) async throws -> Data {
    if CredentialLifetime.forReference(reference) == .session {
      guard let value = sessionValues[reference] else { throw ProviderError.missingCredential }
      return value
    }
    return try await persistent.read(reference)
  }

  public func write(_ secret: Data, for reference: String) async throws {
    guard !secret.isEmpty else { throw ProviderError.invalidCredential }
    if CredentialLifetime.forReference(reference) == .session {
      sessionValues[reference] = secret
    } else {
      try await persistent.write(secret, for: reference)
    }
  }

  public func remove(_ reference: String) async throws {
    if CredentialLifetime.forReference(reference) == .session {
      sessionValues[reference] = nil
    } else {
      try await persistent.remove(reference)
    }
  }
}
