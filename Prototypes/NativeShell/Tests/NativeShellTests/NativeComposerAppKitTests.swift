import AppKit
import SwiftUI
import XCTest

@testable import NativeShell

@MainActor
final class NativeComposerAppKitTests: XCTestCase {
  func testHostedComposerConfiguresAPlainTextUndoableAccessibleTextView() async throws {
    var fixture: ComposerFixture? = try makeHostedComposer(text: "draft")
    await drainMainQueue()

    XCTAssertFalse(try XCTUnwrap(fixture?.textView).isRichText)
    XCTAssertTrue(try XCTUnwrap(fixture?.textView).allowsUndo)
    XCTAssertFalse(try XCTUnwrap(fixture?.textView).importsGraphics)
    XCTAssertEqual(
      try XCTUnwrap(fixture?.textView).accessibilityIdentifier(), "message-composer")
    XCTAssertEqual(try XCTUnwrap(fixture?.textView).accessibilityLabel(), "Message composer")

    tearDownHostedComposer(&fixture)
    await drainMainQueue()
  }

  func testHostedComposerPreservesMarkedTextDuringAnExternalSwiftUIUpdate() async throws {
    var fixture: ComposerFixture? = try makeHostedComposer(text: "draft")
    await drainMainQueue()
    let textView = try XCTUnwrap(fixture?.textView)
    textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
    textView.setMarkedText(
      " composing", selectedRange: NSRange(location: 10, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0))
    let textDuringComposition = textView.string
    XCTAssertTrue(textView.hasMarkedText())

    let model = try XCTUnwrap(fixture?.model)
    model.text = "external replacement"
    try XCTUnwrap(fixture?.hostingView).rootView = AnyView(ComposerHarness(model: model))
    try XCTUnwrap(fixture?.hostingView).layoutSubtreeIfNeeded()
    await drainMainQueue()

    XCTAssertEqual(textView.string, textDuringComposition)
    XCTAssertTrue(textView.hasMarkedText())

    textView.unmarkText()
    tearDownHostedComposer(&fixture)
    await drainMainQueue()
  }

  func testHostedComposerBecomesReadOnlyWhenEnvironmentIsDisabled() async throws {
    var fixture: ComposerFixture? = try makeHostedComposer(text: "draft")
    await drainMainQueue()
    XCTAssertTrue(try XCTUnwrap(fixture?.textView).isEditable)

    let model = try XCTUnwrap(fixture?.model)
    model.isEnabled = false
    try XCTUnwrap(fixture?.hostingView).rootView = AnyView(ComposerHarness(model: model))
    try XCTUnwrap(fixture?.hostingView).layoutSubtreeIfNeeded()
    await drainMainQueue()

    XCTAssertFalse(try XCTUnwrap(fixture?.textView).isEditable)
    tearDownHostedComposer(&fixture)
    await drainMainQueue()
  }

  func testReplacingHostedComposerWithPickerContentDismantlesTextViewWithoutCrash() async throws {
    var fixture: ComposerFixture? = try makeHostedComposer(text: "draft")
    await drainMainQueue()
    XCTAssertNotNil(try XCTUnwrap(fixture?.hostingView).subviews.first)

    try XCTUnwrap(fixture?.hostingView).rootView = AnyView(Text("Recipient picker"))
    try XCTUnwrap(fixture?.hostingView).layoutSubtreeIfNeeded()
    await drainMainQueue()

    XCTAssertNil(findTextView(in: try XCTUnwrap(fixture?.hostingView)))
    tearDownHostedComposer(&fixture)
    await drainMainQueue()
  }

  func testInsertionAtCaretAddsSeparatorsUsesNativeUndoAndProcessesIDOnce() async throws {
    var fixture: ComposerFixture? = try makeHostedComposer(text: "HelloWorld")
    await drainMainQueue()
    let active = try XCTUnwrap(fixture)
    XCTAssertTrue(active.window.makeFirstResponder(active.textView))
    active.textView.setSelectedRange(NSRange(location: 5, length: 0))
    let command = ComposerInsertion(
      conversationID: active.model.conversationID!, contextGeneration: 7,
      expectedText: "HelloWorld", text: "@\"Research Partner\"")
    active.model.contextGeneration = 7
    active.model.insertion = command
    render(active)
    await drainMainQueue()

    XCTAssertEqual(active.textView.string, "Hello @\"Research Partner\" World")
    XCTAssertEqual(active.model.text, "Hello @\"Research Partner\" World")
    XCTAssertEqual(active.model.insertionResults, [command.id: true])
    active.textView.undoManager?.undo()
    XCTAssertEqual(active.textView.string, "HelloWorld")
    XCTAssertEqual(active.model.text, "HelloWorld")

    render(active)
    await drainMainQueue()
    XCTAssertEqual(active.textView.string, "HelloWorld")
    XCTAssertEqual(active.model.insertionResultCount, 1)
    tearDownHostedComposer(&fixture)
  }

