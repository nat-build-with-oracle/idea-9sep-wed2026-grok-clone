import Foundation
import WorkspaceCore

enum ProviderSetupError: Error, LocalizedError {
  case noProvider, targetRequired, busy, changedDestination, changedCredentialLifetime
  var errorDescription: String? {
    switch self {
    case .noProvider: "Choose a provider in Settings before sending. Your draft is kept."
    case .targetRequired: "Choose which bot should reply to this group message."
    case .busy: "Wait for the current save to finish, then try again."
    case .changedDestination:
      "The destination changed. Re-enter the key to authorize its use with this API root."
    case .changedCredentialLifetime:
      "The credential storage choice changed. Re-enter the key; saved credentials are never copied between storage modes."
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
    do {
      generations = try await repository.snapshot().generations
      let page = try await repository.messages(conversationID: conversationID, limit: 100)
      // Keep older pages already loaded; update deltas by stable message identity.
      var existing = messages[conversationID] ?? []
      for item in page.messages {
        let role: PreviewMessage.Role =
          item.role == .user ? .user : item.role == .assistant ? .assistant : .event
        let projected = PreviewMessage(
          role, item.text,
          timestamp: item.createdAt.formatted(date: .abbreviated, time: .shortened),
          id: item.id, speakerName: item.speakerNameSnapshot)
        if let index = existing.firstIndex(where: { $0.id == item.id }) {
          existing[index] = projected
        } else {
          existing.append(projected)
        }
      }
      messages[conversationID] = existing
    } catch { storageError = Self.providerErrorMessage(error) }
  }

  @discardableResult
  func submitDraft() async throws -> UUID {
    guard !isClosing, !isSubmitting else { throw ProviderSetupError.busy }
    guard let coordinator, let configuration = selectedProvider else {
      throw ProviderSetupError.noProvider
    }
    guard let conversationID = selectedID else { throw WorkspaceError.missingRecord }
    guard let target = selectedTargetBotID else { throw ProviderSetupError.targetRequired }
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { throw WorkspaceError.invalidDraft }
    let version = draftVersions[conversationID]
    isSubmitting = true
    defer { isSubmitting = false }
    try await flushDrafts()
    try Task.checkCancellation()
    guard !isClosing else { throw WorkspaceError.storeClosed }
    let id = try await coordinator.submit(
      SendCommand(conversationID: conversationID, targetBotID: target, text: text),
      configuration: configuration)
    if draftVersions[conversationID] == version {
      drafts[conversationID] = ""
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
    try await coordinator.cancel(id)
  }

  func retryReply(_ id: UUID) async throws {
    guard !isClosing, let coordinator, !pendingGenerationActions.contains(id) else {
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
    allowsLoopbackHTTP: Bool, credentialLifetime: CredentialLifetime? = nil
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
    guard (1...80).contains(cleanName.count),
      let root = URL(string: apiRoot.trimmingCharacters(in: .whitespacesAndNewlines))
    else { throw WorkspaceError.invalidProvider }
    let replacement = !secret.isEmpty
    guard replacement || old != nil else { throw ProviderError.missingCredential }
    if replacement {
      guard secret.utf8.count <= 16_384, !secret.contains(where: { $0.isNewline || $0 == "\0" }),
        !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { throw ProviderError.invalidCredential }
    }
    let lifetime =
      credentialLifetime ?? old.map { CredentialLifetime.forReference($0.credentialReference) }
      ?? .keychain
    if let old, !replacement, lifetime != CredentialLifetime.forReference(old.credentialReference) {
      throw ProviderSetupError.changedCredentialLifetime
    }
    let reference = replacement ? lifetime.makeReference() : old!.credentialReference
    let configuration = ProviderConfig(
      id: old?.id ?? UUID(), name: cleanName, apiRoot: root,
      modelID: modelID.trimmingCharacters(in: .whitespacesAndNewlines),
      credentialReference: reference, allowsLoopbackHTTP: allowsLoopbackHTTP)
    _ = try ProviderEndpoint.chatCompletions(configuration)
    if let old, old.apiRoot != configuration.apiRoot, !replacement {
      throw ProviderSetupError.changedDestination
    }
    if replacement { try await credentials.write(Data(secret.utf8), for: reference) }
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
