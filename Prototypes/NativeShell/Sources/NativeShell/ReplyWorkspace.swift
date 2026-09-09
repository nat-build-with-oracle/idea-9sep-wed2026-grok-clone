import Foundation
import WorkspaceCore

struct ReplyPreview: Equatable, Identifiable {
  let id: UUID
  let speakerName: String
  let excerpt: String
  let isAvailable: Bool
  let isLoading: Bool

  init(id: UUID, speakerName: String, excerpt: String, isAvailable: Bool, isLoading: Bool = false) {
    self.id = id
    self.speakerName = speakerName
    self.excerpt = excerpt
    self.isAvailable = isAvailable
    self.isLoading = isLoading
  }

  init(message: PreviewMessage) {
    id = message.id
    speakerName = message.role == .user ? "You" : message.speakerName ?? "Assistant"
    let text = message.text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    excerpt =
      text.isEmpty
      ? (message.attachmentIDs.isEmpty
        ? "Empty message" : AttachmentPresentation.storedCount(message.attachmentIDs.count))
      : String(text.prefix(180)) + (text.count > 180 ? "…" : "")
    isAvailable =
      message.role != .event && (!message.text.isEmpty || !message.attachmentIDs.isEmpty)
    isLoading = false
  }
}

struct TranscriptJumpRequest: Equatable {
  let requestID = UUID()
  let conversationID: UUID
  let messageID: UUID
}

extension PreviewWorkspace {
  var currentReply: ReplyPreview? {
    guard let id = selectedID, let parentID = draftReplyIDs[id] else { return nil }
    return resolvedReplyPreview(parentID, in: id)
  }

  func replyPreview(for message: PreviewMessage) -> ReplyPreview? {
    guard let id = selectedID, let parentID = message.replyToID else { return nil }
    return resolvedReplyPreview(parentID, in: id)
  }

  private func resolvedReplyPreview(_ parentID: UUID, in conversationID: UUID) -> ReplyPreview {
    if let local = messages[conversationID]?.first(where: { $0.id == parentID && $0.role != .event }
    ) {
      return ReplyPreview(message: local)
    }
    return replyPreviews[conversationID]?[parentID]
      ?? ReplyPreview(
        id: parentID, speakerName: "Original message", excerpt: "Loading original message…",
        isAvailable: false, isLoading: true)
  }

  /// Drafting is local: choosing a parent never sends, switches conversations, or changes text.
  func beginReply(to messageID: UUID, in conversationID: UUID) async {
    guard !isClosing, !isLoading, selectedID == conversationID else { return }
    replyChoiceRequests[conversationID, default: 0] += 1
    let request = replyChoiceRequests[conversationID]
    let selection = selectionRequest
    let context = replyContextGeneration
    do {
      let parent: PreviewMessage
      if isPersistent {
        guard let repository else { throw WorkspaceError.storeUnavailable }
        let message = try await repository.message(id: messageID)
        guard message.conversationID == conversationID, message.role != .event,
          !message.text.isEmpty || !message.attachmentIDs.isEmpty
        else {
          throw WorkspaceError.invalidDraft
        }
        parent = projectMessage(message)
      } else {
        guard
          let message = messages[conversationID]?.first(where: {
            $0.id == messageID && $0.role != .event
              && (!$0.text.isEmpty || !$0.attachmentIDs.isEmpty)
          })
        else {
          throw WorkspaceError.invalidDraft
        }
        parent = message
      }
      guard !isClosing, !isLoading, selectedID == conversationID, selection == selectionRequest,
        context == replyContextGeneration, request == replyChoiceRequests[conversationID]
      else { return }
      replyPreviews[conversationID, default: [:]][messageID] = ReplyPreview(message: parent)
      draftReplyIDs[conversationID] = messageID
      if isPersistent { scheduleDraftSave(conversationID) }
      composerFocusRequest += 1
      notice = nil
    } catch {
      guard selectedID == conversationID, selection == selectionRequest,
        context == replyContextGeneration, request == replyChoiceRequests[conversationID]
      else { return }
      notice = "That message is not available to reply to. Your draft is unchanged."
    }
  }

  func clearReply(in conversationID: UUID) {
    guard !isClosing, !isLoading, selectedID == conversationID else { return }
    // Also invalidates a pending parent lookup even if the current draft has no reference yet.
    replyChoiceRequests[conversationID, default: 0] += 1
    guard draftReplyIDs.removeValue(forKey: conversationID) != nil else { return }
    if isPersistent { scheduleDraftSave(conversationID) }
    composerFocusRequest += 1
  }

