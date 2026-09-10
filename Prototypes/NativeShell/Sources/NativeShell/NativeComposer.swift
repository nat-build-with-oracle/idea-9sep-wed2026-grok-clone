import AppKit
import SwiftUI

struct NativeComposer: NSViewRepresentable {
  @Binding var text: String
  @Binding var height: CGFloat
  var focusRequest: Int
  var conversationID: UUID? = nil
  var contextGeneration = 0
  var insertion: ComposerInsertion? = nil
  var onInsertionResult: (UUID, Bool) -> Void = { _, _ in }
  var onSubmit: () -> Void

  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.borderType = .noBorder
    let view = NSTextView(frame: .zero)
    view.isRichText = false
    view.isEditable = context.environment.isEnabled
    view.allowsUndo = true
    view.importsGraphics = false
    view.drawsBackground = false
    view.font = .systemFont(ofSize: 16)
    applyTheme(to: view)
    view.isVerticallyResizable = true
    view.isHorizontallyResizable = false
    view.autoresizingMask = [.width]
    view.textContainerInset = NSSize(width: 0, height: 7)
    view.textContainer?.widthTracksTextView = true
    view.textContainer?.lineFragmentPadding = 0
    view.isAutomaticQuoteSubstitutionEnabled = false
    view.delegate = context.coordinator
    view.setAccessibilityLabel("Message composer")
    view.setAccessibilityIdentifier("message-composer")
    scroll.documentView = view
    context.coordinator.textView = view
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let view = scroll.documentView as? NSTextView else { return }
    view.isEditable = context.environment.isEnabled
    context.coordinator.parent = self
    // Avoid resetting selection and disrupting marked text on unrelated SwiftUI updates.
    if view.string != text && !view.hasMarkedText() { view.string = text }
    if context.coordinator.lastFocus != focusRequest {
      context.coordinator.lastFocus = focusRequest
      DispatchQueue.main.async { [weak view] in view?.window?.makeFirstResponder(view) }
    }
    context.coordinator.scheduleInsertionIfNeeded()
    context.coordinator.measure()
  }

  private func applyTheme(to view: NSTextView) {
    // Install adaptive colors once. Reassigning them during updates can interrupt marked text.
    view.textColor = ShellTheme.foregroundNSColor
    view.insertionPointColor = ShellTheme.foregroundNSColor
  }

  @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: NativeComposer
    weak var textView: NSTextView?
    var lastFocus = -1
    private var handledInsertionIDs = Set<UUID>()
    init(_ parent: NativeComposer) { self.parent = parent }
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
      guard let event = NSApp.currentEvent, event.type == .keyDown else { return false }
      let otherModifiers = !event.modifierFlags.intersection([.control, .option, .command]).isEmpty
      guard
        ComposerInputPolicy.shouldSubmit(
          isReturn: commandSelector == #selector(NSResponder.insertNewline(_:)),
          shift: event.modifierFlags.contains(.shift), hasMarkedText: textView.hasMarkedText(),
          otherModifiers: otherModifiers
        )
      else { return false }
      parent.onSubmit()
      return true
    }
    func textDidChange(_ notification: Notification) {
      guard let view = notification.object as? NSTextView else { return }
      parent.text = view.string
      measure()
    }
    func scheduleInsertionIfNeeded() {
      guard let command = parent.insertion, handledInsertionIDs.insert(command.id).inserted else {
        return
      }
      // Execute after SwiftUI finishes the current representable update. Every mutable
      // precondition is checked again then, so a navigation/reconnect/IME transition wins.
      DispatchQueue.main.async { [self, weak textView] in
        guard let view = textView else {
          parent.onInsertionResult(command.id, false)
          return
        }
        let current = parent.insertion
        guard current?.id == command.id, parent.conversationID == command.conversationID,
          parent.contextGeneration == command.contextGeneration,
          parent.text == command.expectedText, view.string == command.expectedText,
          view.isEditable, view.isSelectable, !view.hasMarkedText(), !command.text.isEmpty
        else {
          parent.onInsertionResult(command.id, false)
          return
        }
        let selected = view.selectedRange()
        guard selected.location != NSNotFound, Range(selected, in: view.string) != nil else {
          parent.onInsertionResult(command.id, false)
          return
        }
        view.insertText(
          Self.separated(command.text, in: view.string, replacing: selected),
          replacementRange: selected)
        parent.onInsertionResult(command.id, true)
      }
    }

    private static func separated(_ insertion: String, in body: String, replacing range: NSRange)
      -> String
    {
      guard let indices = Range(range, in: body) else { return insertion }
      var result = insertion
      let startsWithSpace = insertion.first?.isWhitespace == true
      let endsWithSpace = insertion.last?.isWhitespace == true
      if let previous = body[..<indices.lowerBound].last,
        needsSeparator(previous), !startsWithSpace
      {
        result.insert(" ", at: result.startIndex)
      }
      if let next = body[indices.upperBound...].first, needsSeparator(next), !endsWithSpace {
        result.append(" ")
      }
      return result
    }

    private static func needsSeparator(_ character: Character) -> Bool {
      // Whitespace also prevents a preceding slash, escape or URL prefix from
      // swallowing a picker-inserted token. Code regions remain literal by design.
      !character.isWhitespace
    }
    func measure() {
      guard let view = textView, let container = view.textContainer, let layout = view.layoutManager
      else { return }
      layout.ensureLayout(for: container)
      let measured = min(130, max(36, ceil(layout.usedRect(for: container).height) + 14))
      guard abs(parent.height - measured) > 1 else { return }
      DispatchQueue.main.async { [weak self] in self?.parent.height = measured }
    }
  }
}
