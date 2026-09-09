import Foundation
import WorkspaceCore

extension PreviewWorkspace {
  func beginEditing(_ conversation: PreviewConversation) {
    guard !isClosing, !isLoading, !isSaving, !isProfileSaving, !isDeletingBot,
      botDeletionTarget == nil, editTarget == nil, panel == nil,
      routineEditTarget == nil, routineDetailTarget == nil,
      conversations.contains(where: { $0.id == conversation.id })
    else { return }
    switch conversation.kind {
    case .direct:
      guard let id = conversation.memberIDs.first, bots.contains(where: { $0.id == id }) else {
        return
      }
      editTarget = .bot(id)
    case .group:
      editTarget = .group(conversation.id)
    }
    profileEditorDirty = false
  }

  func loadProfile(for target: ProfileEditTarget) async throws -> ProfileEditSnapshot {
    if isPersistent {
      guard let repository else { throw WorkspaceError.storeUnavailable }
      let snapshot = try await repository.snapshot()
      switch target {
      case .bot(let id):
        guard let bot = snapshot.bots.first(where: { $0.id == id }) else {
          throw WorkspaceError.missingRecord
        }
        return .bot(BotProfile(bot))
      case .group(let id):
        guard let group = snapshot.conversations.first(where: { $0.id == id }), group.kind == .group
        else {
          throw WorkspaceError.missingRecord
        }
        return .group(GroupProfile(group))
      }
    }
    switch target {
    case .bot(let id):
      guard let bot = bots.first(where: { $0.id == id }) else { throw WorkspaceError.missingRecord }
      return .bot(
        BotProfile(
          name: bot.name, description: bot.description, color: bot.color,
          shape: AvatarShape(rawValue: bot.shape.rawValue) ?? .circle))
    case .group(let id):
      guard let group = conversations.first(where: { $0.id == id }), group.kind == .group else {
        throw WorkspaceError.missingRecord
      }
      return .group(GroupProfile(title: group.title, memberBotIDs: group.memberIDs))
    }
  }

  /// Only editable fields are compared/written. Unrelated drafts, streaming deltas and visibility
  /// changes must not be overwritten by a long-lived editing sheet.
  func saveProfile(
    for target: ProfileEditTarget, expected: ProfileEditSnapshot,
    replacement: ProfileEditSnapshot
  ) async throws {
    try await startProfileSave(for: target, expected: expected, replacement: replacement).value
  }

  /// Claim the save before returning to AppKit, so close/quit cannot discard an accepted save.
  func startProfileSave(
    for target: ProfileEditTarget, expected: ProfileEditSnapshot,
    replacement: ProfileEditSnapshot
  ) throws -> Task<Void, Error> {
    guard !isClosing, !isProfileSaving else { throw ProviderSetupError.busy }
    isProfileSaving = true
    return Task {
      defer {
        isProfileSaving = false
        let waiters = profileSaveWaiters
        profileSaveWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
      }
      try await applyProfile(for: target, expected: expected, replacement: replacement)
    }
  }

  private func applyProfile(
    for target: ProfileEditTarget, expected: ProfileEditSnapshot,
    replacement: ProfileEditSnapshot
  ) async throws {
    if isPersistent {
      guard let repository else { throw WorkspaceError.storeUnavailable }
      switch (target, expected, replacement) {
      case (.bot(let id), .bot(let old), .bot(let new)):
        try await repository.apply(.editBot(id: id, expected: old, replacement: new))
      case (.group(let id), .group(let old), .group(let new)):
        try await repository.apply(.editGroup(id: id, expected: old, replacement: new))
      default: throw WorkspaceError.identityConflict
      }
      try await refreshPersistent()
    } else {
      guard try await loadProfile(for: target) == expected else {
        throw WorkspaceError.editConflict
      }
      switch (target, expected, replacement) {
      case (.bot(let id), .bot, .bot(let proposed)):
        let profile = try proposed.validated()
        guard let index = bots.firstIndex(where: { $0.id == id }) else {
          throw WorkspaceError.missingRecord
        }
        bots[index].name = profile.name
        bots[index].description = profile.description
        bots[index].color = profile.color
        bots[index].shape = AvatarKind(rawValue: profile.shape.rawValue) ?? .circle
        for index in conversations.indices
        where conversations[index].kind == .direct && conversations[index].memberIDs == [id] {
          conversations[index].title = profile.name
        }
      case (.group(let id), .group(let old), .group(let proposed)):
        let profile = try proposed.validated()
        guard let index = conversations.firstIndex(where: { $0.id == id }) else {
          throw WorkspaceError.missingRecord
        }
        guard
          profile.memberBotIDs.allSatisfy({ member in
            bots.contains { $0.id == member && (!$0.isHidden || old.memberBotIDs.contains(member)) }
          })
        else { throw WorkspaceError.invalidMembers }
        conversations[index].title = profile.title
        conversations[index].memberIDs = profile.memberBotIDs
      default: throw WorkspaceError.identityConflict
      }
    }
    if case .group(let id) = target, let selected = selectedTargetBotIDs[id],
      conversations.first(where: { $0.id == id })?.memberIDs.contains(selected) != true
    {
      selectedTargetBotIDs[id] = nil
    }
  }
}
