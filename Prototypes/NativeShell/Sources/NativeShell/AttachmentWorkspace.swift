import Foundation
import WorkspaceCore

enum AttachmentWorkspaceError: Error, LocalizedError {
  case changed, failed

  var errorDescription: String? {
    switch self {
    case .changed: "The conversation or draft changed. Choose the files or review Send again."
    case .failed:
      "The file operation could not finish. Check the draft, selected text files, permissions and available storage."
    }
  }
}

struct AttachmentConfirmationTarget: Identifiable {
  enum Action {
    case send(SendCommand, draftVersion: Int?)
    case retry(UUID)
  }

  let id = UUID()
  let plan: AttachmentTransmissionPlan
  let action: Action
  let context: Int
  let conversation: String
  let targetBot: String
}

extension PreviewWorkspace {
  var canChooseAttachments: Bool {
    isPersistent && repository != nil && selectedID != nil && !isLoading && !isClosing
      && !isAttachingFiles && !isSubmitting && !isDeletingBot && !isExporting
      && botDeletionTarget == nil && attachmentConfirmationTarget == nil && panel == nil
      && editTarget == nil && routineEditTarget == nil && routineDetailTarget == nil
      && sendTask == nil
  }

  func chooseAttachments() {
    guard canChooseAttachments else { return }
    performAttachmentImport(chooser: NativeAttachmentFileChooser())
  }

  @discardableResult
  func performAttachmentImport(
    chooser: any AttachmentFileChoosing,
    read: @escaping @Sendable ([URL], UUID) async throws -> [AttachmentContent] = { urls, id in
      try await Task.detached(priority: .utility) {
        try AttachmentFileImporter.read(urls: urls, conversationID: id)
      }.value
    }
  ) -> Task<Void, Never>? {
    guard canChooseAttachments, let conversationID = selectedID else { return nil }
    let context = replyContextGeneration
    let conversationTitle = current?.title ?? "conversation"
    isAttachingFiles = true
    attachmentImportFailure = nil
    notice = nil
    var cancelled = false
    cancelAttachmentSelection = {
      cancelled = true
      chooser.cancel()
    }
    attachmentImportTask = Task {
      defer {
        isAttachingFiles = false
        attachmentImportAccepted = false
        attachmentImportTask = nil
        cancelAttachmentSelection = nil
      }
      guard !cancelled, !isClosing, !isLoading else { return }
      guard let urls = await chooser.choose(), !urls.isEmpty, !cancelled else { return }
      guard context == replyContextGeneration, !isClosing, !isLoading else { return }
      // Accepted copy work is joined, not abandoned, on quit/reconnect. Selection
      // changes may continue, but never retarget these files to a different chat.
      attachmentImportAccepted = true
      cancelAttachmentSelection = nil
      do {
        let contents = try await read(urls, conversationID)
        guard context == replyContextGeneration,
          conversations.contains(where: { $0.id == conversationID })
        else { throw AttachmentWorkspaceError.changed }
        try await stageAttachments(contents, in: conversationID)
        guard context == replyContextGeneration else { return }
        notice = "Copied \(contents.count) text files into \(conversationTitle)'s local draft."
      } catch {
        guard context == replyContextGeneration else { return }
        attachmentImportFailure = Self.attachmentErrorMessage(error)
        notice = attachmentImportFailure
      }
    }
    return attachmentImportTask
  }

  func finishAttachmentImport() async throws {
    let running = attachmentImportTask
    cancelAttachmentSelection?()
    await running?.value
    // A failure observed while closing/reconnecting must remain visible, not be
    // hidden by immediately discarding the window after an accepted copy failed.
    if running != nil, attachmentImportFailure != nil { throw AttachmentWorkspaceError.failed }
  }

