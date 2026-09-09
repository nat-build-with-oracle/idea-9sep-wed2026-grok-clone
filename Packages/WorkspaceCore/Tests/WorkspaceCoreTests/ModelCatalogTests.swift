import Foundation
import XCTest

@testable import WorkspaceCore

final class ModelCatalogTests: XCTestCase {
  func testEndpointAppendsModelsOnceAndAcceptsExplicitLoopbackOnly() throws {
    for root in [
      "http://127.0.0.1:20128/v1", "http://127.0.0.1:20128/v1/",
      "http://127.0.0.1:20128/v1/models/", "http://127.0.0.1:20128/v1/chat/completions/",
    ] {
      XCTAssertEqual(
        try LocalRouterModelCatalog.endpoint(apiRoot: URL(string: root)!, allowsLoopbackHTTP: true)
          .absoluteString,
        "http://127.0.0.1:20128/v1/models")
    }
    XCTAssertEqual(
      try LocalRouterModelCatalog.endpoint(
        apiRoot: URL(string: "https://localhost/v1")!, allowsLoopbackHTTP: false
      ).host, "localhost")
    XCTAssertEqual(
      try LocalRouterModelCatalog.endpoint(
        apiRoot: URL(string: "http://[::1]:20128/v1")!, allowsLoopbackHTTP: true
      ).path, "/v1/models")
  }

  func testEndpointRejectsRemoteOriginsAndUnsafeRoots() {
    for root in [
      "http://127.0.0.1:20128/v1", "https://router.example/v1", "http://localhost.evil/v1",
      "http://192.168.1.2/v1", "https://user:secret@localhost/v1",
      "https://localhost/v1?key=secret", "https://localhost/v1#fragment",
    ] {
      XCTAssertThrowsError(
        try LocalRouterModelCatalog.endpoint(apiRoot: URL(string: root)!, allowsLoopbackHTTP: false)
      ) {
        XCTAssertEqual($0 as? ModelCatalogError, .localEndpointRequired)
      }
    }
  }

  func testDecodePreservesQualifiedIDsAndRemovesExactDuplicates() throws {
    XCTAssertEqual(
      try LocalRouterModelCatalog.decode(
        catalogBody(["glm/glm-5.3", "cx/fixture", "glm/glm-5.3", "My combo"])),
      ["My combo", "cx/fixture", "glm/glm-5.3"])
    XCTAssertEqual(try LocalRouterModelCatalog.decode(catalogBody([])), [])
  }

