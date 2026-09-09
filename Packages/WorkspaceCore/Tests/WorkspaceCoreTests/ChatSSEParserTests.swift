import Foundation
import XCTest

@testable import WorkspaceCore

final class ChatSSEParserTests: XCTestCase {
  func testParsesEventAcrossEverySingleByteSplitBoundary() throws {
    let expectedText = "สวัสดี 👩🏽‍💻"
    let bytes = Data((chunk(content: expectedText) + "\n\ndata: [DONE]\n\n").utf8)

    for split in 0...bytes.count {
      var parser = ChatSSEParser()
      var events = try parser.append(bytes.prefix(split))
      events += try parser.append(bytes.dropFirst(split))
      events += try parser.finish()
      XCTAssertEqual(events, [.text(expectedText), .finished], "Failed byte split \(split)")
    }
  }

  func testParsesUTF8WhenFedOneByteAtATime() throws {
    let expectedText = "ไทย 日本語 🚀"
    let bytes = Data((chunk(content: expectedText) + "\r\rdata: [DONE]\r\r").utf8)
    var parser = ChatSSEParser()
    var events: [ChatEvent] = []

    for byte in bytes {
      events += try parser.append(Data([byte]))
    }

    XCTAssertEqual(events, [.text(expectedText), .finished])
  }

  func testAcceptsLFCRAndCRLFEventBoundaries() throws {
    for newline in ["\n", "\r", "\r\n"] {
      var parser = ChatSSEParser()
      let stream = chunk(content: newline) + newline + newline + "data: [DONE]" + newline + newline

      let events = try parser.append(Data(stream.utf8))

      XCTAssertEqual(
        events, [.text(newline), .finished], "Failed newline style \(newline.debugDescription)")
    }
  }

  func testIgnoresBOMAndCommentLines() throws {
    var parser = ChatSSEParser()
    let stream =
      "\u{feff}: keepalive\ndata: \(chunkPayload(content: "hello"))\n\n: ping\ndata: [DONE]\n\n"

    let events = try parser.append(Data(stream.utf8))

    XCTAssertEqual(events, [.text("hello"), .finished])
  }

  func testFinishReasonAndFollowingDoneEmitOnlyOneTerminalEvent() throws {
    var parser = ChatSSEParser()
    let stream = chunk(content: "complete", finishReason: "stop") + "\n\ndata: [DONE]\n\n"

    var events = try parser.append(Data(stream.utf8))
    events += try parser.finish()

    XCTAssertEqual(events, [.text("complete"), .finished])
    XCTAssertTrue(parser.isFinished)
  }

  func testMalformedJSONThrowsInvalidResponse() {
    var parser = ChatSSEParser()

    assertProviderError(.invalidResponse) {
      _ = try parser.append(Data("data: {not-json}\n\n".utf8))
    }
  }

  func testMalformedUTF8ThrowsInvalidResponseAtLineBoundary() {
    var parser = ChatSSEParser()

    assertProviderError(.invalidResponse) {
      _ = try parser.append(Data([0x64, 0x61, 0x74, 0x61, 0x3a, 0x20, 0xff, 0x0a]))
    }
  }

  func testEarlyEOFThrowsStreamEnded() {
    var parser = ChatSSEParser()

    assertProviderError(.streamEnded) {
      _ = try parser.append(Data((chunk(content: "partial") + "\n\n").utf8))
      _ = try parser.finish()
    }
  }

  func testToolCallsThrowUnsupportedContent() {
    var parser = ChatSSEParser()
    let payload =
      #"data: {"choices":[{"index":0,"delta":{"tool_calls":[{}]},"finish_reason":null}]}"#

    assertProviderError(.unsupportedContent) {
      _ = try parser.append(Data((payload + "\n\n").utf8))
    }
  }

  func testFunctionCallThrowsUnsupportedContent() {
    var parser = ChatSSEParser()
    let payload =
      #"data: {"choices":[{"index":0,"delta":{"function_call":{}},"finish_reason":null}]}"#

    assertProviderError(.unsupportedContent) {
      _ = try parser.append(Data((payload + "\n\n").utf8))
    }
  }

  func testLengthFinishReasonThrowsOutputLimit() {
    var parser = ChatSSEParser()

    assertProviderError(.outputLimit) {
      _ = try parser.append(Data((chunk(content: "partial", finishReason: "length") + "\n\n").utf8))
    }
  }

  func testUnsupportedFinishReasonThrowsUnsupportedContent() {
    var parser = ChatSSEParser()

    assertProviderError(.unsupportedContent) {
      _ = try parser.append(
        Data((chunk(content: "partial", finishReason: "content_filter") + "\n\n").utf8))
    }
  }

  func testSingleLineOverOneMiBThrowsOutputLimit() {
    var parser = ChatSSEParser()
    let oversized = Data(repeating: 65, count: 1_048_577)

    assertProviderError(.outputLimit) {
      _ = try parser.append(oversized)
    }
  }

  func testCombinedDataLinesOverOneMiBThrowOutputLimit() throws {
    var parser = ChatSSEParser()
    let first = Data(("data: " + String(repeating: "a", count: 600_000) + "\n").utf8)
    let second = Data(("data: " + String(repeating: "b", count: 600_000) + "\n").utf8)
    _ = try parser.append(first)

    assertProviderError(.outputLimit) {
      _ = try parser.append(second)
    }
  }

  func testAggregateTextOverFourMiBThrowsOutputLimit() throws {
    var parser = ChatSSEParser()
    let text = String(repeating: "a", count: 900_000)
    let event = Data((chunk(content: text) + "\n\n").utf8)

    for _ in 0..<4 { _ = try parser.append(event) }
    assertProviderError(.outputLimit) {
      _ = try parser.append(event)
    }
  }

  private func chunk(content: String, finishReason: String? = nil) -> String {
    "data: \(chunkPayload(content: content, finishReason: finishReason))"
  }

  private func chunkPayload(content: String, finishReason: String? = nil) -> String {
    let contentData = try! JSONEncoder().encode(content)
    let encodedContent = String(decoding: contentData, as: UTF8.self)
    let reason = finishReason.map { "\"\($0)\"" } ?? "null"
    return
      "{\"choices\":[{\"index\":0,\"delta\":{\"content\":\(encodedContent)},\"finish_reason\":\(reason)}]}"
  }

  private func assertProviderError(
    _ expected: ProviderError, operation: () throws -> Void, file: StaticString = #filePath,
    line: UInt = #line
  ) {
    do {
      try operation()
      XCTFail("Expected \(expected)", file: file, line: line)
    } catch {
      XCTAssertEqual(error as? ProviderError, expected, file: file, line: line)
    }
  }
}
