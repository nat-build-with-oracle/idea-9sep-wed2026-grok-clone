import Foundation
import WorkspaceCore

enum ProviderSetupError: Error, LocalizedError {
  case noProvider, targetRequired, busy, changedDestination, changedCredentialLifetime,
    changedProviderKind, unexpectedCredential
  var errorDescription: String? {
    switch self {
    case .noProvider: "Choose a provider in Settings before sending. Your draft is kept."
    case .targetRequired: "Choose one or more bots to reply to this group message."
    case .busy: "Wait for the current save to finish, then try again."
    case .changedDestination:
      "The destination changed. Re-enter the key to authorize its use with this API root."
    case .changedCredentialLifetime:
      "The credential storage choice changed. Re-enter the key; saved credentials are never copied between storage modes."
    case .changedProviderKind:
      "The provider type changed. Import or enter a fresh credential; credentials are never copied between provider types."
    case .unexpectedCredential:
      "The supplied credential does not belong to the selected provider type. Nothing was saved."
    }
  }
}

enum CapturedDraftCommand {
  case single(SendCommand)
  case round(SendRoundCommand)
}

extension PreviewWorkspace {
  var selectedProvider: ProviderConfig? { providers.first { $0.id == selectedProviderID } }
  var selectedTargetBotIDsForCurrent: [UUID] {
    guard let current else { return [] }
    if current.kind == .direct { return Array(current.memberIDs.prefix(1)) }
    let members = Set(current.memberIDs)
    let selected = selectedTargetBotIDs[current.id] ?? []
    guard Set(selected).count == selected.count, selected.allSatisfy(members.contains) else {
      return []
    }
    return selected
  }
  var selectedTargetBotID: UUID? {
    let targets = selectedTargetBotIDsForCurrent
    return targets.count == 1 ? targets[0] : nil
  }

  func toggleGroupTarget(_ botID: UUID, in conversationID: UUID) {
    guard
      let conversation = conversations.first(where: { $0.id == conversationID }),
      conversation.kind == .group, conversation.memberIDs.contains(botID)
    else { return }
    var targets = selectedTargetBotIDs[conversationID] ?? []
    if let index = targets.firstIndex(of: botID) {
      targets.remove(at: index)
    } else {
      targets.append(botID)
    }
    selectedTargetBotIDs[conversationID] = targets.isEmpty ? nil : targets
  }

  func moveGroupTarget(_ botID: UUID, in conversationID: UUID, offset: Int) {
    guard var targets = selectedTargetBotIDs[conversationID],
      let index = targets.firstIndex(of: botID)
    else { return }
    let destination = index + offset
    guard targets.indices.contains(destination) else { return }
    targets.swapAt(index, destination)
    selectedTargetBotIDs[conversationID] = targets
  }

  func openSettings() {
    if let openSettingsAction { openSettingsAction() } else { panel = .settings }
  }

  static func providerErrorMessage(_ error: Error) -> String {
    if let error = error as? WorkspaceError { return error.localizedDescription }
    if let error = error as? ProviderSetupError { return error.localizedDescription }
    if let error = error as? GroupMentionIssue { return error.localizedDescription }
    if let error = error as? AttachmentError { return error.localizedDescription }
    if let error = error as? AttachmentWorkspaceError { return error.localizedDescription }
    if let error = error as? AttachmentFileImportError { return error.localizedDescription }
    return ProviderError.sanitized(error).localizedDescription
  }

  func makeCoordinator() {
    guard let repository, let credentials, let chatProvider else { return }
    let context = replyContextGeneration
    coordinator = GenerationCoordinator(
      repository: repository, credentials: credentials, provider: chatProvider,
      onChange: { [weak self] id in await self?.refreshGeneration(id, expectedContext: context) },
      onError: { [weak self] message in await self?.setProviderStorageError(message) })
    coordinatorStopped = false
    providerShutdownStarted = false
    startRoutineHost()
  }

  private func setProviderStorageError(_ message: String) { storageError = message }