  func testDiscoveredModelIDsAreUsedVerbatimOnTheChatWire() throws {
    let models = try LocalRouterModelCatalog.decode(
      catalogBody(["glm/glm-5.3", "cx/fixture", "My combo"]))
    for model in models {
      let configuration = ProviderConfig(
        name: "Local router", apiRoot: root, modelID: model,
        credentialReference: "fixture-only", allowsLoopbackHTTP: true)
      let request = try ChatCompletionsProvider.makeRequest(
        ChatRequest(
          provider: configuration,
          turns: [ChatTurn(role: "user", content: "Fixture")], credential: Data("fixture-key".utf8))
      )
      let body = try XCTUnwrap(
        JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
      XCTAssertEqual(body["model"] as? String, model)
      XCTAssertEqual(request.url?.path, "/v1/chat/completions")
    }
  }

  func testMalformedCatalogAndInvalidIDsAreRejected() {
    for value in ["", " ", " model", "model ", "model\nkey", String(repeating: "a", count: 513)] {
      XCTAssertThrowsError(try LocalRouterModelCatalog.decode(catalogBody([value]))) {
        XCTAssertEqual($0 as? ModelCatalogError, .invalidCatalog)
      }
    }
    for body in [
      "{}", "{\"object\":\"list\",\"data\":[{}]}", "{\"object\":\"other\",\"data\":[]}", "not json",
    ] {
      XCTAssertThrowsError(try LocalRouterModelCatalog.decode(Data(body.utf8))) {
        XCTAssertEqual($0 as? ModelCatalogError, .invalidCatalog)
      }
    }
  }

  func testModelCountAndBodyLimitsAreEnforced() {
    XCTAssertThrowsError(
      try LocalRouterModelCatalog.decode(catalogBody(Array(repeating: "model", count: 2049)))
    ) {
      XCTAssertEqual($0 as? ModelCatalogError, .catalogTooLarge)
    }
    XCTAssertThrowsError(try LocalRouterModelCatalog.decode(Data(repeating: 32, count: 1_048_577)))
    {
      XCTAssertEqual($0 as? ModelCatalogError, .catalogTooLarge)
    }
  }

  func testRequestIsCredentialFreeGetAndNeverSendsConversationContent() async throws {
    CatalogFixture.shared.install { instance in
      XCTAssertEqual(instance.request.httpMethod, "GET")
      XCTAssertEqual(instance.request.url?.path, "/v1/models")
      XCTAssertNil(instance.request.httpBody)
      XCTAssertNil(instance.request.value(forHTTPHeaderField: "Authorization"))
      XCTAssertNil(instance.request.value(forHTTPHeaderField: "Cookie"))
      XCTAssertEqual(instance.request.value(forHTTPHeaderField: "Accept"), "application/json")
      instance.respond(status: 200, body: catalogBody(["glm/glm-5.3", "cx/fixture"]))
    }
    let configuration = configuration()
    configuration.httpAdditionalHeaders = [
      "Authorization": "must-not-forward", "Cookie": "must-not-forward",
    ]
    let models = try await LocalRouterModelCatalog(configuration: configuration).models(
      apiRoot: root, allowsLoopbackHTTP: true)
    XCTAssertEqual(models, ["cx/fixture", "glm/glm-5.3"])
  }

  func testHTTPFailuresDoNotExposeResponseBody() async {
    for status in [401, 403, 429, 500] {
      CatalogFixture.shared.install { instance in
        instance.respond(status: status, body: Data("private error echo".utf8))
      }
      do {
        _ = try await transport().models(apiRoot: root, allowsLoopbackHTTP: true)
        XCTFail("Expected HTTP failure")
      } catch {
        XCTAssertEqual(error as? ModelCatalogError, .http(status))
        XCTAssertFalse(error.localizedDescription.contains("private error echo"))
      }
    }
  }

  func testWrongContentTypeIsRejected() async {
    CatalogFixture.shared.install { instance in
      instance.respond(status: 200, contentType: "text/html", body: catalogBody([]))
    }
    do {
      _ = try await transport().models(apiRoot: root, allowsLoopbackHTTP: true)
      XCTFail("Expected invalid catalog")
    } catch { XCTAssertEqual(error as? ModelCatalogError, .invalidCatalog) }
  }

  func testRedirectIsRefusedRatherThanFollowingToRemoteOrigin() async {
    CatalogFixture.shared.install { instance in instance.redirect() }
    do {
      _ = try await transport().models(apiRoot: root, allowsLoopbackHTTP: true)
      XCTFail("Expected redirect rejection")
    } catch { XCTAssertEqual(error as? ProviderError, .redirectRefused) }
  }

  func testStreamingBodyLimitStopsOversizedResponse() async {
    CatalogFixture.shared.install { instance in
      instance.respond(status: 200, body: Data(repeating: 32, count: 1_048_577))
    }
    do {
      _ = try await transport().models(apiRoot: root, allowsLoopbackHTTP: true)
      XCTFail("Expected response size limit")
    } catch { XCTAssertEqual(error as? ModelCatalogError, .catalogTooLarge) }
  }

  func testCancellationStopsUnderlyingRequest() async throws {
    let started = CatalogSignal()
    let stopped = CatalogSignal()
    CatalogFixture.shared.install(
      { instance in
        instance.beginResponse(status: 200, contentType: "application/json")
        Task { await started.signal() }
      }, stopped: { Task { await stopped.signal() } })
    let transport = transport()
    let endpoint = root
    let task = Task { try await transport.models(apiRoot: endpoint, allowsLoopbackHTTP: true) }
    await started.wait()
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Cancelled lookup must not finish successfully")
    } catch { XCTAssertEqual(error as? ProviderError, .cancelled) }
    await stopped.wait()
  }

  private var root: URL { URL(string: "http://127.0.0.1:20128/v1")! }
  private func configuration() -> URLSessionConfiguration {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [CatalogURLProtocol.self]
    return config
  }
  private func transport() -> LocalRouterModelCatalog {
    LocalRouterModelCatalog(configuration: configuration())
  }
}

private func catalogBody(_ ids: [String]) -> Data {
  try! JSONSerialization.data(withJSONObject: ["object": "list", "data": ids.map { ["id": $0] }])
}

private final class CatalogURLProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() { CatalogFixture.shared.handler?(self) }
  override func stopLoading() { CatalogFixture.shared.stopped?() }
  func beginResponse(status: Int, contentType: String) {
    let response = HTTPURLResponse(
      url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": contentType])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
  }
  func respond(status: Int, contentType: String = "application/json", body: Data) {
    beginResponse(status: status, contentType: contentType)
    client?.urlProtocol(self, didLoad: body)
    client?.urlProtocolDidFinishLoading(self)
  }
  func redirect() {
    let target = URL(string: "https://must-not-contact.invalid/v1/models")!
    let response = HTTPURLResponse(
      url: request.url!, statusCode: 307, httpVersion: "HTTP/1.1",
      headerFields: ["Location": target.absoluteString])!
    client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
  }
}

private final class CatalogFixture: @unchecked Sendable {
  typealias Handler = @Sendable (CatalogURLProtocol) -> Void
  static let shared = CatalogFixture()
  private let lock = NSLock()
  private var currentHandler: Handler?
  private var currentStopped: (@Sendable () -> Void)?
  var handler: Handler? { lock.withLock { currentHandler } }
  var stopped: (@Sendable () -> Void)? { lock.withLock { currentStopped } }
  func install(_ handler: @escaping Handler, stopped: (@Sendable () -> Void)? = nil) {
    lock.withLock {
      currentHandler = handler
      currentStopped = stopped
    }
  }
}

private actor CatalogSignal {
  private var signalled = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  func wait() async {
    if signalled { return }
    await withCheckedContinuation { waiters.append($0) }
  }
  func signal() {
    signalled = true
    let pending = waiters
    waiters.removeAll()
    for waiter in pending { waiter.resume() }
  }
}
