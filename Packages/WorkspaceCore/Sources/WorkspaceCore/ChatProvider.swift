import Foundation

public struct ChatTurn: Codable, Sendable, Equatable {
  public let role: String
  public let content: String
  public init(role: String, content: String) {
    self.role = role
    self.content = content
  }
}

public struct ChatRequest: Sendable {
  public let provider: ProviderConfig
  public let turns: [ChatTurn]
  /// Memory-only. Never Codable, persisted, logged, or included in error descriptions.
  public let credential: Data
  public init(provider: ProviderConfig, turns: [ChatTurn], credential: Data) {
    self.provider = provider
    self.turns = turns
    self.credential = credential
  }
}

public enum ChatEvent: Sendable, Equatable {
  case text(String)
  case finished
}

public protocol ChatProvider: Sendable {
  func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error>
}

public enum ProviderError: Error, Sendable, Equatable, LocalizedError {
  case missingCredential, invalidCredential
  case keychain(Int32)
  case invalidResponse, streamEnded
  case http(Int)
  case redirectRefused, timedOut, offline, cancelled, unsupportedContent, outputLimit,
    storageFailure
  public var errorDescription: String? {
    switch self {
    case .missingCredential: "No API key is saved for this provider. Open Settings to add one."
    case .invalidCredential: "The API key must be a nonempty single-line value."
    case .keychain(-34018):
      "This build lacks an authorized Keychain signing profile. Use a properly signed build; no plaintext key was saved."
    case .keychain(let status):
      "Keychain is unavailable (\(status)). No plaintext credential was saved."
    case .invalidResponse: "The provider returned an unsupported or malformed streaming response."
    case .streamEnded:
      "The connection ended before the reply finished. Retry explicitly to continue."
    case .http(401), .http(403):
      "The provider rejected the API key or account access. Check Settings."
    case .http(429): "The provider rate limit was reached. Wait before retrying."
    case .http(let code): "The provider request failed (HTTP \(code))."
    case .redirectRefused:
      "The provider redirected the request. Set the final API root in Settings."
    case .timedOut: "The provider timed out. The partial reply is preserved."
    case .offline: "The provider could not be reached. Check your connection and API root."
    case .cancelled: "Reply stopped."
    case .unsupportedContent:
      "The provider returned tools or non-text output that this adapter does not support."
    case .outputLimit: "The reply exceeded this app's output limit. The partial reply is preserved."
    case .storageFailure: "The reply could not be saved. Check available storage and permissions."
    }
  }
  public static func sanitized(_ error: Error) -> ProviderError {
    if let error = error as? ProviderError { return error }
    if error is CancellationError { return .cancelled }
    if let error = error as? URLError {
      if error.code == .cancelled { return .cancelled }
      if error.code == .timedOut { return .timedOut }
    }
    return .offline
  }
}

public enum ProviderEndpoint {
  public static func chatCompletions(_ provider: ProviderConfig) throws -> URL {
    let provider = try DomainValidation.provider(provider)
    guard var components = URLComponents(url: provider.apiRoot, resolvingAgainstBaseURL: false)
    else {
      throw WorkspaceError.invalidProvider
    }
    while components.path.hasSuffix("/") { components.path.removeLast() }
    if !components.path.hasSuffix("/chat/completions") { components.path += "/chat/completions" }
    guard let result = components.url else { throw WorkspaceError.invalidProvider }
    return result
  }
}

/// Incremental SSE decoder. UTF-8 is decoded only after a full line; CR, LF and CRLF are accepted.
public struct ChatSSEParser: Sendable {
  private var line = Data()
  private var eventLines: [String] = []
  private var eventBytes = 0
  private var skipLF = false
  private var firstLine = true
  public private(set) var isFinished = false
  private var outputBytes = 0
  public init() {}

  public mutating func append(_ data: Data) throws -> [ChatEvent] {
    var result: [ChatEvent] = []
    for byte in data {
      if isFinished { break }
      if skipLF {
        skipLF = false
        if byte == 10 { continue }
      }
      if byte == 10 || byte == 13 {
        result += try consumeLine()
        skipLF = byte == 13
      } else {
        line.append(byte)
        guard line.count <= 1_048_576 else { throw ProviderError.outputLimit }
      }
    }
    return result
  }

  public mutating func finish() throws -> [ChatEvent] {
    var events: [ChatEvent] = []
    if !line.isEmpty { events += try consumeLine() }
    if !eventLines.isEmpty { events += try dispatchEvent() }
    guard isFinished else { throw ProviderError.streamEnded }
    return events
  }

  private mutating func consumeLine() throws -> [ChatEvent] {
    guard var text = String(data: line, encoding: .utf8) else {
      throw ProviderError.invalidResponse
    }
    line.removeAll(keepingCapacity: true)
    if firstLine {
      firstLine = false
      if text.first == "\u{feff}" { text.removeFirst() }
    }
    if text.isEmpty { return try dispatchEvent() }
    if text.hasPrefix("data:") {
      var value = String(text.dropFirst(5))
      if value.first == " " { value.removeFirst() }
      eventBytes += value.utf8.count
      guard eventBytes <= 1_048_576 else { throw ProviderError.outputLimit }
      eventLines.append(value)
    }
    return []
  }

  private mutating func dispatchEvent() throws -> [ChatEvent] {
    guard !eventLines.isEmpty, !isFinished else { return [] }
    let payload = eventLines.joined(separator: "\n")
    eventLines.removeAll(keepingCapacity: true)
    eventBytes = 0
    if payload == "[DONE]" {
      isFinished = true
      return [.finished]
    }
    let chunk: Chunk
    do { chunk = try JSONDecoder().decode(Chunk.self, from: Data(payload.utf8)) } catch {
      throw ProviderError.invalidResponse
    }
    guard chunk.error == nil else { throw ProviderError.invalidResponse }
    var result: [ChatEvent] = []
    for choice in chunk.choices ?? [] where choice.index == 0 {
      guard choice.delta?.toolCalls == nil, choice.delta?.functionCall == nil else {
        throw ProviderError.unsupportedContent
      }
      let text = choice.delta?.content ?? choice.delta?.refusal ?? ""
      if !text.isEmpty {
        outputBytes += text.utf8.count
        guard outputBytes <= 4_194_304 else { throw ProviderError.outputLimit }
        result.append(.text(text))
      }
      if let reason = choice.finishReason {
        guard reason == "stop" else {
          throw reason == "length" ? ProviderError.outputLimit : ProviderError.unsupportedContent
        }
        isFinished = true
        result.append(.finished)
      }
    }
    return result
  }

  private struct IgnoredObject: Decodable, Sendable {}
  private struct Chunk: Decodable {
    let choices: [Choice]?
    let error: IgnoredObject?
  }
  private struct Choice: Decodable {
    let index: Int
    let delta: Delta?
    let finishReason: String?
    enum CodingKeys: String, CodingKey {
      case index, delta
      case finishReason = "finish_reason"
    }
  }
  private struct Delta: Decodable {
    let content: String?
    let refusal: String?
    let toolCalls: [IgnoredObject]?
    let functionCall: IgnoredObject?
    enum CodingKeys: String, CodingKey {
      case content, refusal
      case toolCalls = "tool_calls"
      case functionCall = "function_call"
    }
  }
}
