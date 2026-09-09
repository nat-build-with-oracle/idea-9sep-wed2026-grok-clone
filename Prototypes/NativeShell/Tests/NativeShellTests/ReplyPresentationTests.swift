import XCTest

@testable import NativeShell

@MainActor
final class ReplyPresentationTests: XCTestCase {
  func testAvailableReplyDescribesSenderAndOnlyProvidedExcerpt() throws {
    let workspace = PreviewWorkspace()
    let conversationID = try XCTUnwrap(workspace.selectedID)
    let message = try XCTUnwrap(workspace.messages[conversationID]?.dropFirst().first)
    let presentation = ReplyPresentation(ReplyPreview(message: message))

    XCTAssertEqual(
      presentation.accessibilityLabel,
      "Reply to You: Show me an example of a daily project check-in.")
  }

  func testUnavailableReplyDoesNotExposeStaleSenderOrExcerpt() {
    let presentation = ReplyPresentation(
      ReplyPreview(
        id: UUID(), speakerName: "/private/sensitive/source", excerpt: "stale full message",
        isAvailable: false))

    XCTAssertEqual(presentation.accessibilityLabel, "Original message unavailable")
  }

  func testPendingReplyUsesExplicitLoadingDescription() {
    let presentation = ReplyPresentation(
      ReplyPreview(
        id: UUID(), speakerName: "Original message", excerpt: "Loading original message…",
        isAvailable: false, isLoading: true))

    XCTAssertEqual(presentation, ReplyPresentation.loading)
    XCTAssertEqual(presentation.accessibilityLabel, "Loading original message")
  }
}
