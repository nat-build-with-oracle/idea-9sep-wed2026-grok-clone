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

@MainActor
private final class ComposerModel: ObservableObject {
  @Published var text: String
  @Published var height: CGFloat = 36
  @Published var focusRequest = -1
  @Published var isEnabled = true
  var submitCount = 0

  init(text: String) {
    self.text = text
  }
}

private struct ComposerHarness: View {
  @ObservedObject var model: ComposerModel

  var body: some View {
    NativeComposer(
      text: $model.text, height: $model.height, focusRequest: model.focusRequest
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
