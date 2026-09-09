import Foundation

public struct StreamTimeouts: Sendable {
  public let firstEvent: TimeInterval
  public let idle: TimeInterval
  public let total: TimeInterval
  public init(firstEvent: TimeInterval = 30, idle: TimeInterval = 60, total: TimeInterval = 300) {
    self.firstEvent = max(0.01, firstEvent)
    self.idle = max(0.01, idle)
    self.total = max(0.01, total)
  }
}

/// URLSession configuration is copied once and never mutated after publication.
public final class ChatCompletionsProvider: ChatProvider, @unchecked Sendable {
  private let configuration: URLSessionConfiguration
  private let timeouts: StreamTimeouts
  public init(
    configuration: URLSessionConfiguration = .ephemeral, timeouts: StreamTimeouts = StreamTimeouts()
  ) {
    self.configuration = configuration.copy() as! URLSessionConfiguration
    self.configuration.httpCookieStorage = nil
    self.configuration.httpShouldSetCookies = false
    self.configuration.urlCache = nil
    self.timeouts = timeouts
  }

  public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
    AsyncThrowingStream { continuation in
      do {
        let urlRequest = try Self.makeRequest(request)
        let stream = SessionStream(
          configuration: configuration, request: urlRequest,
          timeouts: timeouts, continuation: continuation)
        continuation.onTermination = { [weak stream] _ in stream?.cancel() }
        stream.start()
      } catch { continuation.finish(throwing: error) }
    }
  }

  static func makeRequest(_ input: ChatRequest) throws -> URLRequest {
    let url = try ProviderEndpoint.chatCompletions(input.provider)
    guard let key = String(data: input.credential, encoding: .utf8), !key.isEmpty,
      key.count <= 16_384, !key.contains(where: { $0.isNewline || $0 == "\0" })
    else {
      throw ProviderError.invalidCredential
    }
    guard !input.turns.isEmpty,
      input.turns.allSatisfy({ ["system", "user", "assistant"].contains($0.role) })
    else {
      throw ProviderError.invalidResponse
    }
    struct Body: Encodable {
      let model: String
      let messages: [ChatTurn]
      let stream = true
      let n = 1
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    request.httpBody = try JSONEncoder().encode(
      Body(model: input.provider.modelID, messages: input.turns))
    request.cachePolicy = .reloadIgnoringLocalCacheData
    return request
  }
}

/// All mutable parser/session state is confined to `queue`, including delegate callbacks and timers.
private final class SessionStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let queue = DispatchQueue(label: "BotWorkspace.provider-stream")
  private let configuration: URLSessionConfiguration
  private let request: URLRequest
  private let timeouts: StreamTimeouts
  private let continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
  private var session: URLSession?
  private var task: URLSessionDataTask?
  private var parser = ChatSSEParser()
  private var finished = false
  private var responseAccepted = false
  private var eventTimer: DispatchWorkItem?
  private var totalTimer: DispatchWorkItem?

  init(
    configuration: URLSessionConfiguration, request: URLRequest, timeouts: StreamTimeouts,
    continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
  ) {
    self.configuration = configuration.copy() as! URLSessionConfiguration
    self.request = request
    self.timeouts = timeouts
    self.continuation = continuation
  }
  func start() {
    queue.async {
      guard !self.finished else { return }
      let delegateQueue = OperationQueue()
      delegateQueue.maxConcurrentOperationCount = 1
      delegateQueue.underlyingQueue = self.queue
      self.configuration.timeoutIntervalForRequest = self.timeouts.idle
      self.configuration.timeoutIntervalForResource = self.timeouts.total
      let session = URLSession(
        configuration: self.configuration, delegate: self, delegateQueue: delegateQueue)
      self.session = session
      self.task = session.dataTask(with: self.request)
      self.armEventTimer(self.timeouts.firstEvent)
      let timer = DispatchWorkItem { [weak self] in self?.finish(ProviderError.timedOut) }
      self.totalTimer = timer
      self.queue.asyncAfter(deadline: .now() + self.timeouts.total, execute: timer)
      self.task?.resume()
    }
  }
  func cancel() { queue.async { self.finish(ProviderError.cancelled) } }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    // Refuse all redirects, rather than risk forwarding a credential or downgrading TLS.
    completionHandler(nil)
    finish(ProviderError.redirectRefused)
  }
  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    guard !finished, let http = response as? HTTPURLResponse else {
      completionHandler(.cancel)
      finish(ProviderError.invalidResponse)
      return
    }
    guard (200...299).contains(http.statusCode) else {
      completionHandler(.cancel)
      finish(ProviderError.http(http.statusCode))
      return
    }
    guard http.mimeType?.lowercased() == "text/event-stream" else {
      completionHandler(.cancel)
      finish(ProviderError.invalidResponse)
      return
    }
    responseAccepted = true
    completionHandler(.allow)
  }
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard !finished, responseAccepted else { return }
    do { try deliver(parser.append(data)) } catch { finish(error) }
  }
  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard !finished else { return }
    if let error {
      finish(ProviderError.sanitized(error))
      return
    }
    do {
      try deliver(parser.finish())
      if !finished { finish(nil) }
    } catch { finish(error) }
  }
  private func deliver(_ events: [ChatEvent]) throws {
    for event in events where !finished {
      continuation.yield(event)
      if event == .finished { finish(nil) } else { armEventTimer(timeouts.idle) }
    }
  }
  private func armEventTimer(_ duration: TimeInterval) {
    eventTimer?.cancel()
    let timer = DispatchWorkItem { [weak self] in self?.finish(ProviderError.timedOut) }
    eventTimer = timer
    queue.asyncAfter(deadline: .now() + duration, execute: timer)
  }
  private func finish(_ error: Error?) {
    guard !finished else { return }
    finished = true
    eventTimer?.cancel()
    totalTimer?.cancel()
    if let error { continuation.finish(throwing: error) } else { continuation.finish() }
    task?.cancel()
    session?.invalidateAndCancel()
    task = nil
    session = nil
  }
}
