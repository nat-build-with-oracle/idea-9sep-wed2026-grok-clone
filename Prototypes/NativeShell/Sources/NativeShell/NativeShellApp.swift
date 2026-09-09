import AppKit
import SwiftUI
import WorkspaceCore

@main struct NativeShellApp {
  @MainActor static func main() {
    let app = NSApplication.shared
    let delegate = ShellAppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    withExtendedLifetime(delegate) { app.run() }
  }
}

@MainActor final class ShellAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  private let store = PreviewWorkspace(seed: false)
  private var persistentRepository: CoreDataWorkspaceRepository?
  private var window: NSWindow?
  private var settingsWindow: NSWindow?
  private var preparingToQuit = false
  private var readyToQuit = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    let arguments = ProcessInfo.processInfo.arguments
    let verifyWorkspace = arguments.contains("--verify-workspace")
    let persistent =
      Bundle.main.bundleIdentifier == "local.independent.BotWorkspace"
      || arguments.contains("--workspace") || verifyWorkspace
    if persistent {
      store.isPersistent = true
      store.isLoading = true
    } else {
      store.seedReference()
    }
    let small = arguments.contains("--small")
    let size = NSSize(width: small ? 800 : 1280, height: small ? 650 : 880)
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.title = persistent ? "Bot Workspace" : "Bot Workspace — Native Feasibility Preview"
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.titlebarSeparatorStyle = .none
    window.backgroundColor = NSColor(ShellTheme.background)
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentMinSize = NSSize(width: 760, height: 600)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: WorkspaceView(store: store))
    self.window = window
    window.delegate = self
    store.openSettingsAction = { [weak self] in self?.showSettings() }
    installMenus()
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)

    if verifyWorkspace {
      verifyDurableWorkspace(small: small, arguments: arguments)
    } else if persistent {
      store.retryOpening = { [weak self] in self?.openWorkspace() }
      openWorkspace()
    }

    if arguments.contains("--picker") { store.openPicker() }
    if arguments.contains("--group"), store.bots.count >= 2 {
      store.openPicker(group: true)
      store.selectRecipient(store.bots[0].id)
      store.selectRecipient(store.bots[1].id)
    }
    // Fixture-only native rendering capture. Does not capture the desktop or another app.
    if arguments.contains("--snapshot") && !persistent {
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
        self?.writeSnapshot(small: small, arguments: arguments)
        NSApp.terminate(nil)
      }
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

  func applicationWillResignActive(_ notification: Notification) {
    Task {
      do { try await store.flushDrafts() } catch { store.storageError = error.localizedDescription }
    }
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !readyToQuit else { return .terminateNow }
    guard !preparingToQuit else { return .terminateCancel }
    store.cancelExportSelection?()
    let recheckProfileAfterSave = store.isProfileSaving
    guard discardProfileChangesIfNeeded() else { return .terminateCancel }
    guard store.isPersistent else { return .terminateNow }
    guard discardProviderChangesIfNeeded() else { return .terminateCancel }
    preparingToQuit = true
    window?.makeFirstResponder(nil)
    store.isClosing = true
    // Do not enter AppKit's terminateLater nested loop while a MainActor task owns this call.
    // Cancel this request, flush asynchronously, then issue a prepared synchronous termination.
    Task {
      do {
        await store.profileEditorSaveTask?.value
        if recheckProfileAfterSave, !discardProfileChangesIfNeeded() {
          preparingToQuit = false
          store.isClosing = false
          return
        }
        try await store.prepareForClose()
        try await persistentRepository?.close()
        readyToQuit = true
        sender.terminate(nil)
      } catch {
        preparingToQuit = false
        store.isClosing = false
        store.resumeAfterCloseFailure()
        store.storageError = error.localizedDescription
        window?.makeKeyAndOrderFront(nil)
      }
    }
    return .terminateCancel
  }

  private func openWorkspace() {
    guard persistentRepository == nil else { return }
    store.isLoading = true
    store.storageError = nil
    Task {
      do {
        let support = try FileManager.default.url(
          for: .applicationSupportDirectory, in: .userDomainMask,
          appropriateFor: nil, create: true)
        let url = support.appendingPathComponent("BotWorkspace/workspace.sqlite")
        let repository = try await CoreDataWorkspaceRepository.open(at: url)
        persistentRepository = repository
        do { try await store.connect(repository) } catch {
          try? await repository.close()
          persistentRepository = nil
          store.repository = nil
          throw error
        }
      } catch { store.storageError = error.localizedDescription }
      store.isLoading = false
    }
  }

  /// Isolated smoke workspace, never the user's normal store. Exercises the real UI service path.
  private func verifyDurableWorkspace(small: Bool, arguments: [String]) {
    Task {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "workspace-smoke-\(UUID())")
      let url = directory.appendingPathComponent("workspace.sqlite")
      do {
        let first = try await CoreDataWorkspaceRepository.open(at: url)
        persistentRepository = first
        try await store.connect(first, displayName: "Smoke workspace")
        let botID = try await store.performCreateBot(
          name: "Research Partner", description: "Smoke fixture", color: "blue", shape: .circle)
        let firstConversationID = store.selectedID
        store.draft = "สวัสดี — this draft survives restart"
        try await store.performAddRoutine(
          name: "Research check", prompt: "Summarize updates", interval: 180)
        let secondID = try await store.performCreateBot(
          name: "Writing Partner", description: "Smoke fixture", color: "magenta", shape: .drop)
        let groupID = try await store.performCreateGroup(
          name: "Project team", members: [botID, secondID])
        try await store.flushDrafts()
        try await first.close()
        var reopened = try await CoreDataWorkspaceRepository.open(at: url)
        persistentRepository = reopened
        try await store.connect(reopened, displayName: "Smoke workspace")
        let snapshot = try await reopened.snapshot()
        guard snapshot.bots.count == 2, snapshot.conversations.count == 3,
          snapshot.routines.count == 1, snapshot.routines.first?.enabled == false,
          snapshot.conversations.contains(where: { $0.id == groupID }),
          snapshot.drafts.first(where: { $0.conversationID == firstConversationID })?.text
            == "สวัสดี — this draft survives restart"
        else {
          throw WorkspaceError.invalidStore
        }
        store.panel = nil
        if arguments.contains("--verify-export") {
          try await verifyExportFlow(
            repository: reopened, conversationID: groupID, botID: botID,
            destination: directory.appendingPathComponent("workspace-export.json"))
          showSettings()
        }
        if arguments.contains("--verify-replies") {
          reopened = try await verifyReplyFlow(
            repository: reopened, url: url, conversationID: groupID, targetID: botID)
        }
        if arguments.contains("--verify-profiles") {
          reopened = try await verifyProfileFlow(
            repository: reopened, url: url,
            botID: botID, groupID: groupID, showGroup: arguments.contains("--edit-group"))
        }
        if arguments.contains("--verify-codex-fixture")
          || arguments.contains("--verify-codex-stdin")
        {
          try await verifyCodexFlow(
            repository: reopened, conversationID: groupID, targetID: botID,
            live: arguments.contains("--verify-codex-stdin"))
          if arguments.contains("--settings") { showSettings() }
        }
        if arguments.contains("--verify-provider") {
          let routerFixture = arguments.contains("--router-models")
          try await verifyProviderFlow(
            repository: reopened, conversationID: groupID, targetID: botID,
            routerFixture: routerFixture)
          if arguments.contains("--settings") {
            let discovery =
              routerFixture ? ModelDiscoveryController(catalog: SmokeRouterModelCatalog()) : nil
            showSettings(discovery: discovery)
            if let discovery {
              // Allow the native view to load its initial form before exercising the injected lookup.
              try await Task.sleep(for: .milliseconds(300))
              await discovery.discover(
                apiRoot: ProviderPreset.nineRouter.apiRoot, allowsLoopbackHTTP: true)?.value
              guard discovery.hasLoaded, discovery.models == SmokeRouterModelCatalog.modelIDs else {
                throw WorkspaceError.invalidStore
              }
              print(
                "NATIVE_MODEL_CATALOG_SMOKE=PASS offlineFixture=true models=3 credentialsSent=false chatRequestsFromDiscovery=0"
              )
            }
          }
        }
        try await Task.sleep(for: .milliseconds(300))
        if arguments.contains("--verify-profiles"), window?.attachedSheet == nil {
          throw WorkspaceError.invalidStore
        }
        writeSnapshot(small: small, arguments: arguments)
        print(
          "NATIVE_PERSISTENCE_SMOKE=PASS bots=2 conversations=3 pausedRoutines=1 restoredDrafts=1")
        try await reopened.close()
        persistentRepository = nil
        store.repository = nil
        try FileManager.default.removeItem(at: directory)
        NSApp.terminate(nil)
      } catch {
        print("NATIVE_PERSISTENCE_SMOKE=FAIL \(error.localizedDescription)")
        try? await persistentRepository?.close()
        persistentRepository = nil
        NSApp.terminate(nil)
      }
    }
  }

  private func verifyExportFlow(
    repository: CoreDataWorkspaceRepository, conversationID: UUID, botID: UUID, destination: URL
  ) async throws {
    let configuration = ProviderConfig(
      name: "Export fixture", apiRoot: URL(string: "https://example.invalid/v1")!,
      modelID: "fixture-model", credentialReference: "session-export-excluded-fixture")
    try await repository.apply(.saveProvider(configuration))
    let command = SendCommand(
      conversationID: conversationID, targetBotID: botID, text: "Export fixture question")
    try await repository.apply(.beginGeneration(command))
    try await repository.apply(
      .applyGenerationEvent(
        GenerationEvent(
          generationID: command.generationID, attemptID: command.attemptID,
          sequence: 1, kind: .started)))
    try await repository.apply(
      .applyGenerationEvent(
        GenerationEvent(
          generationID: command.generationID, attemptID: command.attemptID,
          sequence: 2, kind: .delta("Export fixture answer"))))
    try await repository.apply(
      .applyGenerationEvent(
        GenerationEvent(
          generationID: command.generationID, attemptID: command.attemptID,
          sequence: 3, kind: .completed)))
    store.selectedID = conversationID
    store.draft = "สวัสดี — export includes this unsent draft"
    try Data("Previous fixture export".utf8).write(to: destination)
    guard
      let task = store.performWorkspaceExport(
        destination: SmokeWorkspaceExportDestination(url: destination))
    else { throw WorkspaceError.invalidStore }
    await task.value
    let data = try Data(contentsOf: destination)
    let document = try JSONDecoder().decode(WorkspaceExportDocument.self, from: data)
    guard store.exportError == nil, store.exportStatus != nil,
      document.formatVersion == 1, document.summary.botCount == 2,
      document.summary.conversationCount == 3, document.messages.count == 2,
      document.messages.last?.text == "Export fixture answer",
      document.drafts.contains(where: {
        $0.conversationID == conversationID
          && $0.text == "สวัสดี — export includes this unsent draft"
      }), document.providers.first?.id == configuration.id,
      !String(decoding: data, as: UTF8.self).contains("session-export-excluded-fixture"),
      !String(decoding: data, as: UTF8.self).contains("credentialReference")
    else { throw WorkspaceError.invalidStore }
    print(
      "NATIVE_EXPORT_SMOKE=PASS offlineFixture=true regularFileReplaced=true conversations=3 messages=2 draftFlushed=true storedCredentialsExcluded=true nativeSavePanelSelectionTested=false"
    )
  }

  private func verifyReplyFlow(
    repository: CoreDataWorkspaceRepository, url: URL, conversationID: UUID, targetID: UUID
  ) async throws -> CoreDataWorkspaceRepository {
    let credentials = SessionAwareCredentialStore(persistent: SmokeCredentials())
    let provider = SmokeReplyChatProvider()
    try await store.connect(
      repository, credentials: credentials, provider: provider, displayName: "Smoke workspace")
    _ = try await store.saveProvider(
      id: nil, name: "Offline reply fixture", apiRoot: "https://fixture.invalid/v1",
      modelID: "fixture-text",
      secret: "offline-reply-fixture", allowsLoopbackHTTP: false, credentialLifetime: .session)
    store.selectedID = conversationID
    store.selectedTargetBotIDs[conversationID] = targetID
    store.draft = "Find a fictional source for a short planning draft."
    _ = try await store.submitDraft()
    await store.coordinator?.waitForIdle()
    let firstPage = try await repository.messages(conversationID: conversationID)
    guard let parent = firstPage.messages.last, parent.role == .assistant else {
      throw WorkspaceError.invalidStore
    }
    await store.beginReply(to: parent.id, in: conversationID)
    store.draft = SmokeReplyChatProvider.followUp
    try await store.prepareForClose()
    try await repository.close()
    let reopened = try await CoreDataWorkspaceRepository.open(at: url)
    persistentRepository = reopened
    try await store.connect(
      reopened, credentials: credentials, provider: provider, displayName: "Smoke workspace")
    store.selectedID = conversationID
    store.selectedTargetBotIDs[conversationID] = targetID
    try await store.loadMessages(conversationID)
    guard store.draft == SmokeReplyChatProvider.followUp, store.currentReply?.id == parent.id,
      store.currentReply?.speakerName == "Research Partner", store.currentReply?.isAvailable == true
    else { throw WorkspaceError.invalidStore }
    _ = try await store.submitDraft()
    await store.coordinator?.waitForIdle()
    let page = try await reopened.messages(conversationID: conversationID)
    let snapshot = try await reopened.snapshot()
    guard page.messages.count == 4,
      page.messages.first(where: { $0.text == SmokeReplyChatProvider.followUp })?.replyToID
        == parent.id,
      snapshot.generations.count == 2, snapshot.generations.allSatisfy({ $0.state == .completed }),
      store.draft.isEmpty, store.currentReply == nil,
      snapshot.drafts.first(where: { $0.conversationID == conversationID })?.replyToID == nil,
      let latest = page.messages.last
    else { throw WorkspaceError.invalidStore }
    await store.beginReply(to: latest.id, in: conversationID)
    store.draft = "Keep this next follow-up as a local draft."
    try await store.flushDrafts()
    guard store.currentReply?.id == latest.id else { throw WorkspaceError.invalidStore }
    print(
      "NATIVE_REPLY_SMOKE=PASS offline=true restoredReplyDraft=true sentReference=true providerContext=true matchingDraftCleared=true nextDraftKept=true"
    )
    return reopened
  }

  /// Explicitly injected, offline fixtures, available only in the isolated smoke workspace.
  private func verifyProfileFlow(
    repository: CoreDataWorkspaceRepository, url: URL, botID: UUID, groupID: UUID,
    showGroup: Bool
  ) async throws -> CoreDataWorkspaceRepository {
    let before = try await repository.snapshot()
    guard let originalBot = before.bots.first(where: { $0.id == botID }),
      let originalGroup = before.conversations.first(where: { $0.id == groupID })
    else {
      throw WorkspaceError.invalidStore
    }
    let botEditor = ProfileEditorController(store: store, target: .bot(botID))
    await botEditor.load()?.value
    botEditor.setName("Research Partner Edited")
    botEditor.setDescription("Compare sources and explain tradeoffs clearly.")
    botEditor.setColor("violet")
    botEditor.setShape(.drop)
    await botEditor.save()?.value
    guard botEditor.shouldDismiss, botEditor.errorMessage == nil else {
      throw WorkspaceError.invalidStore
    }
    let groupEditor = ProfileEditorController(store: store, target: .group(groupID))
    await groupEditor.load()?.value
    groupEditor.setName("Edited project team")
    groupEditor.moveMember(from: IndexSet(integer: 0), to: originalGroup.memberBotIDs.count)
    await groupEditor.save()?.value
    guard groupEditor.shouldDismiss, groupEditor.errorMessage == nil else {
      throw WorkspaceError.invalidStore
    }
    store.profileEditorDirty = false
    try await store.prepareForClose()
    try await repository.close()
    let reopened = try await CoreDataWorkspaceRepository.open(at: url)
    persistentRepository = reopened
    try await store.connect(reopened, displayName: "Smoke workspace")
    let snapshot = try await reopened.snapshot()
    guard let bot = snapshot.bots.first(where: { $0.id == botID }),
      let group = snapshot.conversations.first(where: { $0.id == groupID }),
      bot.name == "Research Partner Edited",
      bot.description == "Compare sources and explain tradeoffs clearly.",
      bot.color == "violet", bot.shape == .drop, bot.createdAt == originalBot.createdAt,
      group.title == "Edited project team",
      group.memberBotIDs == Array(originalGroup.memberBotIDs.reversed()),
      group.nextSequence == originalGroup.nextSequence,
      snapshot.routines.count == before.routines.count,
      snapshot.drafts == before.drafts, snapshot.bots.count == before.bots.count,
      snapshot.conversations.count == before.conversations.count,
      let displayed = store.conversations.first(where: {
        showGroup ? $0.id == groupID : $0.kind == .direct && $0.memberIDs == [botID]
      })
    else { throw WorkspaceError.invalidStore }
    store.selectedID = displayed.id
    try await store.loadMessages(displayed.id)
    store.beginEditing(displayed)
    print(
      "NATIVE_PROFILE_SMOKE=PASS botsEdited=1 groupsEdited=1 restarted=true identitiesStable=true draftsKept=true routinesKept=true offline=true"
    )
    return reopened
  }

  private func verifyCodexFlow(
    repository: CoreDataWorkspaceRepository, conversationID: UUID, targetID: UUID, live: Bool
  ) async throws {
    let credential: CodexSessionCredential
    if live {
      // Explicit stdin handoff only. No startup home scan, pathname argument, file copy, or refresh.
      credential = try await Task.detached {
        var data = Data()
        while let chunk = try FileHandle.standardInput.read(upToCount: 16_384), !chunk.isEmpty {
          data.append(chunk)
          guard data.count <= CodexSessionCredential.maximumFileBytes else {
            throw ProviderError.invalidCodexLogin
          }
        }
        return try CodexSessionCredential(authFileData: data)
      }.value
    } else {
      credential = try CodexSessionCredential(
        authFileData: Data(
          "{\"auth_mode\":\"chatgpt\",\"tokens\":{\"access_token\":\"offline-codex-fixture\"}}".utf8
        ))
    }
    let configuration = URLSessionConfiguration.ephemeral
    if !live { configuration.protocolClasses = [SmokeCodexURLProtocol.self] }
    try await store.connect(
      repository,
      credentials: SessionAwareCredentialStore(persistent: SmokeCredentials()),
      provider: ProviderRouter(configuration: configuration), displayName: "Smoke workspace")
    _ = try await store.saveProvider(
      id: nil, name: "Experimental Codex login",
      apiRoot: CodexResponsesProvider.apiRoot.absoluteString,
      modelID: live ? "gpt-5.6-luna" : "offline-model", secret: "", allowsLoopbackHTTP: false,
      credentialLifetime: .session, kind: .codexResponses, codexCredential: credential)
    store.selectedID = conversationID
    store.selectedTargetBotIDs[conversationID] = targetID
    store.draft = "Reply with only READY. This is a text-only compatibility check."
    _ = try await store.submitDraft()
    await store.coordinator?.waitForIdle()
    let snapshot = try await repository.snapshot()
    let page = try await repository.messages(conversationID: conversationID)
    guard snapshot.generations.count == 1, snapshot.generations.first?.state == .completed,
      page.messages.count == 2,
      page.messages.last?.text.trimmingCharacters(in: .whitespacesAndNewlines) == "READY",
      store.currentMessages.last?.speakerName == "Research Partner", store.draft.isEmpty
    else { throw ProviderError.invalidResponse }
    print(
      "NATIVE_CODEX_SMOKE=PASS live=\(live) completed=true attributed=true sessionOnly=true fixedOrigin=true toolsEnabled=false"
    )
  }

  private func verifyProviderFlow(
    repository: CoreDataWorkspaceRepository, conversationID: UUID, targetID: UUID,
    routerFixture: Bool = false
  ) async throws {
    try await store.connect(
      repository, credentials: SessionAwareCredentialStore(persistent: SmokeCredentials()),
      provider: SmokeChatProvider(),
      displayName: "Smoke workspace")
    _ = try await store.saveProvider(
      id: nil, name: routerFixture ? "Offline router fixture" : "Offline fixture provider",
      apiRoot: routerFixture ? ProviderPreset.nineRouter.apiRoot : "https://fixture.invalid/v1",
      modelID: routerFixture ? "glm/smoke-text" : "smoke-text",
      secret: "offline-fixture-credential",
      allowsLoopbackHTTP: routerFixture,
      credentialLifetime: .session)
    store.selectedID = conversationID
    store.selectedTargetBotIDs[conversationID] = targetID
    store.draft = "Summarize this fictional project."
    store.performSend()
    await store.sendTask?.value
    await store.coordinator?.waitForIdle()
    let snapshot = try await repository.snapshot()
    let page = try await repository.messages(conversationID: conversationID)
    guard snapshot.generations.count == 1, snapshot.generations.first?.state == .completed,
      page.messages.count == 2, page.messages.last?.text == SmokeChatProvider.reply,
      store.currentMessages.last?.text == SmokeChatProvider.reply,
      store.currentMessages.last?.speakerName == "Research Partner", store.draft.isEmpty
    else { throw WorkspaceError.invalidStore }
    print(
      "NATIVE_PROVIDER_SMOKE=PASS offlineFixture=true userMessages=1 assistantMessages=1 attributed=true completed=true"
    )
  }

  private func installMenus() {
    let menu = NSMenu()
    let appMenu = NSMenu()
    appMenu.addItem(item("Settings…", #selector(settings), ","))
    appMenu.addItem(.separator())
    appMenu.addItem(
      item("Quit Bot Workspace", #selector(NSApplication.terminate(_:)), "q", target: NSApp))
    menu.addItem(submenu("Bot Workspace", appMenu))

    let file = NSMenu()
    file.addItem(item("New Chat", #selector(newChat), "n"))
    file.addItem(item("Export Workspace…", #selector(exportWorkspace), ""))
    file.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w", target: nil))
    menu.addItem(submenu("File", file))

    let edit = NSMenu()
    for (title, selector, key) in [
      ("Undo", Selector(("undo:")), "z"), ("Cut", #selector(NSText.cut(_:)), "x"),
      ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"),
      ("Select All", #selector(NSText.selectAll(_:)), "a"),
    ] { edit.addItem(item(title, selector, key, target: nil)) }
    edit.addItem(.separator())
    edit.addItem(item("Search Conversations", #selector(search), "f"))
    menu.addItem(submenu("Edit", edit))

    let view = NSMenu()
    view.addItem(item("Toggle Sidebar", #selector(toggleSidebar), ""))
    view.addItem(item("Toggle Details", #selector(toggleDetails), ""))
    menu.addItem(submenu("View", view))
    NSApp.mainMenu = menu
  }

  private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
    item(title, action, key, target: self)
  }
  private func item(_ title: String, _ action: Selector, _ key: String, target: AnyObject?)
    -> NSMenuItem
  {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
    item.target = target
    return item
  }
  private func submenu(_ title: String, _ child: NSMenu) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    child.title = title
    item.submenu = child
    return item
  }

  @objc private func newChat() { store.openPicker() }
  @objc private func settings() { store.openSettings() }
  @objc private func exportWorkspace() {
    guard store.canExportWorkspace else { return }
    showSettings()
    store.exportWorkspace()
  }

  private func showSettings(discovery: ModelDiscoveryController? = nil) {
    guard store.isPersistent else {
      store.panel = .settings
      return
    }
    guard !store.isLoading, !store.isClosing else { return }
    if let settingsWindow {
      settingsWindow.makeKeyAndOrderFront(nil)
      return
    }
    let settings = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 580, height: 740),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
    )
    settings.title = "Bot Workspace Settings"
    settings.contentMinSize = NSSize(width: 520, height: 620)
    settings.isReleasedWhenClosed = false
    settings.appearance = NSAppearance(named: .darkAqua)
    settings.contentView = NSHostingView(
      rootView: ProviderSettingsView(
        store: store, discovery: discovery ?? ModelDiscoveryController()))
    settings.delegate = self
    settingsWindow = settings
    settings.center()
    settings.makeKeyAndOrderFront(nil)
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if sender === window, store.editTarget != nil {
      guard !store.isProfileSaving, discardProfileChangesIfNeeded() else { return false }
      store.editTarget = nil
      store.profileEditorDirty = false
    }
    guard sender === settingsWindow else { return true }
    return !store.isProviderSaving && discardProviderChangesIfNeeded()
  }

  func windowWillClose(_ notification: Notification) {
    guard let closing = notification.object as? NSWindow, closing === settingsWindow else { return }
    closing.contentView = nil
    settingsWindow = nil
    store.providerSettingsDirty = false
  }

  private func discardProviderChangesIfNeeded() -> Bool {
    guard store.providerSettingsDirty, !store.isProviderSaving else { return true }
    let alert = NSAlert()
    alert.messageText = "Discard unsaved provider changes?"
    alert.informativeText = "The entered credential and configuration edits have not been saved."
    alert.addButton(withTitle: "Keep Editing")
    alert.addButton(withTitle: "Discard Changes")
    guard alert.runModal() == .alertSecondButtonReturn else { return false }
    store.providerSettingsDirty = false
    return true
  }
  private func discardProfileChangesIfNeeded() -> Bool {
    guard store.profileEditorDirty, !store.isProfileSaving else { return true }
    let alert = NSAlert()
    alert.messageText = "Discard unsaved profile changes?"
    alert.informativeText =
      "The bot or group edits have not been saved. Conversation messages and drafts will be kept."
    alert.addButton(withTitle: "Keep Editing")
    alert.addButton(withTitle: "Discard Changes")
    // Do not clear dirty state yet: another quit guard may still keep the app open.
    return alert.runModal() == .alertSecondButtonReturn
  }
  @objc private func search() {
    store.sidebarVisible = true
    store.searchFocusRequest += 1
  }
  @objc private func toggleSidebar() { store.sidebarVisible.toggle() }
  @objc private func toggleDetails() { store.inspectorPreferred.toggle() }

  private func writeSnapshot(small: Bool, arguments: [String]) {
    let target =
      arguments.contains("--verify-profiles")
      ? window?.attachedSheet
      : arguments.contains("--settings") || arguments.contains("--verify-export")
        ? settingsWindow : window
    guard let view = target?.contentView?.superview else { return }
    view.layoutSubtreeIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
    let state =
      arguments.contains("--verify-export")
      ? "export-settings"
      : arguments.contains("--verify-profiles")
        ? (arguments.contains("--edit-group") ? "edit-group" : "edit-bot")
        : arguments.contains("--verify-codex-fixture") || arguments.contains("--verify-codex-stdin")
          ? (arguments.contains("--settings") ? "codex-settings" : "codex-chat")
          : arguments.contains("--verify-provider")
            ? (arguments.contains("--settings")
              ? (arguments.contains("--router-models")
                ? "router-model-settings" : "provider-settings")
              : "provider-chat")
            : arguments.contains("--verify-replies")
              ? "reply-chat"
              : arguments.contains("--verify-workspace")
                ? "durable-workspace"
                : arguments.contains("--group")
                  ? "group" : arguments.contains("--picker") ? "picker" : "chat"
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(
      "native-shell-\(small ? "small" : "desktop")-\(state).png")
    do {
      try data.write(to: file)
      print("NATIVE_SNAPSHOT=\(file.path)")
    } catch { print("Snapshot failed: \(error.localizedDescription)") }
  }
}
