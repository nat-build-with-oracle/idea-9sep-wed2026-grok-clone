import AppKit
import SwiftUI
import XCTest

@testable import NativeShell

@MainActor
final class ThemeTests: XCTestCase {
  func testDarkAppearancePreservesOriginalCorePalette() throws {
    let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))

    assertHex(ShellTheme.backgroundNSColor, equals: 0x070707, under: dark)
    assertHex(ShellTheme.sidebarNSColor, equals: 0x111111, under: dark)
    assertHex(ShellTheme.bubbleNSColor, equals: 0x262626, under: dark)
    assertHex(ShellTheme.selectedNSColor, equals: 0x353535, under: dark)
    assertHex(ShellTheme.composerNSColor, equals: 0x2d2d2d, under: dark)
    assertHex(ShellTheme.secondaryNSColor, equals: 0xababab, under: dark)
    assertHex(ShellTheme.foregroundNSColor, equals: 0xf3f3f3, under: dark)
    assertHex(ShellTheme.separatorNSColor, equals: 0x292929, under: dark)
    assertHex(ShellTheme.accentNSColor, equals: 0x3295f6, under: dark)
  }

  func testLightAppearanceUsesDesignContractPalette() throws {
    let light = try XCTUnwrap(NSAppearance(named: .aqua))

    assertHex(ShellTheme.backgroundNSColor, equals: 0xfafafa, under: light)
    assertHex(ShellTheme.sidebarNSColor, equals: 0xf1f2f4, under: light)
    assertHex(ShellTheme.bubbleNSColor, equals: 0xe8e9eb, under: light)
    assertHex(ShellTheme.selectedNSColor, equals: 0xd8dadf, under: light)
    assertHex(ShellTheme.composerNSColor, equals: 0xe7e8ea, under: light)
    assertHex(ShellTheme.secondaryNSColor, equals: 0x5c6066, under: light)
    assertHex(ShellTheme.foregroundNSColor, equals: 0x1b1c1e, under: light)
    assertHex(ShellTheme.separatorNSColor, equals: 0xcdd0d5, under: light)
    assertHex(ShellTheme.accentNSColor, equals: 0x0068d9, under: light)
  }

  func testSemanticColorsResolveDifferentlyForDarkAndLightAppearances() throws {
    let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
    let light = try XCTUnwrap(NSAppearance(named: .aqua))

    XCTAssertNotEqual(
      rgb(ShellTheme.backgroundNSColor, under: dark),
      rgb(ShellTheme.backgroundNSColor, under: light))
    XCTAssertNotEqual(
      rgb(ShellTheme.foregroundNSColor, under: dark),
      rgb(ShellTheme.foregroundNSColor, under: light))
  }

  func testLightForegroundAndSecondaryTextHaveReadableBackgroundContrast() throws {
    let light = try XCTUnwrap(NSAppearance(named: .aqua))
    let background = rgb(ShellTheme.backgroundNSColor, under: light)

    XCTAssertGreaterThanOrEqual(
      contrastRatio(rgb(ShellTheme.foregroundNSColor, under: light), background), 7)
    XCTAssertGreaterThanOrEqual(
      contrastRatio(rgb(ShellTheme.secondaryNSColor, under: light), background), 4.5)
    XCTAssertGreaterThanOrEqual(
      contrastRatio(rgb(ShellTheme.warningNSColor, under: light), background), 4.5)
  }

  func testComposerAppearanceChangeKeepsViewContentAndSelectionWhenAppKitCommitsMarkedText()
    async throws
  {
    _ = NSApplication.shared
    let model = ThemeComposerModel()
    let hostingView = NSHostingView(rootView: AnyView(ThemeComposerHarness(model: model)))
    hostingView.frame = NSRect(x: 0, y: 0, width: 400, height: 100)
    let window = NSWindow(
      contentRect: hostingView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
    window.contentView = hostingView
    hostingView.layoutSubtreeIfNeeded()
    let textView = try XCTUnwrap(findTextView(in: hostingView))
    XCTAssertTrue(window.makeFirstResponder(textView))
    textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
    textView.setMarkedText(
      " composing", selectedRange: NSRange(location: 10, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0))
    let content = textView.string
    let selection = textView.selectedRange()
    let markedRange = textView.markedRange()
    XCTAssertTrue(textView.hasMarkedText())

    let light = try XCTUnwrap(NSAppearance(named: .aqua))
    window.appearance = light
    hostingView.layoutSubtreeIfNeeded()
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async { continuation.resume() }
    }

    XCTAssertIdentical(findTextView(in: hostingView), textView)
    XCTAssertEqual(textView.string, content)
    XCTAssertEqual(textView.selectedRange(), selection)
    // AppKit may commit composition on appearance changes. Do not require that OS quirk,
    // or synthesize a new composition; if retained, the original marked range must survive.
    if textView.hasMarkedText() { XCTAssertEqual(textView.markedRange(), markedRange) }
    XCTAssertEqual(model.submitCount, 0)
    XCTAssertEqual(textView.textColor, ShellTheme.foregroundNSColor)
    XCTAssertEqual(textView.insertionPointColor, ShellTheme.foregroundNSColor)
    XCTAssertEqual(
      rgb(try XCTUnwrap(textView.textColor), under: light),
      rgb(ShellTheme.foregroundNSColor, under: light))

    window.makeFirstResponder(nil)
    window.contentView = nil
    hostingView.removeFromSuperview()
    window.close()
  }

  private func assertHex(
    _ color: NSColor, equals expected: UInt32, under appearance: NSAppearance,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let actual = rgb(color, under: appearance)
    XCTAssertEqual(
      actual.red, CGFloat((expected >> 16) & 255) / 255, accuracy: 0.000_001, file: file, line: line
    )
    XCTAssertEqual(
      actual.green, CGFloat((expected >> 8) & 255) / 255, accuracy: 0.000_001, file: file,
      line: line)
    XCTAssertEqual(
      actual.blue, CGFloat(expected & 255) / 255, accuracy: 0.000_001, file: file, line: line)
  }

  private func rgb(_ color: NSColor, under appearance: NSAppearance) -> RGB {
    var resolved: NSColor?
    appearance.performAsCurrentDrawingAppearance {
      resolved = color.usingColorSpace(.sRGB)
    }
    guard let resolved else { return RGB(red: 0, green: 0, blue: 0) }
    return RGB(
      red: resolved.redComponent, green: resolved.greenComponent, blue: resolved.blueComponent)
  }

  private func contrastRatio(_ first: RGB, _ second: RGB) -> CGFloat {
    let lighter = max(first.luminance, second.luminance)
    let darker = min(first.luminance, second.luminance)
    return (lighter + 0.05) / (darker + 0.05)
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
private final class ThemeComposerModel: ObservableObject {
  @Published var text = "draft"
  @Published var height: CGFloat = 36
  @Published var focusRequest = -1
  var submitCount = 0
}

private struct ThemeComposerHarness: View {
  @ObservedObject var model: ThemeComposerModel

  var body: some View {
    NativeComposer(text: $model.text, height: $model.height, focusRequest: model.focusRequest) {
      model.submitCount += 1
    }
    .frame(width: 400, height: model.height)
  }
}

private struct RGB: Equatable {
  let red: CGFloat
  let green: CGFloat
  let blue: CGFloat

  var luminance: CGFloat {
    0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
  }

  private func linear(_ component: CGFloat) -> CGFloat {
    component <= 0.04045
      ? component / 12.92
      : pow((component + 0.055) / 1.055, 2.4)
  }
}