  /// Uses the sole versioned draft writer. A separate repository save here could
  /// race an older autosave and cause reference GC to discard a newly copied file.
  private func stageAttachments(_ contents: [AttachmentContent], in conversationID: UUID)
    async throws
  {
    guard let repository else { throw WorkspaceError.storeUnavailable }
    guard !contents.isEmpty else { return }
    let oldIDs = draftAttachmentIDs[conversationID] ?? []
    let newIDs = contents.map(\.attachment.id)
    guard Set(newIDs).count == newIDs.count, Set(oldIDs).isDisjoint(with: newIDs) else {
      throw AttachmentError.duplicateReference
    }
    guard oldIDs.count + newIDs.count <= AttachmentLimits.maxCount else {
      throw AttachmentError.tooManyAttachments
    }
    let existing = try await repository.attachments(ids: oldIDs)
    guard (draftAttachmentIDs[conversationID] ?? []) == oldIDs else {
      throw AttachmentWorkspaceError.changed
    }
    var total = existing.reduce(0) { $0 + $1.byteCount }
    for content in contents {
      guard content.attachment.conversationID == conversationID else {
        throw AttachmentError.foreignAttachment
      }
      // Also revalidate injected readers at the native boundary.
      _ = try AttachmentContent(attachment: content.attachment, data: content.data)
      total += content.data.count
      guard total <= AttachmentLimits.maxDraftBytes else { throw AttachmentError.draftTooLarge }
    }
    for content in contents {
      pendingAttachmentPayloads[content.attachment.id] = content
      attachmentMetadata[content.attachment.id] = content.attachment
      unavailableAttachmentIDs.remove(content.attachment.id)
    }
    draftAttachmentIDs[conversationID] = oldIDs + newIDs
    scheduleDraftSave(conversationID)
    do {
      try await flushDrafts()
    } catch {
      // A later unrelated draft can fail after this batch committed. Only undo
      // this batch if the writer has not acknowledged its payload transaction.
      if newIDs.contains(where: { pendingAttachmentPayloads[$0] != nil }) {
        draftAttachmentIDs[conversationID] = (draftAttachmentIDs[conversationID] ?? []).filter {
          !newIDs.contains($0)
        }
        for id in newIDs {
          pendingAttachmentPayloads[id] = nil
          attachmentMetadata[id] = nil
        }
        scheduleDraftSave(conversationID)
        storageError = Self.attachmentErrorMessage(error)
        throw error
      }
      // This file transaction succeeded. Preserve its success while surfacing the
      // unrelated draft failure; reporting a failed import invites duplicate copies.
      storageError = Self.attachmentErrorMessage(error)
    }
  }

  func removeDraftAttachment(_ id: UUID, in conversationID: UUID) {
    guard !isClosing, !isLoading, !isAttachingFiles, !isSubmitting, !isDeletingBot,
      selectedID == conversationID, attachmentConfirmationTarget == nil,
      draftAttachmentIDs[conversationID]?.contains(id) == true
    else { return }
    draftAttachmentIDs[conversationID]?.removeAll { $0 == id }
    scheduleDraftSave(conversationID)
    composerFocusRequest += 1
  }

  func refreshAttachmentMetadata(in conversationID: UUID, retryUnavailable: Bool = false) async {
    guard let repository else { return }
    let context = replyContextGeneration
    let ids = Set(
      (draftAttachmentIDs[conversationID] ?? [])
        + (messages[conversationID] ?? []).flatMap(\.attachmentIDs))
    if retryUnavailable { unavailableAttachmentIDs.subtract(ids) }
    let missing = ids.subtracting(attachmentMetadata.keys).subtracting(unavailableAttachmentIDs)
    // Each metadata API call is bounded to one message's maximum reference count.
    let ordered = missing.sorted { $0.uuidString < $1.uuidString }
    for offset in stride(from: 0, to: ordered.count, by: AttachmentLimits.maxCount) {
      let batch = Array(ordered[offset..<min(offset + AttachmentLimits.maxCount, ordered.count)])
      do {
        let metadata = try await repository.attachments(ids: batch)
        guard context == replyContextGeneration,
          conversations.contains(where: { $0.id == conversationID })
        else { return }
        for attachment in metadata { attachmentMetadata[attachment.id] = attachment }
      } catch AttachmentError.missingAttachment {
        // Only a genuinely missing record warrants individual metadata lookups.
        // Storage/corruption failures must remain visible, not become missing chips.
        for id in batch {
          do {
            let metadata = try await repository.attachments(ids: [id])
            guard context == replyContextGeneration,
              conversations.contains(where: { $0.id == conversationID })
            else { return }
            if let attachment = metadata.first { attachmentMetadata[id] = attachment }
          } catch AttachmentError.missingAttachment {
            guard context == replyContextGeneration else { return }
            unavailableAttachmentIDs.insert(id)
          } catch {
            guard context == replyContextGeneration else { return }
            storageError = Self.attachmentErrorMessage(error)
            return
          }
        }
      } catch {
        guard context == replyContextGeneration else { return }
        storageError = Self.attachmentErrorMessage(error)
        return
      }
    }
  }