  func refreshGeneration(_ conversationID: UUID, expectedContext: Int? = nil) async {
    if let expectedContext, expectedContext != replyContextGeneration { return }
    guard let repository else { return }
    let context = replyContextGeneration
    do {
      let snapshot = try await repository.snapshot()
      let page = try await repository.messages(conversationID: conversationID, limit: 100)
      guard context == replyContextGeneration,
        conversations.contains(where: { $0.id == conversationID })
      else { return }
      generations = snapshot.generations
      projectConversationActivity(snapshot, context: context)
      if routineDetailTarget != nil { try await refreshRoutinePresentation() }
      // Keep older pages already loaded; update deltas by stable message identity.
      var existing = messages[conversationID] ?? []
      for item in page.messages {
        let projected = projectMessage(item)
        if let index = existing.firstIndex(where: { $0.id == item.id }) {
          existing[index] = projected
        } else {
          existing.append(projected)
        }
      }
      messages[conversationID] = existing
      await refreshReplyPreviews(in: conversationID)
      await refreshAttachmentMetadata(in: conversationID)
    } catch {
      guard context == replyContextGeneration,
        conversations.contains(where: { $0.id == conversationID })
      else { return }
      storageError = Self.providerErrorMessage(error)
    }
  }

  @discardableResult
  func submitDraft(attachmentConsent: AttachmentTransmissionPlan? = nil) async throws -> UUID {
    let captured = try captureDraftSubmission()
    switch captured.command {
    case .single(let command):
      return try await submitCapturedDraft(
        command, configuration: captured.configuration, version: captured.version,
        context: captured.context, attachmentConsent: attachmentConsent)
    case .round:
      // Multi-target sends must pass through the explicit ordered disclosure UI.
      throw ProviderError.roundConsentChanged
    }
  }

  func captureDraftSubmission() throws -> (
    command: CapturedDraftCommand, configuration: ProviderConfig, version: Int?, context: Int,
    mentionRouting: MentionRoutingSnapshot?
  ) {
    guard !isClosing, !isSubmitting, !isDeletingBot, !isAttachingFiles, mentionInsertion == nil
    else {
      throw ProviderSetupError.busy
    }
    guard !currentNeedsMembershipRepair else { throw WorkspaceError.invalidMembers }
    guard coordinator != nil, let configuration = selectedProvider else {
      throw ProviderSetupError.noProvider
    }
    guard let conversationID = selectedID else { throw WorkspaceError.missingRecord }
    let mentionRouting = try captureMentionRouting()
    let targets = mentionRouting?.targetBotIDs ?? selectedTargetBotIDsForCurrent
    guard !targets.isEmpty else { throw ProviderSetupError.targetRequired }
    let text = (currentMentionResolution?.messageText ?? draft)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let sourceText = current?.kind == .group ? draft : nil
    let attachmentIDs = draftAttachmentIDs[conversationID] ?? []
    guard !text.isEmpty || !attachmentIDs.isEmpty else { throw WorkspaceError.invalidDraft }
    return (
      targets.count == 1 && mentionRouting == nil
        ? .single(
          SendCommand(
            conversationID: conversationID, targetBotID: targets[0], text: text,
            replyToID: draftReplyIDs[conversationID], attachmentIDs: attachmentIDs,
            expectedDraftText: sourceText))
        : .round(
          SendRoundCommand(
            conversationID: conversationID,
            targets: targets.map { SendRoundCommand.Target(targetBotID: $0) }, text: text,
            replyToID: draftReplyIDs[conversationID], attachmentIDs: attachmentIDs,
            expectedDraftText: sourceText)),
      configuration, draftVersions[conversationID], replyContextGeneration, mentionRouting
    )
  }

  @discardableResult
  func submitCapturedDraft(
    _ command: SendCommand, configuration: ProviderConfig, version: Int?, context: Int,
    attachmentConsent: AttachmentTransmissionPlan?
  ) async throws -> UUID {
    guard let coordinator, !isClosing, !isSubmitting, !isDeletingBot,
      context == replyContextGeneration
    else { throw ProviderSetupError.busy }
    isSubmitting = true
    defer { isSubmitting = false }
    try await flushDrafts()
    try Task.checkCancellation()
    guard !isClosing, context == replyContextGeneration else { throw WorkspaceError.storeClosed }
    let id = try await coordinator.submit(
      command, configuration: configuration, attachmentConsent: attachmentConsent)
    guard context == replyContextGeneration else { return id }
    let conversationID = command.conversationID
    if draftVersions[conversationID] == version {
      drafts[conversationID] = ""
      draftReplyIDs[conversationID] = nil
      draftAttachmentIDs[conversationID] = []
      dirtyDrafts.remove(conversationID)
    } else {
      // A newer edit remains a separate draft, even when its text happens to match.
      scheduleDraftSave(conversationID)
    }
    notice = nil
    await refreshGeneration(conversationID)
    return id
  }

