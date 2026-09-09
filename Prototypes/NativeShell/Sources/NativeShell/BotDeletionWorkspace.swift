import Foundation
import WorkspaceCore

struct BotDeletionTarget: Equatable, Identifiable {
  let id: UUID
}

extension PreviewWorkspace {
  var canBeginBotDeletion: Bool {
    isPersistent && repository != nil && coordinator != nil
      && !isClosing && !isLoading && !isSaving && !isSubmitting && !isProfileSaving
      && !isExporting && !isDeletingBot && botDeletionTarget == nil
      && editTarget == nil && panel == nil && routineEditTarget == nil
      && routineDetailTarget == nil && pendingRoutineActions.isEmpty
  }

  var currentNeedsMembershipRepair: Bool {
    guard let current, current.kind == .group else { return false }
    return current.memberIDs.filter { id in bots.contains { $0.id == id } }.count < 2
  }

  func canRetry(_ generation: Generation) -> Bool {
    guard !isDeletingBot, !isClosing, generation.routineRunID == nil,
      let conversation = conversations.first(where: { $0.id == generation.conversationID }),
      conversation.memberIDs.contains(generation.targetBotID),
      bots.contains(where: { $0.id == generation.targetBotID })
    else { return false }
    return conversation.kind != .group
      || conversation.memberIDs.filter { id in bots.contains { $0.id == id } }.count >= 2
  }

  @discardableResult
  func beginBotDeletion(_ botID: UUID) -> Task<Void, Never>? {
    guard canBeginBotDeletion, bots.contains(where: { $0.id == botID }) else { return nil }
    botDeletionTarget = BotDeletionTarget(id: botID)
    return reloadBotDeletionPlan()
  }

  @discardableResult
  func reloadBotDeletionPlan() -> Task<Void, Never>? {
    guard let target = botDeletionTarget, let repository, !isDeletingBot, !isClosing else {
      return nil
    }
    botDeletionRequest += 1
    let request = botDeletionRequest
    let context = replyContextGeneration
    botDeletionLoadTask?.cancel()
    botDeletionPlan = nil
    botDeletionError = nil
    isLoadingBotDeletion = true
    botDeletionLoadTask = Task {
      defer {
        if request == botDeletionRequest {
          isLoadingBotDeletion = false
          botDeletionLoadTask = nil
        }
      }
      do {
        try Task.checkCancellation()
        guard request == botDeletionRequest, context == replyContextGeneration,
          botDeletionTarget == target
        else { return }
        try await flushDrafts()
        let plan = try await repository.botDeletionPlan(botID: target.id)
        try Task.checkCancellation()
        guard request == botDeletionRequest, context == replyContextGeneration,
          botDeletionTarget == target
        else { return }
        botDeletionPlan = plan
      } catch {
        guard request == botDeletionRequest, context == replyContextGeneration,
          botDeletionTarget == target, !Task.isCancelled
        else { return }
        botDeletionError = Self.deletionErrorMessage(error)
      }
    }
    return botDeletionLoadTask
  }

  func cancelBotDeletion() {
    guard !isDeletingBot, botDeletionTarget != nil || isLoadingBotDeletion else { return }
    botDeletionRequest += 1
    botDeletionLoadTask?.cancel()
    botDeletionLoadTask = nil
    isLoadingBotDeletion = false
    botDeletionTarget = nil
    botDeletionPlan = nil
    botDeletionError = nil
    composerFocusRequest += 1
  }

  @discardableResult
  func confirmBotDeletion() -> Task<Void, Never>? {
    guard let plan = botDeletionPlan, botDeletionTarget?.id == plan.botID,
      let coordinator, !isClosing, !isLoading, !isLoadingBotDeletion, !isDeletingBot,
      !isSubmitting, !isProfileSaving, !isExporting
    else { return nil }
    let context = replyContextGeneration
    isDeletingBot = true
    botDeletionError = nil
    selectionRequest += 1
    // Accepted deletion is joined by quit/reconnect, not retargeted by later selection.
    botDeletionTask = Task {
      defer {
        isDeletingBot = false
        botDeletionTask = nil
      }
      do {
        draftSaveTask?.cancel()
        await draftSaveTask?.value
        try await flushDrafts()
        guard context == replyContextGeneration else { throw WorkspaceError.staleRevision }
        try await coordinator.deleteBot(expected: plan)
        removeDeletedBotFromPresentation(plan)
        botDeletionTarget = nil
        botDeletionPlan = nil
        notice = "Bot deleted. Group history and shared providers were kept."
        do {
          try await refreshPersistent()
          if selectedID == nil { selectedID = visibleConversations.first?.id }
          if let selectedID { try await loadMessages(selectedID) }
        } catch {
          // The transaction succeeded. Do not tell the user deletion failed or can be retried.
          storageError = "Bot deleted, but the workspace could not refresh. Reopen it to refresh."
        }
      } catch {
        botDeletionPlan = nil
        botDeletionError =
          Self.deletionErrorMessage(error)
          + " Review the current impact before trying again. Affected replies may already be stopped."
      }
    }
    return botDeletionTask
  }

  private func removeDeletedBotFromPresentation(_ plan: BotDeletionPlan) {
    let removed = Set(plan.directConversationIDs)
    bots.removeAll { $0.id == plan.botID }
    conversations.removeAll { removed.contains($0.id) }
    for index in conversations.indices {
      conversations[index].memberIDs.removeAll { $0 == plan.botID }
    }
    for id in removed {
      drafts[id] = nil
      draftReplyIDs[id] = nil
      draftAttachmentIDs[id] = nil
      dirtyDrafts.remove(id)
      draftVersions[id] = nil
      messages[id] = nil
      replyPreviews[id] = nil
      selectedTargetBotIDs[id] = nil
    }
    for (id, target) in selectedTargetBotIDs where target == plan.botID {
      selectedTargetBotIDs[id] = nil
    }
    generations.removeAll { removed.contains($0.conversationID) }
    routines.removeAll { $0.botID == plan.botID }
    if let selectedID, removed.contains(selectedID) { self.selectedID = nil }
    transcriptJumpRequest = nil
    replyJumpGeneration += 1
    isJumpingToReply = false
  }

  private static func deletionErrorMessage(_ error: Error) -> String {
    if let known = error as? BotDeletionError { return known.localizedDescription }
    if let known = error as? WorkspaceError { return known.localizedDescription }
    return "The bot could not be deleted. Check workspace storage and try again."
  }
}
