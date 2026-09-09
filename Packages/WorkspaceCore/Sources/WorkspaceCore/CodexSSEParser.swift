import Foundation

/// Incremental, text-only decoder for the fixed-origin Codex Responses stream.
///
/// The parser deliberately accepts only the response and reasoning lifecycle used by this app.
/// Tool, function, and otherwise unknown events fail closed rather than being interpreted.
public struct CodexSSEParser: Sendable {
  private static let maximumLineBytes = 1_048_576
  private static let maximumEventBytes = 1_048_576
  private static let maximumOutputBytes = 4_194_304
  private static let maximumWireBytes = 16_777_216

  private var line = Data()
  private var eventName: String?
  private var dataLines: [String] = []
  private var eventBytes = 0
  private var wireBytes = 0
  private var outputBytes = 0
  private var completedTextMessageSeen = false
  private var skipLF = false
  private var firstLine = true
  public private(set) var isFinished = false

  public init() {}

  public mutating func append(_ data: Data) throws -> [ChatEvent] {
    guard !isFinished else { return [] }
    wireBytes += data.count
    guard wireBytes <= Self.maximumWireBytes else { throw ProviderError.outputLimit }

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
        guard line.count <= Self.maximumLineBytes else { throw ProviderError.outputLimit }
      }
    }
    return result
  }

  public mutating func finish() throws -> [ChatEvent] {
    var events: [ChatEvent] = []
    if !line.isEmpty { events += try consumeLine() }
    if eventName != nil || !dataLines.isEmpty { events += try dispatchEvent() }
    guard isFinished else { throw ProviderError.streamEnded }
    return events
  }

  private mutating func consumeLine() throws -> [ChatEvent] {
    let byteCount = line.count
    guard var text = String(data: line, encoding: .utf8) else {
      throw ProviderError.invalidResponse
    }
    line.removeAll(keepingCapacity: true)
    if firstLine {
      firstLine = false
      if text.first == "\u{feff}" { text.removeFirst() }
    }
    if text.isEmpty { return try dispatchEvent() }
    if text.hasPrefix(":") { return [] }

    eventBytes += byteCount
    guard eventBytes <= Self.maximumEventBytes else { throw ProviderError.outputLimit }

    let field: Substring
    var value: Substring
    if let separator = text.firstIndex(of: ":") {
      field = text[..<separator]
      value = text[text.index(after: separator)...]
      if value.first == " " { value = value.dropFirst() }
    } else {
      field = Substring(text)
      value = ""
    }

    switch field {
    case "event":
      guard !value.isEmpty, eventName == nil else { throw ProviderError.invalidResponse }
      eventName = String(value)
    case "data":
      dataLines.append(String(value))
    default:
      throw ProviderError.invalidResponse
    }
    return []
  }

  private mutating func dispatchEvent() throws -> [ChatEvent] {
    defer {
      eventName = nil
      dataLines.removeAll(keepingCapacity: true)
      eventBytes = 0
    }
    guard !isFinished else { return [] }
    guard !dataLines.isEmpty else {
      if eventName == nil { return [] }
      throw ProviderError.invalidResponse
    }

    let payload = dataLines.joined(separator: "\n")
    guard payload != "[DONE]", let data = payload.data(using: .utf8) else {
      throw ProviderError.invalidResponse
    }
    let object: [String: Any]
    do {
      guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ProviderError.invalidResponse
      }
      object = decoded
    } catch let error as ProviderError {
      throw error
    } catch {
      throw ProviderError.invalidResponse
    }

    guard let type = object["type"] as? String, !type.isEmpty else {
      throw ProviderError.invalidResponse
    }
    if let eventName, eventName != type { throw ProviderError.invalidResponse }

    switch type {
    case "response.output_text.delta", "response.refusal.delta":
      guard let delta = object["delta"] as? String else { throw ProviderError.invalidResponse }
      return try emit(delta)

    case "response.output_item.added", "response.output_item.done":
      guard let item = object["item"] as? [String: Any] else {
        throw ProviderError.invalidResponse
      }
      try validateOutputItem(item)
      if type == "response.output_item.done", hasNonemptyMessageText(item) {
        completedTextMessageSeen = true
      }
      return []

    case "response.created", "response.in_progress", "response.queued":
      guard object["response"] is [String: Any] else { throw ProviderError.invalidResponse }
      return []

    case "response.content_part.added", "response.content_part.done":
      guard let part = object["part"] as? [String: Any], let partType = part["type"] as? String
      else { throw ProviderError.invalidResponse }
      guard partType == "output_text" || partType == "refusal" else {
        throw ProviderError.unsupportedContent
      }
      return []

    case "response.output_text.done":
      guard object["text"] is String else { throw ProviderError.invalidResponse }
      return []

    case "response.refusal.done":
      guard object["refusal"] is String else { throw ProviderError.invalidResponse }
      return []

    case "response.reasoning_summary_part.added", "response.reasoning_summary_part.done":
      guard let part = object["part"] as? [String: Any] else {
        throw ProviderError.invalidResponse
      }
      guard part["type"] as? String == "summary_text", part["text"] is String else {
        throw ProviderError.unsupportedContent
      }
      return []

    case "response.reasoning_summary_text.delta", "response.reasoning_summary_text.done",
      "response.reasoning_text.delta", "response.reasoning_text.done":
      guard (object["delta"] as? String) != nil || (object["text"] as? String) != nil else {
        throw ProviderError.invalidResponse
      }
      return []

    case "response.completed":
      try validateCompletion(object)
      isFinished = true
      return [.finished]

    case "response.failed", "response.incomplete":
      throw ProviderError.invalidResponse

    default:
      if type.contains("tool") || type.contains("function") {
        throw ProviderError.unsupportedContent
      }
      throw ProviderError.invalidResponse
    }
  }

  private mutating func emit(_ text: String) throws -> [ChatEvent] {
    guard !text.isEmpty else { return [] }
    outputBytes += text.utf8.count
    guard outputBytes <= Self.maximumOutputBytes else { throw ProviderError.outputLimit }
    return [.text(text)]
  }

  private mutating func validateCompletion(_ event: [String: Any]) throws {
    guard let response = event["response"] as? [String: Any],
      let responseID = response["id"] as? String, !responseID.isEmpty,
      response["status"] as? String == "completed",
      let output = response["output"] as? [[String: Any]]
    else { throw ProviderError.invalidResponse }

    var completionHasMessage = false
    for item in output {
      try validateOutputItem(item)
      if hasNonemptyMessageText(item) { completionHasMessage = true }
    }
    // Codex can omit repeated message items in its terminal output array. A prior explicit
    // supported message-done event plus actual emitted text is required in that case;
    // a text delta alone, an empty completed event, [DONE], or EOF cannot complete a reply.
    guard outputBytes > 0, completionHasMessage || completedTextMessageSeen else {
      throw ProviderError.invalidResponse
    }
  }

  private mutating func validateOutputItem(_ item: [String: Any]) throws {
    guard let type = item["type"] as? String else { throw ProviderError.invalidResponse }
    switch type {
    case "message":
      guard item["role"] as? String == "assistant",
        let content = item["content"] as? [[String: Any]]
      else { throw ProviderError.invalidResponse }
      for part in content {
        guard let partType = part["type"] as? String else { throw ProviderError.invalidResponse }
        switch partType {
        case "output_text":
          guard part["text"] is String else { throw ProviderError.invalidResponse }
        case "refusal":
          guard (part["refusal"] as? String) != nil || (part["text"] as? String) != nil else {
            throw ProviderError.invalidResponse
          }
        default:
          throw ProviderError.unsupportedContent
        }
      }
    case "reasoning":
      // Reasoning is allowed as lifecycle metadata but is never exposed as assistant text.
      return
    default:
      throw ProviderError.unsupportedContent
    }
  }

  private func hasNonemptyMessageText(_ item: [String: Any]) -> Bool {
    guard item["type"] as? String == "message",
      let content = item["content"] as? [[String: Any]]
    else { return false }
    return content.contains { !(($0["text"] ?? $0["refusal"]) as? String ?? "").isEmpty }
  }
}
