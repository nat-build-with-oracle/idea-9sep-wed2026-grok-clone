import Foundation

public protocol RouterModelCatalog: Sendable {
  func models(apiRoot: URL, allowsLoopbackHTTP: Bool) async throws -> [String]
}

public enum ModelCatalogError: Error, Sendable, Equatable, LocalizedError {
  case localEndpointRequired, invalidCatalog, catalogTooLarge
  case http(Int)
  public var errorDescription: String? {
    switch self {
    case .localEndpointRequired:
      "Discovery is only available for a loopback router. Explicitly enable HTTP for a local HTTP URL, or enter the model ID manually."
    case .invalidCatalog:
      "The router returned an unsupported model list. Enter the exact model ID manually."
    case .catalogTooLarge:
      "The router's model list exceeded the discovery limit. Enter the exact model ID manually."
    case .http(401), .http(403):
      "The router denied model discovery. No credential was sent. Enter the model ID from its dashboard manually."
    case .http(let code):
      "Model discovery failed (HTTP \(code)). No chat was sent."
    }
  }
}

/// Opt-in, credential-free discovery for a user-managed local 9router-compatible gateway.
/// Configuration is copied and never changed after initialization.
public final class LocalRouterModelCatalog: RouterModelCatalog, @unchecked Sendable {
  private let configuration: URLSessionConfiguration
  private static let byteLimit = 1_048_576
  private static let modelLimit = 2_048

  public init(configuration: URLSessionConfiguration = .ephemeral) {
    self.configuration = configuration.copy() as! URLSessionConfiguration
    self.configuration.httpCookieStorage = nil
    self.configuration.httpShouldSetCookies = false
    self.configuration.urlCache = nil
    self.configuration.urlCredentialStorage = nil
    self.configuration.httpAdditionalHeaders = nil
    self.configuration.timeoutIntervalForRequest = 15
    self.configuration.timeoutIntervalForResource = 15
  }

  public static func endpoint(apiRoot: URL, allowsLoopbackHTTP: Bool) throws -> URL {
    let provider = ProviderConfig(
      name: "Local model discovery", apiRoot: apiRoot, modelID: "catalog",
      credentialReference: "no-credential", allowsLoopbackHTTP: allowsLoopbackHTTP)
    guard (try? DomainValidation.provider(provider)) != nil,
      var components = URLComponents(url: apiRoot, resolvingAgainstBaseURL: false),
      let host = components.host?.lowercased(),
      ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)
    else { throw ModelCatalogError.localEndpointRequired }
    while components.path.hasSuffix("/") { components.path.removeLast() }
    if components.path.hasSuffix("/chat/completions") {
      components.path.removeLast("/chat/completions".count)
    }
    if !components.path.hasSuffix("/models") { components.path += "/models" }
    guard let url = components.url else { throw ModelCatalogError.localEndpointRequired }
    return url
  }

  public func models(apiRoot: URL, allowsLoopbackHTTP: Bool) async throws -> [String] {
    let endpoint = try Self.endpoint(apiRoot: apiRoot, allowsLoopbackHTTP: allowsLoopbackHTTP)
    try Task.checkCancellation()
    var request = URLRequest(url: endpoint)
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.cachePolicy = .reloadIgnoringLocalCacheData
    let redirects = CatalogRedirectGuard()
    let session = URLSession(configuration: configuration, delegate: redirects, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    do {
      let (bytes, response) = try await session.bytes(for: request)
      if redirects.wasRedirected { throw ProviderError.redirectRefused }
      guard let http = response as? HTTPURLResponse else { throw ModelCatalogError.invalidCatalog }
      guard (200...299).contains(http.statusCode) else {
        throw ModelCatalogError.http(http.statusCode)
      }
      guard http.mimeType?.lowercased() == "application/json" else {
        throw ModelCatalogError.invalidCatalog
      }
      guard http.expectedContentLength <= Self.byteLimit else {
        throw ModelCatalogError.catalogTooLarge
      }
      var body = Data()
      for try await byte in bytes {
        try Task.checkCancellation()
        guard body.count < Self.byteLimit else { throw ModelCatalogError.catalogTooLarge }
        body.append(byte)
      }
      try Task.checkCancellation()
      return try Self.decode(body)
    } catch {
      if redirects.wasRedirected { throw ProviderError.redirectRefused }
      if let error = error as? ModelCatalogError { throw error }
      throw ProviderError.sanitized(error)
    }
  }

  static func decode(_ body: Data) throws -> [String] {
    guard body.count <= byteLimit else { throw ModelCatalogError.catalogTooLarge }
    struct Catalog: Decodable {
      struct Model: Decodable { let id: String }
      let object: String
      let data: [Model]
    }
    let catalog: Catalog
    do { catalog = try JSONDecoder().decode(Catalog.self, from: body) } catch {
      throw ModelCatalogError.invalidCatalog
    }
    guard catalog.object == "list" else { throw ModelCatalogError.invalidCatalog }
    guard catalog.data.count <= modelLimit else { throw ModelCatalogError.catalogTooLarge }
    guard
      catalog.data.allSatisfy({ model in
        !model.id.isEmpty && model.id.utf8.count <= 512
          && model.id == model.id.trimmingCharacters(in: .whitespacesAndNewlines)
          && !model.id.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
          })
      })
    else { throw ModelCatalogError.invalidCatalog }
    // IDs are opaque wire values. Preserve prefixes/case; selection remains the user's action.
    return Array(Set(catalog.data.map(\.id))).sorted()
  }
}

private final class CatalogRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private var redirected = false
  var wasRedirected: Bool { lock.withLock { redirected } }
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    lock.withLock { redirected = true }
    completionHandler(nil)
    task.cancel()
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler:
      @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    answer(challenge, completionHandler: completionHandler)
  }

  func urlSession(
    _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
    completionHandler:
      @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    answer(challenge, completionHandler: completionHandler)
  }

  private func answer(
    _ challenge: URLAuthenticationChallenge,
    completionHandler:
      @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    // Validate normal HTTPS server trust, but never answer an HTTP/client-identity challenge.
    if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
      completionHandler(.performDefaultHandling, nil)
    } else {
      completionHandler(.cancelAuthenticationChallenge, nil)
    }
  }
}
