import Foundation
import WorkspaceCore

struct ConversationReadViewport: Equatable {
  let conversationID: UUID
  let latestSequence: Int64
  let latestMessageID: UUID?
  let latestMessageTextByteCount: Int
  let isAtLatest: Bool

  static func bottomIsVisible(_ bottom: Double, in height: Double) -> Bool {
    bottom.isFinite && height.isFinite && height > 0 && bottom > 0 && bottom <= height + 0.5
  }
}

struct ConversationReadReceipt: Equatable {
  let context: Int
  let conversationID: UUID
  let throughSequence: Int64
}

extension PreviewWorkspace {
  /// One atomic snapshot supplies counts, watermarks and active-stream barriers together.
  /// Older async refreshes may not undo an acknowledged read or newer incoming activity.
  func projectConversationActivity(_ snapshot: WorkspaceSnapshot, context: Int) {
    guard context == replyContextGeneration, snapshot.revision >= activityRevision else { return }
    activityRevision = snapshot.revision
    conversationActivity = Dictionary(
      uniqueKeysWithValues: snapshot.conversationActivity.map { ($0.conversationID, $0) })
    lastReadSequences = Dictionary(
      uniqueKeysWithValues: snapshot.conversations.map { ($0.id, $0.lastReadSequence) })
    conversationReadBarriers = Set(
      snapshot.generations.filter { !$0.state.isTerminal }.map(\.conversationID))
    if let failed = failedReadReceipt,
      lastReadSequences[failed.conversationID] == nil
        || (lastReadSequences[failed.conversationID] ?? 0) >= failed.throughSequence
    {
      failedReadReceipt = nil
      readStatusError = nil
    }
  }

  var visibleReadReceipt: ConversationReadReceipt? {
    guard isPersistent, repository != nil, !readReceiptsSuspended,
      workspaceIsForeground, !isLoading, !isClosing, pickerMode == .closed,
      panel == nil, editTarget == nil, botDeletionTarget == nil,
      attachmentConfirmationTarget == nil, routineEditTarget == nil, routineDetailTarget == nil,
      !isAttachingFiles, !isExporting, !isDeletingBot,
      let id = selectedID, let viewport = readViewport, viewport.conversationID == id,
      viewport.isAtLatest, let activity = conversationActivity[id],
      activity.unreadAssistantCount > 0, viewport.latestSequence == activity.latestSequence,
      viewport.latestMessageID == activity.latestMessageID,
      viewport.latestMessageTextByteCount == activity.latestMessageTextByteCount,
      viewport.latestSequence > (lastReadSequences[id] ?? 0),
      !conversationReadBarriers.contains(id)
    else { return nil }
    return ConversationReadReceipt(
      context: replyContextGeneration, conversationID: id,
      throughSequence: viewport.latestSequence)
  }

  func recordReadViewport(_ viewport: ConversationReadViewport) {
    guard viewport.conversationID == selectedID else { return }
    readViewport = viewport
  }

  func requestVisibleReadReceipt() {
    guard readReceiptTask == nil, let receipt = visibleReadReceipt,
      receipt != failedReadReceipt, let repository
    else { return }
    readReceiptTask = Task { [weak self] in
      guard let self else { return }
      defer {
        self.readReceiptTask = nil
        self.requestVisibleReadReceipt()
      }
      var next: ConversationReadReceipt? = receipt
      while let receipt = next {
        // Navigation/visibility may change before this task reaches the repository.
        guard self.visibleReadReceipt == receipt else { return }
        do {
          try await repository.apply(
            .markRead(
              conversationID: receipt.conversationID, throughSequence: receipt.throughSequence))
          let snapshot = try await repository.snapshot()
          guard receipt.context == self.replyContextGeneration else { return }
          self.projectConversationActivity(snapshot, context: receipt.context)
          self.failedReadReceipt = nil
          self.readStatusError = nil
          next = self.visibleReadReceipt
        } catch {
          guard receipt.context == self.replyContextGeneration else { return }
          self.failedReadReceipt = receipt
          self.readStatusError =
            "Read status could not be saved or refreshed. Retry when storage is available."
          return
        }
      }
    }
  }

  func retryReadStatus() {
    guard readReceiptTask == nil, !readReceiptsSuspended, !isClosing, let repository else { return }
    let context = replyContextGeneration
    readReceiptTask = Task { [weak self] in
      guard let self else { return }
      defer {
        self.readReceiptTask = nil
        self.requestVisibleReadReceipt()
      }
      do {
        let snapshot = try await repository.snapshot()
        guard context == self.replyContextGeneration else { return }
        self.projectConversationActivity(snapshot, context: context)
        self.failedReadReceipt = nil
        self.readStatusError = nil
      } catch {
        guard context == self.replyContextGeneration else { return }
        self.readStatusError =
          "Read status could not be refreshed. Retry when storage is available."
      }
    }
  }

  func suspendReadReceipts() async {
    readReceiptsSuspended = true
    await readReceiptTask?.value
  }

  func resetConversationActivity() {
    activityRevision = -1
    conversationActivity = [:]
    lastReadSequences = [:]
    conversationReadBarriers = []
    readViewport = nil
    failedReadReceipt = nil
    readStatusError = nil
  }

  func sidebarPreview(for conversation: PreviewConversation) -> String {
    if isPersistent {
      return conversationActivity[conversation.id]?.lastMessagePreview ?? "Start a conversation"
    }
    return messages[conversation.id]?.last?.text ?? "Start a conversation"
  }

  func sidebarTimestamp(for conversation: PreviewConversation, now: Date = Date()) -> String? {
    guard isPersistent else {
      return conversation.id == conversations.first?.id ? "9:06 PM" : "Yesterday"
    }
    guard let date = conversationActivity[conversation.id]?.lastMessageAt else { return nil }
    if Calendar.current.isDate(date, inSameDayAs: now) {
      return date.formatted(date: .omitted, time: .shortened)
    }
    return date.formatted(.dateTime.month(.abbreviated).day())
  }
}
