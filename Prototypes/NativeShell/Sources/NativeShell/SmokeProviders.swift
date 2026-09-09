import Foundation
import WorkspaceCore

/// Never selected by a normal workspace. These fixtures are injected only by --verify-workspace.
actor SmokeCredentials: CredentialStore {
  private var values: [String: Data] = [:]
  func read(_ reference: String) throws -> Data {
    guard let data = values[reference] else { throw ProviderError.missingCredential }
    return data
  }
  func write(_ secret: Data, for reference: String) { values[reference] = secret }
  func remove(_ reference: String) { values[reference] = nil }
}

struct SmokeChatProvider: ChatProvider {
  static let reply =
    "Offline smoke fixture: the fictional project is ready for a short planning draft. No external request was made."
  func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
    AsyncThrowingStream { continuation in
      for word in Self.reply.split(separator: " ", omittingEmptySubsequences: false).enumerated() {
        continuation.yield(.text((word.offset == 0 ? "" : " ") + word.element))
      }
      continuation.yield(.finished)
      continuation.finish()
    }
  }
}