  static func attachmentErrorMessage(_ error: Error) -> String {
    if let known = error as? AttachmentError { return known.localizedDescription }
    if let known = error as? AttachmentFileImportError { return known.localizedDescription }
    if let known = error as? AttachmentWorkspaceError { return known.localizedDescription }
    if let known = error as? WorkspaceError { return known.localizedDescription }
    return AttachmentWorkspaceError.failed.localizedDescription
  }

  func prepareSendOrConfirmAttachments() async throws {
    let captured = try captureDraftSubmission()
    guard let coordinator else { throw ProviderSetupError.noProvider }
    try await flushDrafts()
    let plan = try await coordinator.attachmentTransmissionPlan(
      for: captured.command, configuration: captured.configuration)
    try Task.checkCancellation()
    guard !isClosing, captured.context == replyContextGeneration else {
      throw AttachmentWorkspaceError.changed
    }
    if let plan {
      guard selectedID == plan.conversationID, selectedProvider == captured.configuration,
        selectedTargetBotID == plan.targetBotID,
        draftVersions[plan.conversationID] == captured.version
      else { throw AttachmentWorkspaceError.changed }
      showAttachmentConfirmation(
        plan, action: .send(captured.command, draftVersion: captured.version),
        context: captured.context)
    } else {
      _ = try await submitCapturedDraft(
        captured.command, configuration: captured.configuration, version: captured.version,
        context: captured.context, attachmentConsent: nil)
    }
  }

  func performRetry(_ generationID: UUID) {
    guard sendTask == nil, attachmentConfirmationTarget == nil, !isClosing, !isAttachingFiles,
      !isDeletingBot, let coordinator, let configuration = selectedProvider
    else { return }
    let context = replyContextGeneration
    sendTask = Task {
      defer { sendTask = nil }
      do {
        let plan = try await coordinator.retryAttachmentTransmissionPlan(
          for: generationID, configuration: configuration)
        try Task.checkCancellation()
        guard !isClosing, context == replyContextGeneration, selectedProvider == configuration
        else {
          throw AttachmentWorkspaceError.changed
        }
        if let plan {
          guard selectedID == plan.conversationID else { throw AttachmentWorkspaceError.changed }
          showAttachmentConfirmation(plan, action: .retry(generationID), context: context)
        } else {
          try await retryReply(generationID)
        }
      } catch { notice = Self.providerErrorMessage(error) }
    }
  }

  private func showAttachmentConfirmation(
    _ plan: AttachmentTransmissionPlan, action: AttachmentConfirmationTarget.Action, context: Int
  ) {
    attachmentConfirmationError = nil
    attachmentConfirmationTarget = AttachmentConfirmationTarget(
      plan: plan, action: action, context: context,
      conversation: conversations.first(where: { $0.id == plan.conversationID })?.title
        ?? "Conversation",
      targetBot: bots.first(where: { $0.id == plan.targetBotID })?.name ?? "Selected bot")
  }

  func cancelAttachmentConfirmation() {
    guard !isConfirmingAttachmentSend else { return }
    attachmentConfirmationTarget = nil
    attachmentConfirmationError = nil
    composerFocusRequest += 1
  }

  @discardableResult
  func confirmAttachmentSend() -> Task<Void, Never>? {
    guard let target = attachmentConfirmationTarget, sendTask == nil,
      !isClosing, !isLoading, !isConfirmingAttachmentSend
    else { return nil }
    // Claim synchronously so double clicks cannot accept two provider operations.
    isConfirmingAttachmentSend = true
    attachmentConfirmationError = nil
    sendTask = Task {
      defer {
        isConfirmingAttachmentSend = false
        sendTask = nil
      }
      do {
        guard target.context == replyContextGeneration, selectedID == target.plan.conversationID,
          selectedProvider == target.plan.provider
        else { throw ProviderError.attachmentConsentChanged }
        switch target.action {
        case .send(let command, let version):
          guard selectedTargetBotID == command.targetBotID,
            draftVersions[command.conversationID] == version
          else { throw ProviderError.attachmentConsentChanged }
          _ = try await submitCapturedDraft(
            command, configuration: target.plan.provider, version: version, context: target.context,
            attachmentConsent: target.plan)
        case .retry(let generationID):
          try await retryReply(generationID, attachmentConsent: target.plan)
        }
        if target.context == replyContextGeneration {
          attachmentConfirmationTarget = nil
          attachmentConfirmationError = nil
          composerFocusRequest += 1
        }
      } catch {
        guard target.context == replyContextGeneration else { return }
        attachmentConfirmationError = Self.providerErrorMessage(error)
      }
    }
    return sendTask
  }
}
