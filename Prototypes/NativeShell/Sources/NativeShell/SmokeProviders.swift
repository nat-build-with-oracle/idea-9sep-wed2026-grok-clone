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

struct SmokeRouterModelCatalog: RouterModelCatalog {
  static let modelIDs = ["cx/smoke-text", "glm/smoke-text", "local/smoke-text"]
  func models(apiRoot: URL, allowsLoopbackHTTP: Bool) async throws -> [String] { Self.modelIDs }
}

/// URL loading is intercepted only when explicitly injected by the isolated Codex fixture smoke.
final class SmokeCodexURLProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    guard request.url == CodexResponsesProvider.endpoint,
      request.value(forHTTPHeaderField: "Authorization") == "Bearer offline-codex-fixture"
    else {
      client?.urlProtocol(self, didFailWithError: ProviderError.invalidResponse)
      return
    }
    let response = HTTPURLResponse(
      url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
      headerFields: [:])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    // Mirrors the observed fixed-backend stream: MIME omitted and terminal output not repeated.
    let events: [[String: Any]] = [
      ["type": "response.output_text.delta", "delta": "READY"],
      [
        "type": "response.output_item.done",
        "item": [
          "type": "message", "role": "assistant",
          "content": [["type": "output_text", "text": "READY"]],
        ],
      ],
      [
        "type": "response.completed",
        "response": [
          "id": "offline-response", "status": "completed",
          "output": [],
        ],
      ],
    ]
    do {
      for event in events {
        let json = try JSONSerialization.data(withJSONObject: event)
        var bytes = Data("data: ".utf8)
        bytes.append(json)
        bytes.append(Data("\n\n".utf8))
        for byte in bytes { client?.urlProtocol(self, didLoad: Data([byte])) }
      }
      client?.urlProtocolDidFinishLoading(self)
    } catch { client?.urlProtocol(self, didFailWithError: ProviderError.invalidResponse) }
  }
  override func stopLoading() {}
}

/// Verifies the real native reply submission reaches the provider boundary with explicit context.
struct SmokeReplyChatProvider: ChatProvider {
  static let followUp = "Explain how this source helps our fictional project."
  func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
    if request.turns.last?.content == Self.followUp {
      guard request.turns.first?.content.contains("Reply context:") == true,
        request.turns.filter({ $0.role == "assistant" && $0.content == SmokeChatProvider.reply })
          .count == 1
      else { return AsyncThrowingStream { $0.finish(throwing: ProviderError.invalidResponse) } }
    }
    return SmokeChatProvider().stream(request)
  }
}