  func testInsertionSeparatesFromURLAndEscapePrefixes() async throws {
    for prefix in ["https://", "\\", "("] {
      var fixture: ComposerFixture? = try makeHostedComposer(text: prefix)
      await drainMainQueue()
      let active = try XCTUnwrap(fixture)
      active.textView.setSelectedRange(NSRange(location: prefix.utf16.count, length: 0))
      let command = ComposerInsertion(
        conversationID: active.model.conversationID!, contextGeneration: 0,
        expectedText: prefix, text: "@\"Reviewer\"")
      active.model.insertion = command
      render(active)
      await drainMainQueue()
      XCTAssertEqual(active.textView.string, "\(prefix) @\"Reviewer\"")
      XCTAssertEqual(active.model.insertionResults[command.id], true)
      tearDownHostedComposer(&fixture)
    }
  }

  func testInsertionReplacesSelectionWithoutAddingRedundantSpaces() async throws {
    var fixture: ComposerFixture? = try makeHostedComposer(text: "Hello old world")
    await drainMainQueue()
    let active = try XCTUnwrap(fixture)
    active.textView.setSelectedRange(NSRange(location: 6, length: 3))
    let command = ComposerInsertion(
      conversationID: active.model.conversationID!, contextGeneration: 0,
      expectedText: "Hello old world", text: "@\"Reviewer\"")
    active.model.insertion = command
    render(active)
    await drainMainQueue()

    XCTAssertEqual(active.textView.string, "Hello @\"Reviewer\" world")
    XCTAssertEqual(active.textView.selectedRange().location, 17)
    XCTAssertEqual(active.model.insertionResults[command.id], true)
    tearDownHostedComposer(&fixture)
  }

  func testInsertionRejectsMarkedTextWithoutChangingComposition() async throws {
    var fixture: ComposerFixture? = try makeHostedComposer(text: "draft")
    await drainMainQueue()
    let active = try XCTUnwrap(fixture)
    active.textView.setSelectedRange(NSRange(location: 5, length: 0))
    active.textView.setMarkedText(
      " composing", selectedRange: NSRange(location: 10, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0))
    await drainMainQueue()
    let composed = active.textView.string
    let command = ComposerInsertion(
      conversationID: active.model.conversationID!, contextGeneration: 0,
      expectedText: composed, text: "@\"Bot\"")
    active.model.text = composed
    active.model.insertion = command
    render(active)
    await drainMainQueue()

    XCTAssertTrue(active.textView.hasMarkedText())
    XCTAssertEqual(active.textView.string, composed)
    XCTAssertEqual(active.model.insertionResults[command.id], false)
    active.textView.unmarkText()
    tearDownHostedComposer(&fixture)
  }

  func testInsertionRejectsStaleConversationReconnectAndBody() async throws {
    for stale in StaleInsertionCase.allCases {
      var fixture: ComposerFixture? = try makeHostedComposer(text: "draft")
      await drainMainQueue()
      let active = try XCTUnwrap(fixture)
      let command = ComposerInsertion(
        conversationID: active.model.conversationID!, contextGeneration: 3,
        expectedText: "draft", text: "@\"Bot\"")
      active.model.contextGeneration = 3
      active.model.insertion = command
      render(active)
      switch stale {
      case .conversation: active.model.conversationID = UUID()
      case .reconnect: active.model.contextGeneration = 4
      case .body: active.model.text = "newer draft"
      }
      render(active)
      await drainMainQueue()

      XCTAssertEqual(active.model.insertionResults[command.id], false, "case: \(stale)")
      XCTAssertEqual(active.textView.string, stale == .body ? "newer draft" : "draft")
      tearDownHostedComposer(&fixture)
      await drainMainQueue()
    }
  }

