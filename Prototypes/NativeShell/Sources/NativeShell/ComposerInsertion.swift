import Foundation

/// A one-shot, context-bound request to insert plain text into the native composer.
/// The expected body prevents a delayed command from editing a newer draft that happens
/// to reuse the same conversation or view.
struct ComposerInsertion: Identifiable, Equatable {
  let id: UUID
  let conversationID: UUID
  let contextGeneration: Int
  let expectedText: String
  let text: String

  init(
    id: UUID = UUID(), conversationID: UUID, contextGeneration: Int, expectedText: String,
    text: String
  ) {
    self.id = id
    self.conversationID = conversationID
    self.contextGeneration = contextGeneration
    self.expectedText = expectedText
    self.text = text
  }
}