  @discardableResult
  func submitCapturedRound(
    _ command: SendRoundCommand, configuration: ProviderConfig, version: Int?, context: Int,
    consent: RoundTransmissionPlan
  ) async throws -> [UUID] {
    guard let coordinator, !isClosing, !isSubmitting, !isDeletingBot,
      context == replyContextGeneration
    else { throw ProviderSetupError.busy }
    isSubmitting = true
    defer { isSubmitting = false }
    try await flushDrafts()
    try Task.checkCancellation()
    guard !isClosing, context == replyContextGeneration else { throw WorkspaceError.storeClosed }
    let ids = try await coordinator.submitRound(
      command, configuration: configuration, consent: consent)
    guard context == replyContextGeneration else { return ids }
    let conversationID = command.conversationID
    if draftVersions[conversationID] == version {
      drafts[conversationID] = ""
      draftReplyIDs[conversationID] = nil
      draftAttachmentIDs[conversationID] = []
      dirtyDrafts.remove(conversationID)
    } else {
      scheduleDraftSave(conversationID)
    }
    notice = nil
    await refreshGeneration(conversationID)
    return ids
  }

  func cancelReply(_ id: UUID) async throws {
    guard let coordinator, let generation = generations.first(where: { $0.id == id }) else {
      throw ProviderSetupError.busy
    }
    let siblings = generations.filter { $0.userMessageID == generation.userMessageID }
    let actionIDs = siblings.count > 1 ? Set(siblings.map(\.id)) : Set([id])
    guard pendingGenerationActions.isDisjoint(with: actionIDs) else {
      throw ProviderSetupError.busy
    }
    pendingGenerationActions.formUnion(actionIDs)
    defer { pendingGenerationActions.subtract(actionIDs) }
    if siblings.count > 1 {
      try await coordinator.cancelRound(userMessageID: generation.userMessageID)
    } else if let runID = generation.routineRunID {
      try await coordinator.cancelRoutine(runID)
    } else {
      try await coordinator.cancel(id)
    }
  }

  func retryReply(_ id: UUID, attachmentConsent: AttachmentTransmissionPlan? = nil) async throws {
    guard !roundHasUnfinishedSiblings(of: id) else { throw ProviderError.roundInProgress }
    guard !isClosing, !isDeletingBot, let coordinator, !pendingGenerationActions.contains(id) else {
      throw ProviderSetupError.busy
    }
    guard let configuration = selectedProvider else { throw ProviderSetupError.noProvider }
    pendingGenerationActions.insert(id)
    defer { pendingGenerationActions.remove(id) }
    try await coordinator.retry(
      id, configuration: configuration, attachmentConsent: attachmentConsent)
  }