  func testInsertionRejectsDisabledComposer() async throws {
    var fixture: ComposerFixture? = try makeHostedComposer(text: "draft")
    await drainMainQueue()
    let active = try XCTUnwrap(fixture)
    let command = ComposerInsertion(
      conversationID: active.model.conversationID!, contextGeneration: 0,
      expectedText: "draft", text: "@\"Bot\"")
    active.model.isEnabled = false
    active.model.insertion = command
    render(active)
    await drainMainQueue()

    XCTAssertFalse(active.textView.isEditable)
    XCTAssertEqual(active.textView.string, "draft")
    XCTAssertEqual(active.model.insertionResults[command.id], false)
    tearDownHostedComposer(&fixture)
  }

  func testCoordinatorDoesNotRouteASelectorWithoutACurrentKeyDownEvent() {
    _ = NSApplication.shared
    var submitCount = 0
    let composer = NativeComposer(
      text: .constant(""), height: .constant(36), focusRequest: 0
    ) {
      submitCount += 1
    }
    let coordinator = composer.makeCoordinator()
    let textView = NSTextView(frame: .zero)

    XCTAssertNotEqual(NSApp.currentEvent?.type, .keyDown)
    XCTAssertFalse(
      coordinator.textView(textView, doCommandBy: #selector(NSResponder.insertNewline(_:))))
    XCTAssertEqual(submitCount, 0)
  }

  private func makeHostedComposer(text: String) throws -> ComposerFixture {
    _ = NSApplication.shared
    let model = ComposerModel(text: text)
    let hostingView = NSHostingView(rootView: AnyView(ComposerHarness(model: model)))
    hostingView.frame = NSRect(x: 0, y: 0, width: 500, height: 160)
    let window = NSWindow(
      contentRect: hostingView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hostingView
    hostingView.layoutSubtreeIfNeeded()
    let textView = try XCTUnwrap(findTextView(in: hostingView))
    return ComposerFixture(
      model: model, hostingView: hostingView, window: window, textView: textView)
  }

  private func tearDownHostedComposer(_ fixture: inout ComposerFixture?) {
    guard let activeFixture = fixture else { return }
    activeFixture.window.makeFirstResponder(nil)
    activeFixture.window.orderOut(nil)
    activeFixture.window.contentView = nil
    activeFixture.hostingView.removeFromSuperview()
    activeFixture.window.close()
    fixture = nil
  }

  private func render(_ fixture: ComposerFixture) {
    fixture.hostingView.rootView = AnyView(ComposerHarness(model: fixture.model))
    fixture.hostingView.layoutSubtreeIfNeeded()
  }

  private func drainMainQueue() async {
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async { continuation.resume() }
    }
  }

  private func findTextView(in view: NSView) -> NSTextView? {
    if let textView = view as? NSTextView { return textView }
    for subview in view.subviews {
      if let textView = findTextView(in: subview) { return textView }
    }
    return nil
  }
}

private enum StaleInsertionCase: CaseIterable { case conversation, reconnect, body }

@MainActor
private final class ComposerModel: ObservableObject {
  @Published var text: String
  @Published var height: CGFloat = 36
  @Published var focusRequest = -1
  @Published var isEnabled = true
  @Published var conversationID: UUID? = UUID()
  @Published var contextGeneration = 0
  @Published var insertion: ComposerInsertion?
  var submitCount = 0
  var insertionResults: [UUID: Bool] = [:]
  var insertionResultCount = 0

  init(text: String) {
    self.text = text
  }
}

private struct ComposerHarness: View {
  @ObservedObject var model: ComposerModel

  var body: some View {
    NativeComposer(
      text: $model.text, height: $model.height, focusRequest: model.focusRequest,
      conversationID: model.conversationID, contextGeneration: model.contextGeneration,
      insertion: model.insertion,
      onInsertionResult: { id, result in
        model.insertionResultCount += 1
        model.insertionResults[id] = result
      }
    ) {
      model.submitCount += 1
    }
    .frame(width: 500, height: model.height)
    .disabled(!model.isEnabled)
  }
}

@MainActor
private struct ComposerFixture {
  let model: ComposerModel
  let hostingView: NSHostingView<AnyView>
  let window: NSWindow
  let textView: NSTextView
}
