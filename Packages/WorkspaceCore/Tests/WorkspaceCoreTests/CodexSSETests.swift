import Foundation
import XCTest

@testable import WorkspaceCore

final class CodexSSETests: XCTestCase {
  func testParsesTextAndCompletionAcrossEveryByteSplit() throws {
    let text = "สวัสดี 👩🏽‍💻"
    let stream =
      event("response.created", #"{"type":"response.created","response":{}}"#)
      + event(
        "response.output_text.delta", json(["type": "response.output_text.delta", "delta": text]))
      + event("response.completed", completion())
    let bytes = Data(stream.utf8)

    for split in 0...bytes.count {
      var parser = CodexSSEParser()
      var events = try parser.append(bytes.prefix(split))
      events += try parser.append(bytes.dropFirst(split))
      events += try parser.finish()
      XCTAssertEqual(events, [.text(text), .finished], "Failed byte split \(split)")
      XCTAssertTrue(parser.isFinished)
    }
  }

  func testAcceptsCRLFCRLFBOMCommentsAndDataOnlyEvents() throws {
    var parser = CodexSSEParser()
    let stream =
      "\u{feff}: hello\r\rdata: \(json(["type": "response.refusal.delta", "delta": "No."]))\r\r\n"
      + "event: response.completed\r\ndata: \(completion())\r\n\r\n"

    let events = try parser.append(Data(stream.utf8))

    XCTAssertEqual(events, [.text("No."), .finished])
  }

  func testReasoningLifecycleIsAcceptedButNotEmitted() throws {
    var parser = CodexSSEParser()
    let stream =
      event(
        "response.output_item.added",
        #"{"type":"response.output_item.added","item":{"type":"reasoning","summary":[]}}"#)
      + event(
        "response.reasoning_summary_part.added",
        #"{"type":"response.reasoning_summary_part.added","part":{"type":"summary_text","text":""}}"#
      )
      + event(
        "response.reasoning_summary_text.delta",
        #"{"type":"response.reasoning_summary_text.delta","delta":"private"}"#)
      + event(
        "response.reasoning_summary_text.done",
        #"{"type":"response.reasoning_summary_text.done","text":"private"}"#)
      + event(nil, json(["type": "response.output_text.delta", "delta": "answer"]))
      + event("response.output_item.done", messageItemEvent())
      + event("response.completed", completion())

    XCTAssertEqual(try parser.append(Data(stream.utf8)), [.text("answer"), .finished])
  }

  func testMessageAndRefusalPartsValidateAtCompletion() throws {
    var parser = CodexSSEParser()
    let output: [[String: Any]] = [
      ["type": "reasoning", "summary": []],
      [
        "type": "message", "role": "assistant",
        "content": [
          ["type": "output_text", "text": "answer"],
          ["type": "refusal", "refusal": "boundary"],
        ],
      ],
    ]

    let events = try parser.append(
      Data(
        (event(nil, json(["type": "response.output_text.delta", "delta": "answer"]))
          + event("response.completed", completion(output: output))).utf8))

    XCTAssertEqual(events, [.text("answer"), .finished])
  }

  func testRefusalDoneUsesRefusalField() throws {
    var parser = CodexSSEParser()
    let stream =
      event(nil, json(["type": "response.refusal.delta", "delta": "boundary"]))
      + event(
        "response.refusal.done",
        json(["type": "response.refusal.done", "refusal": "boundary"]))
      + event("response.completed", completion())

    XCTAssertEqual(try parser.append(Data(stream.utf8)), [.text("boundary"), .finished])
    assertError(
      .invalidResponse,
      event: json(["type": "response.refusal.done", "text": "wrong field"]))
  }

  func testFullTerminalWithoutAnyTextDeltaCannotCreateEmptyReply() {
    assertError(.invalidResponse, event: completion())
  }

  func testFailedIncompleteMalformedAndDoneAloneFail() {
    assertError(
      .invalidResponse, event: #"{"type":"response.failed","response":{"status":"failed"}}"#)
    assertError(
      .invalidResponse, event: #"{"type":"response.incomplete","response":{"status":"incomplete"}}"#
    )
    assertError(.invalidResponse, event: "not-json")
    assertError(.invalidResponse, event: "[DONE]")
  }

  func testCompletionRequiresCompletedStatusAndVerifiedMessage() {
    assertError(
      .invalidResponse,
      event: json(["type": "response.completed", "response": ["status": "failed", "output": []]]))
    assertError(
      .invalidResponse,
      event: json(["type": "response.completed", "response": ["status": "completed"]]))
    assertError(
      .invalidResponse,
      event: json([
        "type": "response.completed",
        "response": ["id": "", "status": "completed", "output": messageOutput()],
      ]))
    assertError(
      .invalidResponse,
      event: completion(output: [["type": "reasoning", "summary": []]]))

    var priorMessageParser = CodexSSEParser()
    assertProviderError(.invalidResponse) {
      _ = try priorMessageParser.append(
        Data(
          (event("response.output_item.done", messageItemEvent())
            + event("response.completed", completion(output: []))).utf8))
    }
  }

  func testToolFunctionAndNonTextItemsFailClosed() {
    for itemType in [
      "function_call", "custom_tool_call", "web_search_call", "image_generation_call",
    ] {
      assertError(
        .unsupportedContent,
        event: json(["type": "response.output_item.done", "item": ["type": itemType]]))
    }
    assertError(
      .unsupportedContent,
      event: json(["type": "response.function_call_arguments.delta", "delta": "{}"]),
      named: "response.function_call_arguments.delta")
    assertError(
      .unsupportedContent,
      event: json(["type": "response.content_part.added", "part": ["type": "image"]]))
  }

  func testTerminalMayOmitRepeatedMessageOnlyAfterTextAndValidatedMessageDone() throws {
    let text = event(nil, json(["type": "response.output_text.delta", "delta": "answer"]))
    let done = event("response.output_item.done", messageItemEvent())
    let terminal = event("response.completed", completion(output: []))
    let bytes = Data((text + done + terminal).utf8)
    for split in 0...bytes.count {
      var parser = CodexSSEParser()
      var events = try parser.append(bytes.prefix(split))
      events += try parser.append(bytes.dropFirst(split))
      events += try parser.finish()
      XCTAssertEqual(events, [.text("answer"), .finished])
    }
    let added = done.replacingOccurrences(
      of: "response.output_item.done", with: "response.output_item.added")
    let reasoningDone = event(
      nil, json(["type": "response.output_item.done", "item": ["type": "reasoning"]]))
    let emptyMessage = event(
      "response.completed",
      completion(output: [["type": "message", "role": "assistant", "content": []]]))
    for stream in [
      text + terminal, done + terminal, terminal, text + added + terminal,
      text + reasoningDone + terminal, emptyMessage,
    ] {
      var parser = CodexSSEParser()
      assertProviderError(.invalidResponse) { _ = try parser.append(Data(stream.utf8)) }
    }
    var tool = CodexSSEParser()
    assertProviderError(.unsupportedContent) {
      _ = try tool.append(
        Data(
          (text + done
            + event(
              "response.completed",
              completion(output: [["type": "function_call"]]))).utf8))
    }
  }

  func testReasoningSummaryPartRequiresTypedTextPart() {
    assertError(
      .invalidResponse,
      event: json(["type": "response.reasoning_summary_part.added", "summary_index": 0]))
    assertError(
      .unsupportedContent,
      event: json([
        "type": "response.reasoning_summary_part.added",
        "part": ["type": "summary_text"],
      ]))
  }

  func testUnknownEventAndMismatchedEventNameFailClosed() {
    assertError(.invalidResponse, event: #"{"type":"response.future_event"}"#)

    var parser = CodexSSEParser()
    assertProviderError(.invalidResponse) {
      _ = try parser.append(
        Data(event("response.created", #"{"type":"response.in_progress","response":{}}"#).utf8))
    }
  }

  func testMalformedUTF8AndEarlyEOFFail() throws {
    var invalidUTF8 = CodexSSEParser()
    assertProviderError(.invalidResponse) {
      _ = try invalidUTF8.append(Data([0x64, 0x61, 0x74, 0x61, 0x3a, 0x20, 0xff, 0x0a]))
    }

    var early = CodexSSEParser()
    _ = try early.append(
      Data(
        event(
          "response.output_text.delta", #"{"type":"response.output_text.delta","delta":"partial"}"#
        ).utf8))
    assertProviderError(.streamEnded) { _ = try early.finish() }
  }

  func testLineAndCombinedEventOverOneMiBFail() throws {
    var lineParser = CodexSSEParser()
    assertProviderError(.outputLimit) {
      _ = try lineParser.append(Data(repeating: 65, count: 1_048_577))
    }

    var eventParser = CodexSSEParser()
    _ = try eventParser.append(
      Data(("data: " + String(repeating: "a", count: 600_000) + "\n").utf8))
    assertProviderError(.outputLimit) {
      _ = try eventParser.append(
        Data(("data: " + String(repeating: "b", count: 600_000) + "\n").utf8))
    }
  }

  func testAggregateTextOverFourMiBFails() throws {
    var parser = CodexSSEParser()
    let delta = String(repeating: "a", count: 900_000)
    let payload = Data(
      event(nil, json(["type": "response.output_text.delta", "delta": delta])).utf8)
    for _ in 0..<4 { _ = try parser.append(payload) }
    assertProviderError(.outputLimit) { _ = try parser.append(payload) }
  }

  func testOverallWireOverSixteenMiBFailsEvenForComments() throws {
    var parser = CodexSSEParser()
    let comment = Data((":" + String(repeating: "a", count: 1_000_000) + "\n").utf8)
    for _ in 0..<16 { _ = try parser.append(comment) }
    assertProviderError(.outputLimit) { _ = try parser.append(comment) }
  }

  private func event(_ name: String?, _ payload: String) -> String {
    (name.map { "event: \($0)\n" } ?? "") + "data: \(payload)\n\n"
  }

  private func messageItemEvent() -> String {
    json([
      "type": "response.output_item.done",
      "item": [
        "type": "message", "role": "assistant",
        "content": [["type": "output_text", "text": "answer"]],
      ],
    ])
  }

  private func completion(output: [[String: Any]]? = nil) -> String {
    json([
      "type": "response.completed",
      "response": [
        "id": "resp_fixture",
        "status": "completed",
        "output": output ?? messageOutput(),
      ],
    ])
  }

  private func messageOutput() -> [[String: Any]] {
    [
      [
        "type": "message", "role": "assistant",
        "content": [["type": "output_text", "text": "answer"]],
      ]
    ]
  }

  private func json(_ object: Any) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
  }

  private func assertError(
    _ expected: ProviderError, event payload: String, named name: String? = nil,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    var parser = CodexSSEParser()
    assertProviderError(expected, file: file, line: line) {
      _ = try parser.append(Data(event(name, payload).utf8))
    }
  }

  private func assertProviderError(
    _ expected: ProviderError, file: StaticString = #filePath, line: UInt = #line,
    operation: () throws -> Void
  ) {
    do {
      try operation()
      XCTFail("Expected \(expected)", file: file, line: line)
    } catch {
      XCTAssertEqual(error as? ProviderError, expected, file: file, line: line)
    }
  }
}
