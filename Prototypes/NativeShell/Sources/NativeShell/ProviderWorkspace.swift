import Foundation
import WorkspaceCore

enum ProviderSetupError: Error, LocalizedError {
  case noProvider, targetRequired, busy, changedDestination, changedCredentialLifetime,
    changedProviderKind, unexpectedCredential
  var errorDescription: String? {
    switch self {
    case .noProvider: "Choose a provider in Settings before sending. Your draft is kept."
    case .targetRequired: "Choose which bot should reply to this group message."
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

extension PreviewWorkspace {
  var selectedProvider: ProviderConfig? { providers.first { $0.id == selectedProviderID } }
  var selectedTargetBotID: UUID? {
    guard let current else { return nil }
    if current.kind == .direct { return current.memberIDs.first }
    guard let target = selectedTargetBotIDs[current.id], current.memberIDs.contains(target) else {
      return nil
    }
    return target
  }

  func openSettings() {
    if let openSettingsAction { openSettingsAction() } else { panel = .settings }
  }

  static func providerErrorMessage(_ error: Error) -> String {
    if let error = error as? WorkspaceError { return error.localizedDescription }
    if let error = error as? ProviderSetupError { return error.localizedDescription }
    return ProviderError.sanitized(error).localizedDescription
  }

  func makeCoordinator() {
    guard let repository, let credentials, let chatProvider else { return }
    coordinator = GenerationCoordinator(
      repository: repository, credentials: credentials, provider: chatProvider,
      onChange: { [weak self] id in await self?.refreshGeneration(id) },
      onError: { [weak self] message in await self?.setProviderStorageError(message) })
    coordinatorStopped = false
    providerShutdownStarted = false
  }

  private func setProviderStorageError(_ message: String) { storageError = message }

  func refreshGeneration(_ conversationID: UUID) async {
    guard let repository else { return }
    let context = replyContextGeneration
    do {
      let latestGenerations = try await repository.snapshot().generations
      let page = try await repository.messages(conversationID: conversationID, limit: 100)
      guard context == replyContextGeneration,
        conversations.contains(where: { $0.id == conversationID })
      else { return }
      generations = latestGenerations
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
    } catch {
      guard context == replyContextGeneration,
        conversations.contains(where: { $0.id == conversationID })
      else { return }
      storageError = Self.providerErrorMessage(error)
    }
  }

  @discardableResult
  func submitDraft() async throws -> UUID {
    guard !isClosing, !isSubmitting, !isDeletingBot else { throw ProviderSetupError.busy }
    guard !currentNeedsMembershipRepair else { throw WorkspaceError.invalidMembers }
    guard let coordinator, let configuration = selectedProvider else {
      throw ProviderSetupError.noProvider
    }
    guard let conversationID = selectedID else { throw WorkspaceError.missingRecord }
    guard let target = selectedTargetBotID else { throw ProviderSetupError.targetRequired }
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    let replyToID = draftReplyIDs[conversationID]
    guard !text.isEmpty else { throw WorkspaceError.invalidDraft }
    let version = draftVersions[conversationID]
    isSubmitting = true
    defer { isSubmitting = false }
    try await flushDrafts()
    try Task.checkCancellation()
    guard !isClosing else { throw WorkspaceError.storeClosed }
    let id = try await coordinator.submit(
      SendCommand(
        conversationID: conversationID, targetBotID: target, text: text, replyToID: replyToID),
      configuration: configuration)
    if draftVersions[conversationID] == version {
      drafts[conversationID] = ""
      draftReplyIDs[conversationID] = nil
      dirtyDrafts.remove(conversationID)
    } else {
      // Even a new edit with identical text must survive the repository's matching-draft clear.
      scheduleDraftSave(conversationID)
    }
    notice = nil
    await refreshGeneration(conversationID)
    return id
  }

  func cancelReply(_ id: UUID) async throws {
    guard let coordinator, !pendingGenerationActions.contains(id) else {
      throw ProviderSetupError.busy
    }
    pendingGenerationActions.insert(id)
    defer { pendingGenerationActions.remove(id) }
    if let runID = generations.first(where: { $0.id == id })?.routineRunID {
      try await coordinator.cancelRoutine(runID)
    } else {
      try await coordinator.cancel(id)
    }
  }

  func retryReply(_ id: UUID) async throws {
    guard !isClosing, !isDeletingBot, let coordinator, !pendingGenerationActions.contains(id) else {
      throw ProviderSetupError.busy
    }
    guard let configuration = selectedProvider else { throw ProviderSetupError.noProvider }
    pendingGenerationActions.insert(id)
    defer { pendingGenerationActions.remove(id) }
    try await coordinator.retry(id, configuration: configuration)
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
    try await flushDrafts()
    providerShutdownStarted = true
    try await coordinator?.shutdown()
    coordinatorStopped = true
  }

  func resumeAfterCloseFailure() {
    if coordinatorStopped { makeCoordinator() }
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
