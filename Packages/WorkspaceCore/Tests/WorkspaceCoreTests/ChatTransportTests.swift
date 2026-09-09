import Foundation
import XCTest

@testable import WorkspaceCore

final class ChatTransportTests: XCTestCase {
  func testEndpointAppendsChatCompletionsExactlyOnce() throws {
    for root in [
      "https://example.test/v1", "https://example.test/v1/",
      "https://example.test/v1/chat/completions/",
    ] {
      let endpoint = try ProviderEndpoint.chatCompletions(provider(apiRoot: root))

      XCTAssertEqual(endpoint.absoluteString, "https://example.test/v1/chat/completions")
    }
  }

  func testEndpointRejectsUnsafeProviderURLs() {
    let unsafeRoots = [
      "http://example.test/v1", "https://user:secret@example.test/v1",
      "https://example.test/v1?token=secret", "https://example.test/v1#fragment",
    ]

    for root in unsafeRoots {
      XCTAssertThrowsError(try ProviderEndpoint.chatCompletions(provider(apiRoot: root))) {
        XCTAssertEqual($0 as? WorkspaceError, .invalidProvider)
      }
    }
  }

  func testRequestContainsRequiredHeadersAndJSONBody() throws {
    let input = ChatRequest(
      provider: provider(apiRoot: "https://example.test/v1"),
      turns: [
        ChatTurn(role: "system", content: "Be concise"), ChatTurn(role: "user", content: "Hello"),
      ],
      credential: Data("test-key".utf8))

    let request = try ChatCompletionsProvider.makeRequest(input)
    let body = try XCTUnwrap(
      JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
    let messages = try XCTUnwrap(body["messages"] as? [[String: String]])

    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
    XCTAssertEqual(body["model"] as? String, "test-model")
    XCTAssertEqual(body["stream"] as? Bool, true)
    XCTAssertEqual(body["n"] as? Int, 1)
    XCTAssertEqual(
      messages,
      [["role": "system", "content": "Be concise"], ["role": "user", "content": "Hello"]])
  }

  func testStreamsSSEChunksFromURLProtocol() async throws {
    URLProtocolFixture.shared.install { protocolInstance in
      protocolInstance.respond(
        status: 200, contentType: "text/event-stream; charset=utf-8",
        chunks: [
          Data("data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"".utf8),
          Data("hello".utf8),
          Data("\"},\"finish_reason\":null}]}\n\ndata: [DONE]\n\n".utf8),
        ])
    }
    let transport = ChatCompletionsProvider(configuration: fixtureConfiguration())

    let events = try await collect(transport.stream(validRequest()))

    XCTAssertEqual(events, [.text("hello"), .finished])
  }

  func testHTTPErrorStatusesAreReportedWithoutParsingBody() async {
    for status in [400, 401, 403, 429, 500] {
      URLProtocolFixture.shared.install { protocolInstance in
        protocolInstance.respond(
          status: status, contentType: "application/json",
          chunks: [Data("credential echo must be ignored".utf8)])
      }
      let transport = ChatCompletionsProvider(configuration: fixtureConfiguration())

      await assertProviderError(.http(status)) {
        _ = try await self.collect(transport.stream(self.validRequest()))
      }
    }
  }

  func testNonEventStreamContentTypeIsRejected() async {
    URLProtocolFixture.shared.install { protocolInstance in
      protocolInstance.respond(status: 200, contentType: "application/json", chunks: [])
    }
    let transport = ChatCompletionsProvider(configuration: fixtureConfiguration())

    await assertProviderError(.invalidResponse) {
      _ = try await self.collect(transport.stream(self.validRequest()))
    }
  }

  func testRedirectIsRefusedBeforeFollowingLocation() async {
    URLProtocolFixture.shared.install { protocolInstance in
      protocolInstance.redirect(
        to: URL(string: "https://redirected.example.test/chat/completions")!)
    }
    let transport = ChatCompletionsProvider(configuration: fixtureConfiguration())

    await assertProviderError(.redirectRefused) {
      _ = try await self.collect(transport.stream(self.validRequest()))
    }
  }

  func testCancellingConsumerCancelsUnderlyingURLLoad() async {
    let started = AsyncSignal()
    let stopped = AsyncSignal()
    URLProtocolFixture.shared.install(
      handler: { protocolInstance in
        Task { await started.signal() }
        protocolInstance.beginResponse(status: 200, contentType: "text/event-stream")
      },
      stopped: { Task { await stopped.signal() } })
    let transport = ChatCompletionsProvider(configuration: fixtureConfiguration())
    let stream = transport.stream(validRequest())
    let collection = Task {
      var events: [ChatEvent] = []
      for try await event in stream { events.append(event) }
      return events
    }
    await started.wait()

    collection.cancel()
    let events = (try? await collection.value) ?? []
    await stopped.wait()

    XCTAssertTrue(collection.isCancelled)
    XCTAssertTrue(events.isEmpty)
  }

  private func provider(apiRoot: String) -> ProviderConfig {
    ProviderConfig(
      name: "Fixture", apiRoot: URL(string: apiRoot)!, modelID: "test-model",
      credentialReference: "fixture-reference")
  }

  private func validRequest() -> ChatRequest {
    ChatRequest(
      provider: provider(apiRoot: "https://example.test/v1"),
      turns: [ChatTurn(role: "user", content: "Hello")], credential: Data("test-key".utf8))
  }

  private func fixtureConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [FixtureURLProtocol.self]
    return configuration
  }

  private func collect(_ stream: AsyncThrowingStream<ChatEvent, Error>) async throws -> [ChatEvent]
  {
    var events: [ChatEvent] = []
    for try await event in stream { events.append(event) }
    return events
  }

  private func assertProviderError(
    _ expected: ProviderError, operation: () async throws -> Void, file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    do {
      try await operation()
      XCTFail("Expected \(expected)", file: file, line: line)
    } catch {
      XCTAssertEqual(error as? ProviderError, expected, file: file, line: line)
    }
  }
}

private final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let handler = URLProtocolFixture.shared.handler() else {
      client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
      return
    }
    handler(self)
  }

  override func stopLoading() {
    URLProtocolFixture.shared.stoppedHandler()?()
  }

  func beginResponse(status: Int, contentType: String) {
    let response = HTTPURLResponse(
      url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": contentType])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
  }

  func respond(status: Int, contentType: String, chunks: [Data]) {
    beginResponse(status: status, contentType: contentType)
    for chunk in chunks { client?.urlProtocol(self, didLoad: chunk) }
    client?.urlProtocolDidFinishLoading(self)
  }

  func redirect(to url: URL) {
    let response = HTTPURLResponse(
      url: request.url!, statusCode: 307, httpVersion: "HTTP/1.1",
      headerFields: ["Location": url.absoluteString])!
    client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: url), redirectResponse: response)
  }
}

private final class URLProtocolFixture: @unchecked Sendable {
  typealias Handler = @Sendable (FixtureURLProtocol) -> Void
  static let shared = URLProtocolFixture()
  private let lock = NSLock()
  private var currentHandler: Handler?
  private var currentStoppedHandler: (@Sendable () -> Void)?

  func install(handler: @escaping Handler, stopped: (@Sendable () -> Void)? = nil) {
    lock.withLock {
      currentHandler = handler
      currentStoppedHandler = stopped
    }
  }

  func handler() -> Handler? { lock.withLock { currentHandler } }
  func stoppedHandler() -> (@Sendable () -> Void)? { lock.withLock { currentStoppedHandler } }
}

private actor AsyncSignal {
  private var isSignalled = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    if isSignalled { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func signal() {
    isSignalled = true
    let pending = waiters
    waiters.removeAll()
    for waiter in pending { waiter.resume() }
  }
}