  func refreshReplyPreviews(in conversationID: UUID, retryUnavailable: Bool = false) async {
    guard let repository else { return }
    let context = replyContextGeneration
    let activeParents = Set(
      generations.filter { !$0.state.isTerminal }.compactMap(\.assistantMessageID))
    var ids = Set((messages[conversationID] ?? []).compactMap(\.replyToID))
    if let id = draftReplyIDs[conversationID] { ids.insert(id) }
    for id in ids {
      if messages[conversationID]?.contains(where: { $0.id == id && $0.role != .event }) == true {
        continue
      }
      if let cached = replyPreviews[conversationID]?[id], !cached.isLoading,
        !activeParents.contains(id), !retryUnavailable || cached.isAvailable
      {
        continue
      }
      do {
        let message = try await repository.message(id: id)
        guard context == replyContextGeneration else { return }
        guard message.conversationID == conversationID, message.role != .event,
          !message.text.isEmpty || !message.attachmentIDs.isEmpty
        else {
          throw WorkspaceError.invalidDraft
        }
        replyPreviews[conversationID, default: [:]][id] = ReplyPreview(
          message: projectMessage(message))
      } catch {
        guard context == replyContextGeneration else { return }
        replyPreviews[conversationID, default: [:]][id] = ReplyPreview(
          id: id, speakerName: "Original message", excerpt: "Original message unavailable",
          isAvailable: false)
      }
    }
  }

  /// Load a contiguous transcript back to the parent, keeping already visible and streamed rows.
  /// Every await rechecks navigation/request identity; no jump may navigate to another conversation.
  func jumpToReply(messageID: UUID, in conversationID: UUID) async {
    guard !isClosing, !isLoading, selectedID == conversationID else { return }
    replyJumpGeneration += 1
    let request = replyJumpGeneration
    let selection = selectionRequest
    let context = replyContextGeneration
    isJumpingToReply = true
    defer { if request == replyJumpGeneration { isJumpingToReply = false } }
    func isCurrent() -> Bool {
      !isClosing && !isLoading && selectedID == conversationID && selection == selectionRequest
        && context == replyContextGeneration && request == replyJumpGeneration
    }
    do {
      if isPersistent {
        guard let repository else { throw WorkspaceError.storeUnavailable }
        let target = try await repository.message(id: messageID)
        guard isCurrent() else { return }
        guard target.conversationID == conversationID, target.role != .event,
          !target.text.isEmpty || !target.attachmentIDs.isEmpty
        else {
          throw WorkspaceError.invalidDraft
        }
        while messages[conversationID]?.contains(where: { $0.id == messageID }) != true {
          let before = messages[conversationID]?.compactMap(\.sequence).min()
          guard before.map({ target.sequence < $0 }) ?? true else {
            throw WorkspaceError.missingRecord
          }
          let page = try await repository.messages(
            conversationID: conversationID, beforeSequence: before, limit: 100)
          guard isCurrent() else { return }
          guard let first = page.messages.first, before.map({ first.sequence < $0 }) ?? true else {
            throw WorkspaceError.missingRecord
          }
          mergeOlderMessages(page, in: conversationID)
        }
      }
      guard isCurrent(),
        messages[conversationID]?.contains(where: {
          $0.id == messageID && $0.role != .event
            && (!$0.text.isEmpty || !$0.attachmentIDs.isEmpty)
        })
          == true
      else { return }
      await refreshReplyPreviews(in: conversationID)
      guard isCurrent() else { return }
      transcriptJumpRequest = TranscriptJumpRequest(
        conversationID: conversationID, messageID: messageID)
    } catch {
      guard isCurrent() else { return }
      notice = "The original message could not be opened. Your draft is unchanged."
    }
  }

  func mergeOlderMessages(_ page: MessagePage, in conversationID: UUID) {
    let current = messages[conversationID] ?? []
    let existingIDs = Set(current.map(\.id))
    let older = page.messages.filter { !existingIDs.contains($0.id) }.map(projectMessage)
    messages[conversationID] = (older + current).sorted { ($0.sequence ?? 0) < ($1.sequence ?? 0) }
    if selectedID == conversationID,
      page.messages.isEmpty
        || page.messages.first?.sequence == messages[conversationID]?.first?.sequence
    {
      hasOlderMessages = page.hasMore
      olderCursor = page.beforeSequence
    }
  }
}
