import Foundation
import WorkspaceCore

extension PreviewWorkspace {
  func connect(_ repository: any WorkspaceRepository) async throws {
    isPersistent = true
    isLoading = true
    defer { isLoading = false }
    self.repository = repository
    name = UserDefaults.standard.string(forKey: "workspace.displayName") ?? "Your workspace"
    // Never silently replay an unfinished request after restart.
    try await repository.apply(.interruptPendingGenerations)
    try await refreshPersistent()
    selectedID = conversations.first?.id
    if let selectedID { try await loadMessages(selectedID) }
  }

  func refreshPersistent() async throws {
    guard let repository else { throw WorkspaceError.storeUnavailable }
    let snapshot = try await repository.snapshot()
    bots = snapshot.bots.map { bot in
      var projected = PreviewBot(
        id: bot.id, name: bot.name, description: bot.description,
        color: bot.color, shape: AvatarKind(rawValue: bot.shape.rawValue) ?? .circle)
      projected.isHidden = bot.hiddenAt != nil
      return projected
    }
    conversations = snapshot.conversations.sorted { $0.createdAt > $1.createdAt }.map {
      PreviewConversation(
        id: $0.id, title: $0.title, kind: $0.kind == .direct ? .direct : .group,
        memberIDs: $0.memberBotIDs)
    }
    for draft in snapshot.drafts where !dirtyDrafts.contains(draft.conversationID) {
      drafts[draft.conversationID] = draft.text
    }
    routines = snapshot.routines.map { routine in
      let minutes: Int
      switch routine.trigger {
      case .interval(let value): minutes = value
      case .daily: minutes = 1440
      }
      return PreviewRoutine(
        id: routine.id, botID: routine.ownerBotID, name: routine.name,
        intervalMinutes: minutes, enabled: routine.enabled)
    }
    storageError = nil
    if !search.isEmpty { await searchPersistent() }
  }

  func loadMessages(_ id: UUID) async throws {
    guard let repository else { return }
    let page = try await repository.messages(conversationID: id, limit: 100)
    messages[id] = page.messages.map(projectMessage)
    if selectedID == id {
      hasOlderMessages = page.hasMore
      olderCursor = page.beforeSequence
    }
  }

  func searchPersistent() async {
    guard isPersistent, let repository else { return }
    searchRequest += 1
    let request = searchRequest
    let query = search
    do {
      let results = try await repository.search(query, includeHidden: showHidden)
      guard request == searchRequest, query == search else { return }
      persistentSearchIDs = Set(results.map(\.id))
    } catch { storageError = error.localizedDescription }
  }

  func loadOlderMessages() async {
    guard let repository, let id = selectedID, let before = olderCursor else { return }
    do {
      let page = try await repository.messages(
        conversationID: id, beforeSequence: before, limit: 100)
      guard id == selectedID else { return }
      messages[id] = page.messages.map(projectMessage) + (messages[id] ?? [])
      hasOlderMessages = page.hasMore
      olderCursor = page.beforeSequence
    } catch { storageError = error.localizedDescription }
  }

  private func projectMessage(_ message: Message) -> PreviewMessage {
    let role: PreviewMessage.Role
    switch message.role {
    case .user: role = .user
    case .assistant: role = .assistant
    case .event: role = .event
    }
    return PreviewMessage(
      role, message.text,
      timestamp: message.createdAt.formatted(date: .abbreviated, time: .shortened), id: message.id)
  }

  func scheduleDraftSave(_ id: UUID) {
    dirtyDrafts.insert(id)
    draftVersions[id, default: 0] += 1
    draftSaveTask?.cancel()
    draftSaveTask = Task { [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(300))
        try Task.checkCancellation()
        try await self?.flushDrafts()
      } catch is CancellationError {} catch { self?.storageError = error.localizedDescription }
    }
  }

  func flushDrafts() async throws {
    guard isPersistent, let repository else { return }
    while !dirtyDrafts.isEmpty {
      for id in Array(dirtyDrafts) {
        let version = draftVersions[id]
        let draft = Draft(conversationID: id, text: drafts[id] ?? "")
        try await repository.apply(.saveDraft(draft))
        if version == draftVersions[id] { dirtyDrafts.remove(id) }
      }
    }
    if dirtyDrafts.isEmpty { storageError = nil }
  }

  @discardableResult func performCreateBot(
    name: String, description: String, color: String, shape: AvatarKind
  ) async throws -> UUID {
    guard isPersistent else {
      return try createBot(name: name, description: description, color: color, shape: shape)
    }
    guard let repository else { throw WorkspaceError.storeUnavailable }
    let bot = Bot(
      name: name, description: description, color: color,
      shape: AvatarShape(rawValue: shape.rawValue) ?? .circle)
    let conversationID = UUID()
    try await repository.apply(.createBot(bot, conversationID: conversationID))
    try await refreshPersistent()
    try await selectCreatedConversation(conversationID)
    panel = nil
    return bot.id
  }

  @discardableResult func performCreateGroup(name: String, members: [UUID]) async throws -> UUID {
    guard isPersistent else { return try createGroup(name: name, members: members) }
    guard let repository else { throw WorkspaceError.storeUnavailable }
    let group = Conversation(kind: .group, title: name, memberBotIDs: members)
    try await repository.apply(.createGroup(group))
    try await refreshPersistent()
    try await selectCreatedConversation(group.id)
    return group.id
  }

  func performToggleHidden(_ conversation: PreviewConversation) async {
    guard isPersistent else {
      toggleHidden(conversation)
      return
    }
    guard let repository, conversation.kind == .direct,
      let bot = bots.first(where: { $0.id == conversation.memberIDs.first })
    else { return }
    do {
      try await repository.apply(.setHidden(botID: bot.id, at: bot.isHidden ? nil : Date()))
      try await refreshPersistent()
    } catch { storageError = error.localizedDescription }
  }

  func performAddRoutine(name: String, prompt: String, interval: Int) async throws {
    guard isPersistent else {
      try addRoutine(name: name, interval: interval)
      return
    }
    guard let repository, let bot = currentBot else { throw WorkspaceError.missingRecord }
    let routine = Routine(
      ownerBotID: bot.id, name: name, prompt: prompt, trigger: .interval(minutes: interval),
      timezoneID: TimeZone.current.identifier, enabled: false)
    try await repository.apply(.saveRoutine(routine))
    try await refreshPersistent()
    panel = nil
    notice = "Paused routine saved. Scheduling is not connected yet."
  }

  func performSend() {
    guard isPersistent else {
      do { try saveLocalMessage() } catch { notice = error.localizedDescription }
      return
    }
    // The provider core is not connected to this UI yet. Preserve the editable draft.
    notice = "No AI provider is connected. Your draft is saved locally; no message has been sent."
    Task { do { try await flushDrafts() } catch { storageError = error.localizedDescription } }
  }

  func saveDisplayName(_ value: String) {
    name = value
    if isPersistent { UserDefaults.standard.set(value, forKey: "workspace.displayName") }
  }

  private func selectCreatedConversation(_ id: UUID) async throws {
    try await flushDrafts()
    selectionRequest += 1
    selectedID = id
    pickerMode = .closed
    notice = nil
    composerFocusRequest += 1
    try await loadMessages(id)
  }
}