  @discardableResult
  func saveProvider(
    id: UUID?, name: String, apiRoot: String, modelID: String, secret: String,
    allowsLoopbackHTTP: Bool, credentialLifetime: CredentialLifetime? = nil,
    kind: ProviderKind = .chatCompletions, codexCredential: CodexSessionCredential? = nil
  ) async throws -> UUID {
    guard !isClosing, !isProviderSaving else { throw ProviderSetupError.busy }
    guard let repository, let credentials else { throw WorkspaceError.storeUnavailable }
    isProviderSaving = true
    defer {
      isProviderSaving = false
      let waiters = providerSaveWaiters
      providerSaveWaiters.removeAll()
      for waiter in waiters { waiter.resume() }
    }
    let snapshot = try await repository.snapshot()
    let old = snapshot.providers.first { $0.id == id }
    guard id == nil || old != nil else { throw WorkspaceError.missingRecord }
    let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (1...80).contains(cleanName.count) else { throw WorkspaceError.invalidProvider }
    let isKindChange = old.map { $0.kind != kind } ?? false
    let apiSecretReplacement = !secret.isEmpty
    let codexReplacement = codexCredential != nil
    guard !(apiSecretReplacement && codexReplacement) else {
      throw ProviderSetupError.unexpectedCredential
    }
    switch kind {
    case .chatCompletions:
      guard codexCredential == nil else { throw ProviderSetupError.unexpectedCredential }
      guard apiSecretReplacement || old != nil else { throw ProviderError.missingCredential }
      if isKindChange && !apiSecretReplacement { throw ProviderSetupError.changedProviderKind }
    case .codexResponses:
      guard secret.isEmpty else { throw ProviderSetupError.unexpectedCredential }
      guard codexReplacement || old != nil else { throw ProviderError.codexLoginRequired }
      if isKindChange && !codexReplacement { throw ProviderSetupError.changedProviderKind }
    }
    if apiSecretReplacement {
      guard secret.utf8.count <= 16_384, !secret.contains(where: { $0.isNewline || $0 == "\0" }),
        !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { throw ProviderError.invalidCredential }
    }
    let lifetime: CredentialLifetime =
      kind == .codexResponses
      ? .session
      : credentialLifetime ?? old.map { CredentialLifetime.forReference($0.credentialReference) }
        ?? .keychain
    let replacement = apiSecretReplacement || codexReplacement
    if let old, !replacement, lifetime != CredentialLifetime.forReference(old.credentialReference) {
      throw ProviderSetupError.changedCredentialLifetime
    }
    let reference: String
    if codexReplacement {
      reference = CodexSessionCredential.makeReference()
    } else if apiSecretReplacement {
      reference = lifetime.makeReference()
    } else {
      reference = old!.credentialReference
    }
    let root: URL
    switch kind {
    case .chatCompletions:
      guard
        let enteredRoot = URL(
          string: apiRoot.trimmingCharacters(in: .whitespacesAndNewlines))
      else { throw WorkspaceError.invalidProvider }
      root = enteredRoot
    case .codexResponses:
      guard
        let enteredRoot = URL(
          string: apiRoot.trimmingCharacters(in: .whitespacesAndNewlines)),
        enteredRoot.absoluteString == CodexResponsesProvider.apiRoot.absoluteString,
        !allowsLoopbackHTTP
      else { throw WorkspaceError.invalidProvider }
      root = enteredRoot
    }
    let configuration = ProviderConfig(
      id: old?.id ?? UUID(), name: cleanName, apiRoot: root,
      modelID: modelID.trimmingCharacters(in: .whitespacesAndNewlines),
      credentialReference: reference,
      allowsLoopbackHTTP: allowsLoopbackHTTP, kind: kind)
    switch kind {
    case .chatCompletions: _ = try ProviderEndpoint.chatCompletions(configuration)
    case .codexResponses: try CodexResponsesProvider.validateConfiguration(configuration)
    }
    if let old, old.apiRoot != configuration.apiRoot, !replacement {
      throw ProviderSetupError.changedDestination
    }
    if apiSecretReplacement { try await credentials.write(Data(secret.utf8), for: reference) }
    if let codexCredential {
      try await credentials.write(try codexCredential.sessionData(), for: reference)
    }
    do {
      guard !isClosing else { throw WorkspaceError.storeClosed }
      try await repository.apply(.saveProvider(configuration))
    } catch {
      if replacement {
        do { try await credentials.remove(reference) } catch {
          notice =
            "Provider was not saved. An unused credential could not be removed. No plaintext key was saved to disk."
        }
      }
      throw error
    }
    try await refreshPersistent()
    selectedProviderID = configuration.id
    if replacement, let old,
      !providers.contains(where: { $0.credentialReference == old.credentialReference })
    {
      do { try await credentials.remove(old.credentialReference) } catch {
        notice = "Provider saved. Its previous unused credential could not be removed."
      }
    }
    return configuration.id
  }

  func prepareForClose() async throws {
    await suspendReadReceipts()
    await shutdownRoutines()
    try await finishAttachmentImport()
    cancelAttachmentConfirmation()
    if let botDeletionTask {
      await botDeletionTask.value
      if botDeletionError != nil { throw WorkspaceError.storeUnavailable }
    } else {
      cancelBotDeletion()
    }
    cancelExportSelection?()
    if let exportTask {
      await exportTask.value
      if exportError != nil { throw WorkspaceExportFlowError.failed }
    }
    await profileEditorSaveTask?.value
    if isProfileSaving { await withCheckedContinuation { profileSaveWaiters.append($0) } }
    if isProviderSaving { await withCheckedContinuation { providerSaveWaiters.append($0) } }
    sendTask?.cancel()
    await sendTask?.value
    cancelAttachmentConfirmation()
    try await flushDrafts()
    providerShutdownStarted = true
    try await coordinator?.shutdown()
    coordinatorStopped = true
  }

  func resumeAfterCloseFailure() {
    readReceiptsSuspended = false
    requestVisibleReadReceipt()
    if coordinatorStopped {
      makeCoordinator()
    } else if routineHost == nil && !providerShutdownStarted {
      startRoutineHost()
    }
  }

  func recoverStorage() async throws {
    try await flushDrafts()
    if providerShutdownStarted, !coordinatorStopped {
      try await coordinator?.shutdown()
      coordinatorStopped = true
    }
    resumeAfterCloseFailure()
  }
}
