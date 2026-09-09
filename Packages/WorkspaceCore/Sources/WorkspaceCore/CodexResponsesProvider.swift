import Foundation

/// Experimental implementation-level compatibility, not a supported public API guarantee.
/// No endpoint override, refresh owner, tool interpreter, cookie jar, or persistent credential.
public final class CodexResponsesProvider: ChatProvider, @unchecked Sendable {
  public static let apiRoot = URL(string: "https://chatgpt.com/backend-api/codex")!
  public static let endpoint = URL(string: "https://chatgpt.com/backend-api/codex/responses")!
  private let configuration: URLSessionConfiguration
  private let timeouts: StreamTimeouts

  public init(
    configuration: URLSessionConfiguration = .ephemeral, timeouts: StreamTimeouts = StreamTimeouts()
  ) {
    self.configuration = configuration.copy() as! URLSessionConfiguration
    self.timeouts = timeouts
  }

  public static func validateConfiguration(_ provider: ProviderConfig) throws {
    guard provider.kind == .codexResponses,
      provider.apiRoot.absoluteString == apiRoot.absoluteString,
      !provider.allowsLoopbackHTTP,
      CodexSessionCredential.isReference(provider.credentialReference),
      !provider.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      provider.modelID.utf8.count <= 512,
      !provider.modelID.contains(where: { $0.isNewline || $0 == "\0" })
    else { throw WorkspaceError.invalidProvider }
  }

  public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
    AsyncThrowingStream { continuation in
      do {
        let urlRequest = try Self.makeRequest(request)
        let stream = SessionStream(
          configuration: configuration, request: urlRequest, timeouts: timeouts,
          continuation: continuation, kind: .codexResponses)
        continuation.onTermination = { [weak stream] _ in stream?.cancel() }
        stream.start()
      } catch { continuation.finish(throwing: error) }
    }
  }

  static func makeRequest(_ input: ChatRequest) throws -> URLRequest {
    _ = try DomainValidation.provider(input.provider)
    try validateConfiguration(input.provider)
    let credential = try CodexSessionCredential(sessionData: input.credential)
    guard !input.turns.isEmpty,
      input.turns.allSatisfy({ ["system", "user", "assistant"].contains($0.role) }),
      input.turns.contains(where: { $0.role == "user" })
    else { throw ProviderError.invalidResponse }
    struct Content: Encodable {
      let type: String
      let text: String
    }
    struct InputMessage: Encodable {
      let type = "message"
      let role: String
      let content: [Content]
    }
    struct Reasoning: Encodable { let effort = "low" }
    struct Body: Encodable {
      let model: String
      let instructions: String
      let input: [InputMessage]
      let tools: [String] = []
      let toolChoice = "none"
      let parallelToolCalls = false
      let store = false
      let stream = true
      let reasoning = Reasoning()
      enum CodingKeys: String, CodingKey {
        case model, instructions, input, tools, store, stream, reasoning
        case toolChoice = "tool_choice"
        case parallelToolCalls = "parallel_tool_calls"
      }
    }
    let messages = input.turns.filter { $0.role != "system" }.map { turn in
      InputMessage(
        role: turn.role,
        content: [
          Content(type: turn.role == "assistant" ? "output_text" : "input_text", text: turn.content)
        ])
    }
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
    if let accountID = credential.accountID {
      request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
    }
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    request.setValue("BotWorkspace/0.1", forHTTPHeaderField: "User-Agent")
    request.setValue("botworkspace", forHTTPHeaderField: "originator")
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.httpShouldHandleCookies = false
    request.httpBody = try JSONEncoder().encode(
      Body(
        model: input.provider.modelID,
        instructions: input.turns.filter { $0.role == "system" }.map(\.content).joined(
          separator: "\n\n"),
        input: messages))
    return request
  }
}

/// Dispatch and preflight share a provider-kind boundary; mocks can still implement ChatProvider.
public struct ProviderRouter: ChatProvider {
  private let chat: ChatCompletionsProvider
  private let codex: CodexResponsesProvider
  public init(
    configuration: URLSessionConfiguration = .ephemeral, timeouts: StreamTimeouts = StreamTimeouts()
  ) {
    chat = ChatCompletionsProvider(configuration: configuration, timeouts: timeouts)
    codex = CodexResponsesProvider(configuration: configuration, timeouts: timeouts)
  }
  public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
    switch request.provider.kind {
    case .chatCompletions: chat.stream(request)
    case .codexResponses: codex.stream(request)
    }
  }
  static func makeRequest(_ request: ChatRequest) throws -> URLRequest {
    switch request.provider.kind {
    case .chatCompletions: try ChatCompletionsProvider.makeRequest(request)
    case .codexResponses: try CodexResponsesProvider.makeRequest(request)
    }
  }
}
