import AppKit
import Combine
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
  private let store: PreviewWorkspace
  private let preferenceFixtureSuite: String?
  private var appearanceSubscription: AnyCancellable?

  override init() {
    let arguments = ProcessInfo.processInfo.arguments
    let durable =
      Bundle.main.bundleIdentifier == "local.independent.BotWorkspace"
      || arguments.contains("--workspace")
    let isolated = arguments.contains("--verify-workspace")
    preferenceFixtureSuite =
      isolated && arguments.contains("--verify-appearance")
      ? "NativeAppearanceSmoke-\(UUID())" : nil
    let defaults =
      preferenceFixtureSuite.flatMap { UserDefaults(suiteName: $0) }
      ?? (durable && !isolated ? UserDefaults.standard : nil)
    store = PreviewWorkspace(
      seed: false,
      preferencesStorage: WorkspacePreferencesStorage(defaults: defaults))
    super.init()
  }
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
    appearanceSubscription = store.$preferences.map(\.appearance).removeDuplicates().sink {
      [weak self] appearance in self?.applyAppearance(appearance)
    }
    let small = arguments.contains("--small") || arguments.contains("--minimum")
    let minimum = verifyWorkspace && arguments.contains("--minimum")
    let size = NSSize(
      width: minimum ? 760 : small ? 800 : 1280, height: minimum ? 600 : small ? 650 : 880)
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.title = persistent ? "Bot Workspace" : "Bot Workspace — Native Feasibility Preview"
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.titlebarSeparatorStyle = .none
    window.backgroundColor = ShellTheme.backgroundNSColor
    window.appearance = nil
    window.contentMinSize = NSSize(width: 760, height: 600)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: WorkspaceView(store: store))
    self.window = window
    window.delegate = self
    store.openSettingsAction = { [weak self] in self?.showSettings() }
    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(workspaceWillSleep(_:)), name: NSWorkspace.willSleepNotification,
      object: nil)
    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(workspaceDidWake(_:)), name: NSWorkspace.didWakeNotification,
      object: nil)
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

  private func applyAppearance(_ appearance: WorkspaceAppearance) {
    switch appearance {
    case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
    case .light: NSApp.appearance = NSAppearance(named: .aqua)
    case .system: NSApp.appearance = nil
    }
    // Nil inherits the app's appearance; System must clear every former override.
    window?.appearance = nil
    settingsWindow?.appearance = nil
    window?.backgroundColor = ShellTheme.backgroundNSColor
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

  func applicationWillResignActive(_ notification: Notification) {
    store.workspaceIsForeground = false
    Task {
      do { try await store.flushDrafts() } catch { store.storageError = error.localizedDescription }
    }
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    updateReadingVisibility()
  }

  func windowDidBecomeKey(_ notification: Notification) {
    if let key = notification.object as? NSWindow, key === window {
      updateReadingVisibility()
    } else {
      store.workspaceIsForeground = false
    }
  }
  func windowDidResignKey(_ notification: Notification) {
    if let resigning = notification.object as? NSWindow, resigning === window {
      store.workspaceIsForeground = false
    }
  }
  func windowDidMiniaturize(_ notification: Notification) {
    if let minimized = notification.object as? NSWindow, minimized === window {
      store.workspaceIsForeground = false
    }
  }
  func windowDidDeminiaturize(_ notification: Notification) { updateReadingVisibility() }

  private func updateReadingVisibility() {
    store.workspaceIsForeground =
      NSApp.isActive && window?.isKeyWindow == true && window?.isVisible == true
      && window?.isMiniaturized == false
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !readyToQuit else { return .terminateNow }
    guard !preparingToQuit else { return .terminateCancel }
    store.cancelExportSelection?()
    store.cancelBotDeletion()
    let recheckRoutineAfterSave = store.isRoutineSaving
    guard discardRoutineChangesIfNeeded() else { return .terminateCancel }
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
        await store.routineEditorSaveTask?.value
        if recheckRoutineAfterSave, !discardRoutineChangesIfNeeded() {
          preparingToQuit = false
          store.isClosing = false
          return
        }
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
        try await store.prepareForClose()
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
        if arguments.contains("--verify-unread") {
          reopened = try await verifyUnreadFlow(
            repository: reopened, url: url, conversationID: firstConversationID!, botID: botID,
            otherBotID: secondID, small: small, arguments: arguments)
        }
        if arguments.contains("--verify-attachments") {
          reopened = try await verifyAttachmentFlow(
            repository: reopened, url: url, conversationID: groupID, targetID: botID,
            directory: directory, small: small, arguments: arguments)
        }
        if arguments.contains("--verify-appearance") {
          reopened = try await verifyAppearanceFlow(
            repository: reopened, url: url, conversationID: groupID, targetID: botID,
            small: small, arguments: arguments)
        }
        if arguments.contains("--verify-routines") {
          reopened = try await verifyRoutineFlow(
            repository: reopened, url: url, botID: botID, groupID: groupID,
            small: small, arguments: arguments)
        }
        if arguments.contains("--verify-deletion") {
          reopened = try await verifyBotDeletionFlow(
            repository: reopened, url: url, botID: botID, otherBotID: secondID,
            directConversationID: firstConversationID!, groupID: groupID, small: small,
            arguments: arguments)
        }
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
        if arguments.contains("--verify-group-rounds") {
          try await verifyGroupRoundFlow(
            repository: reopened, conversationID: groupID,
            orderedTargetIDs: [secondID, botID], small: small, arguments: arguments)
        }
        if arguments.contains("--verify-mentions") {
          try await verifyMentionFlow(
            repository: reopened, conversationID: groupID,
            manualTargetIDs: [botID, secondID], mentionedTargetIDs: [secondID, botID],
            small: small, arguments: arguments)
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
        let finalSnapshot = try await reopened.snapshot()
        print(
          "NATIVE_PERSISTENCE_SMOKE=PASS bots=\(finalSnapshot.bots.count) conversations=\(finalSnapshot.conversations.count) pausedRoutines=\(finalSnapshot.routines.filter { !$0.enabled }.count) restoredDrafts=1"
        )
        try await store.prepareForClose()
        try await reopened.close()
        persistentRepository = nil
        store.repository = nil
        try FileManager.default.removeItem(at: directory)
        cleanupPreferenceFixture()
        NSApp.terminate(nil)
      } catch {
        print("NATIVE_PERSISTENCE_SMOKE=FAIL \(error.localizedDescription)")
        cleanupPreferenceFixture()
        try? await persistentRepository?.close()
        persistentRepository = nil
        NSApp.terminate(nil)
      }
    }
  }

  private func cleanupPreferenceFixture() {
    guard let suite = preferenceFixtureSuite else { return }
    UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
  }

  /// Exercises the real preference write/appearance propagation with an isolated suite.
  /// No OS appearance preference, user workspace, or real credential is modified.
  private func verifyUnreadFlow(
    repository: CoreDataWorkspaceRepository, url: URL, conversationID: UUID, botID: UUID,
    otherBotID: UUID, small: Bool, arguments: [String]
  ) async throws -> CoreDataWorkspaceRepository {
    let fixtureForeground = arguments.contains("--fixture-foreground")
    guard
      let otherID = store.conversations.first(where: {
        $0.kind == .direct && $0.memberIDs == [otherBotID]
      })?.id
    else { throw UnreadSmokeFailure(stage: "missing-other") }
    // Strict smoke requires real window focus. The explicit fixture flag is only
    // used by this isolated verifier when the host console is locked.
    showSettings()
    if fixtureForeground {
      store.workspaceIsForeground = false
    } else {
      let settingsDeadline = Date().addingTimeInterval(5)
      while settingsWindow?.isKeyWindow != true || store.workspaceIsForeground,
        Date() < settingsDeadline
      {
        try await Task.sleep(for: .milliseconds(10))
      }
      guard settingsWindow?.isKeyWindow == true, !store.workspaceIsForeground else {
        throw UnreadSmokeFailure(
          stage:
            "settings-key-window active=\(NSApp.isActive) settingsKey=\(settingsWindow?.isKeyWindow == true) mainKey=\(window?.isKeyWindow == true) foreground=\(store.workspaceIsForeground)"
        )
      }
    }
    for (id, owner, text) in [
      (
        conversationID, botID,
        "A new offline reply — สวัสดี. This stays unread while Settings is active."
      ),
      (otherID, otherBotID, "An unopened chat also has a saved preview and unread reply."),
    ] {
      let command = SendCommand(
        conversationID: id, targetBotID: owner, text: "Synthetic unread fixture")
      try await repository.apply(.beginGeneration(command))
      for (sequence, kind): (Int64, GenerationEvent.Kind) in [
        (1, .started), (2, .delta(text)), (3, .completed),
      ] {
        try await repository.apply(
          .applyGenerationEvent(
            GenerationEvent(
              generationID: command.generationID, attemptID: command.attemptID,
              sequence: sequence, kind: kind)))
      }
    }
    try await store.refreshPersistent()
    store.selectedID = conversationID
    try await store.loadMessages(conversationID)
    store.draft = "Keep this unread-workflow draft 👩🏽‍💻"
    try await store.flushDrafts()
    try await Task.sleep(for: .milliseconds(150))
    guard store.lastReadSequences[conversationID] == 0,
      store.conversationActivity[conversationID]?.unreadAssistantCount == 1,
      store.conversationActivity[otherID]?.unreadAssistantCount == 1,
      store.messages[otherID] == nil
    else { throw UnreadSmokeFailure(stage: "background-counts") }
    for appearance in [WorkspaceAppearance.dark, .light] {
      store.preferences.appearance = appearance
      try await Task.sleep(for: .milliseconds(100))
      writeSnapshot(small: small, arguments: arguments + ["--unread-\(appearance.rawValue)-before"])
    }
    settingsWindow?.performClose(nil)
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    if fixtureForeground { store.workspaceIsForeground = true }
    let deadline = Date().addingTimeInterval(5)
    while store.lastReadSequences[conversationID] != 2, Date() < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    guard store.workspaceIsForeground, store.lastReadSequences[conversationID] == 2,
      store.conversationActivity[conversationID]?.unreadAssistantCount == 0,
      store.conversationActivity[otherID]?.unreadAssistantCount == 1,
      store.draft == "Keep this unread-workflow draft 👩🏽‍💻", store.readStatusError == nil
    else { throw UnreadSmokeFailure(stage: "foreground-rendered") }
    try await Task.sleep(for: .milliseconds(100))
    writeSnapshot(small: small, arguments: arguments + ["--unread-after"])
    try await store.prepareForClose()
    try await repository.close()
    let reopened = try await CoreDataWorkspaceRepository.open(at: url)
    persistentRepository = reopened
    try await store.connect(reopened, displayName: "Smoke workspace")
    guard store.lastReadSequences[conversationID] == 2,
      store.conversationActivity[conversationID]?.unreadAssistantCount == 0,
      store.conversationActivity[otherID]?.unreadAssistantCount == 1,
      store.drafts[conversationID] == "Keep this unread-workflow draft 👩🏽‍💻"
    else { throw UnreadSmokeFailure(stage: "restart") }
    store.selectedID = conversationID
    try await store.loadMessages(conversationID)
    print(
      "NATIVE_UNREAD_SMOKE=PASS foregroundSource=\(fixtureForeground ? "fixture" : "window") actualWindowFocusTested=\(!fixtureForeground) backgroundRetainsUnread=true unopenedPreview=true foregroundRenderedRead=true otherChatRetained=true restartRetained=true physicalInputTested=false"
    )
    return reopened
  }

  private func verifyAppearanceFlow(
    repository: CoreDataWorkspaceRepository, url: URL, conversationID: UUID, targetID: UUID,
    small: Bool, arguments: [String]
  ) async throws -> CoreDataWorkspaceRepository {
    guard let suite = preferenceFixtureSuite, let defaults = UserDefaults(suiteName: suite) else {
      throw WorkspaceError.invalidStore
    }
    try await verifyProviderFlow(
      repository: repository, conversationID: conversationID, targetID: targetID)
    let baseline = try await repository.snapshot()
    let retainedText = "Keep this draft — สวัสดี"
    store.draft = retainedText
    store.preferences.sidebarWidth = 400
    store.preferences.inspectorWidth = 400
    showSettings()
    for appearance in [WorkspaceAppearance.light, .dark, .system, .light] {
      var edit = AppearanceSettingsDraft(store.preferences)
      edit.appearance = appearance
      store.preferences = edit.applying(to: store.preferences)
      let expected: NSAppearance.Name? =
        appearance == .system ? nil : appearance == .dark ? .darkAqua : .aqua
      let deadline = ContinuousClock.now.advanced(by: .seconds(5))
      while NSApp.appearance?.name != expected || window?.appearance != nil
        || settingsWindow?.appearance != nil
      {
        guard ContinuousClock.now < deadline else { throw WorkspaceError.invalidStore }
        try await Task.sleep(for: .milliseconds(10))
      }
      guard store.draft == retainedText, store.currentMessages.count == 2 else {
        throw WorkspaceError.invalidStore
      }
      if let expected {
        guard window?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected,
          settingsWindow?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected
        else { throw WorkspaceError.invalidStore }
      }
      // Layout settlement is only for fixture rendering, not a performance assertion.
      try await Task.sleep(for: .milliseconds(100))
      writeSnapshot(small: small, arguments: arguments + ["--appearance-\(appearance.rawValue)"])
      writeSnapshot(
        small: small, arguments: arguments + ["--settings", "--appearance-\(appearance.rawValue)"])
    }
    let persisted = WorkspacePreferencesStorage(defaults: defaults).load()
    guard persisted == store.preferences, persisted.appearance == .light,
      persisted.sidebarWidth == 400, persisted.inspectorWidth == 400,
      let window
    else { throw WorkspaceError.invalidStore }
    let layout = WorkspaceLayout(
      containerWidth: Double(window.contentLayoutRect.width), preferences: persisted,
      pickerOpen: false)
    if arguments.contains("--minimum") {
      guard layout.sidebarWidth == 335, !layout.showsInspector else {
        throw WorkspaceError.invalidStore
      }
    }
    try await store.prepareForClose()
    try await repository.close()
    let reopened = try await CoreDataWorkspaceRepository.open(at: url)
    persistentRepository = reopened
    try await store.connect(reopened, displayName: "Appearance smoke workspace")
    store.selectedID = conversationID
    store.selectedTargetBotIDs[conversationID] = [targetID]
    try await store.loadMessages(conversationID)
    let after = try await reopened.snapshot()
    guard after.bots == baseline.bots, after.providers == baseline.providers,
      after.generations == baseline.generations, store.draft == retainedText,
      store.preferences == persisted, store.currentMessages.count == 2
    else { throw WorkspaceError.invalidStore }
    print(
      "NATIVE_APPEARANCE_SMOKE=PASS isolatedPreferences=true lightDarkSystem=true appAndSettingsInherited=true preferencesRestored=true draftsAndMessagesPreserved=true savedWidthsPreserved=true minimumLayout=\(arguments.contains("--minimum")) physicalInputTested=false"
    )
    return reopened
  }

  /// Exercises explicit file selection, managed persistence and disclosure with synthetic local
  /// input and an injected provider. It never opens NSOpenPanel, reads user files, or uses a key.
  private func verifyAttachmentFlow(
    repository: CoreDataWorkspaceRepository, url: URL, conversationID: UUID, targetID: UUID,
    directory: URL, small: Bool, arguments: [String]
  ) async throws -> CoreDataWorkspaceRepository {
    let credentialReference = "attachment-smoke-memory-only"
    let credentials = SmokeAttachmentCredentials(
      reference: credentialReference, value: Data("offline-attachment-key".utf8))
    let provider = SmokeAttachmentProvider()
    let configuration = ProviderConfig(
      name: "Offline attachment fixture", apiRoot: URL(string: "https://fixture.invalid/v1")!,
      modelID: "attachment-fixture", credentialReference: credentialReference)
    try await repository.apply(.saveProvider(configuration))
    try await store.connect(
      repository, credentials: credentials, provider: provider,
      displayName: "Attachment smoke workspace")
    store.selectedID = conversationID
    store.selectedTargetBotIDs[conversationID] = [targetID]
    try await store.loadMessages(conversationID)

    let body = "Synthetic attachment body — สวัสดี\nSecond line."
    let selectedURL = directory.appendingPathComponent("selected-attachment-smoke.txt")
    try Data(body.utf8).write(to: selectedURL, options: .atomic)
    let chooser = SmokeAttachmentChooser(urls: [selectedURL])
    store.draft = "Read the attached synthetic note."
    guard let importTask = store.performAttachmentImport(chooser: chooser) else {
      throw AttachmentSmokeFailure(stage: "import-start")
    }
    await importTask.value
    guard chooser.chooseCount == 1, store.attachmentImportFailure == nil,
      let attachmentID = store.currentDraftAttachmentIDs.first,
      store.currentDraftAttachmentIDs.count == 1,
      let imported = try? await repository.attachmentContent(id: attachmentID),
      imported.data == Data(body.utf8),
      imported.attachment.originalName == selectedURL.lastPathComponent
    else { throw AttachmentSmokeFailure(stage: "managed-copy") }
    try FileManager.default.removeItem(at: selectedURL)
    guard !FileManager.default.fileExists(atPath: selectedURL.path) else {
      throw AttachmentSmokeFailure(stage: "original-delete")
    }

    try await store.prepareForClose()
    try await repository.close()
    let reopened = try await CoreDataWorkspaceRepository.open(at: url)
    persistentRepository = reopened
    try await store.connect(
      reopened, credentials: credentials, provider: provider,
      displayName: "Attachment smoke workspace")
    store.selectedID = conversationID
    store.selectedTargetBotIDs[conversationID] = [targetID]
    try await store.loadMessages(conversationID)
    await store.refreshAttachmentMetadata(in: conversationID, retryUnavailable: true)
    guard store.currentDraftAttachmentIDs == [attachmentID],
      store.attachmentMetadata[attachmentID] == imported.attachment,
      (try await reopened.attachmentContent(id: attachmentID)) == imported
    else { throw AttachmentSmokeFailure(stage: "restart") }

    try await store.prepareSendOrConfirmAttachments()
    try await waitForAttachmentSmoke("first-confirmation") {
      self.store.attachmentConfirmationTarget?.plan.attachments == [imported.attachment]
        && self.window?.attachedSheet != nil
    }
    try await Task.sleep(for: .milliseconds(100))
    writeSnapshot(small: small, arguments: arguments + ["--attachment-confirmation"])
    store.cancelAttachmentConfirmation()
    try await waitForAttachmentSmoke("cancel-dismissed") {
      self.store.attachmentConfirmationTarget == nil && self.window?.attachedSheet == nil
    }
    guard await credentials.readCount() == 0, provider.callCount == 0 else {
      throw AttachmentSmokeFailure(stage: "cancel-effects")
    }

    try await store.prepareSendOrConfirmAttachments()
    try await waitForAttachmentSmoke("second-confirmation") {
      self.store.attachmentConfirmationTarget != nil && self.window?.attachedSheet != nil
    }
    guard let send = store.confirmAttachmentSend() else {
      throw AttachmentSmokeFailure(stage: "confirm-start")
    }
    await send.value
    await store.coordinator?.waitForIdle()
    guard let request = provider.lastRequest else {
      throw AttachmentSmokeFailure(stage: "request")
    }
    let userText = request.turns.filter { $0.role == "user" }.map(\.content).joined(separator: "\n")
    let page = try await reopened.messages(conversationID: conversationID)
    let snapshot = try await reopened.snapshot()
    try await store.loadMessages(conversationID)
    await store.refreshAttachmentMetadata(in: conversationID, retryUnavailable: true)
    guard await credentials.readCount() == 1, provider.callCount == 1,
      userText.components(separatedBy: body).count - 1 == 1,
      userText.contains(imported.attachment.sha256), store.currentDraftAttachmentIDs.isEmpty,
      store.draft.isEmpty,
      !snapshot.drafts.contains(where: { $0.conversationID == conversationID }),
      page.messages.first(where: { $0.role == .user && $0.attachmentIDs == [attachmentID] }) != nil,
      store.currentMessages.first(where: {
        $0.role == .user && $0.attachmentIDs == [attachmentID]
      }) != nil,
      store.attachmentMetadata[attachmentID] == imported.attachment
    else { throw AttachmentSmokeFailure(stage: "confirmed-send") }
    print(
      "NATIVE_ATTACHMENT_SMOKE=PASS offlineFixture=true injectedChooser=true nativePanelSelectionTested=false managedCopySurvivedOriginalDeletion=true restarted=true chipsRestored=true confirmationCancelledWithoutEffects=true explicitConfirmationSent=true exactBodyOnce=true matchingDraftCleared=true storedMessageChips=true"
    )
    return reopened
  }

  private func waitForAttachmentSmoke(
    _ stage: String, condition: @MainActor () -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while !condition() {
      guard clock.now < deadline else { throw AttachmentSmokeFailure(stage: stage) }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private func verifyBotDeletionFlow(
    repository: CoreDataWorkspaceRepository, url: URL, botID: UUID, otherBotID: UUID,
    directConversationID: UUID, groupID: UUID, small: Bool, arguments: [String]
  ) async throws -> CoreDataWorkspaceRepository {
    // All state is in verifyDurableWorkspace's synthetic temporary store, never the user's store.
    try await verifyProviderFlow(
      repository: repository, conversationID: groupID, targetID: botID, routerFixture: false)
    let before = try await repository.snapshot()
    store.selectedID = groupID
    store.draft = "Keep this group draft after deleting one member"
    await store.beginBotDeletion(botID)?.value
    guard let plan = store.botDeletionPlan, plan.directConversationCount == 1,
      plan.routineCount == 1, plan.affectedGroupCount == 1
    else { throw WorkspaceError.invalidStore }
    try await Task.sleep(for: .milliseconds(300))
    guard window?.attachedSheet != nil else { throw WorkspaceError.invalidStore }
    writeSnapshot(small: small, arguments: arguments + ["--deletion-confirmation"])
    guard let deletion = store.confirmBotDeletion() else { throw WorkspaceError.invalidStore }
    await deletion.value
    guard store.botDeletionError == nil, store.botDeletionTarget == nil else {
      throw WorkspaceError.invalidStore
    }
    try await store.prepareForClose()
    try await repository.close()
    let reopened = try await CoreDataWorkspaceRepository.open(at: url)
    persistentRepository = reopened
    try await store.connect(reopened, displayName: "Deletion smoke workspace")
    store.selectedID = groupID
    try await store.loadMessages(groupID)
    let snapshot = try await reopened.snapshot()
    let page = try await reopened.messages(conversationID: groupID)
    guard snapshot.bots.count == 1, snapshot.bots.first?.id == otherBotID,
      snapshot.conversations.count == 2, snapshot.routines.isEmpty,
      !snapshot.conversations.contains(where: { $0.id == directConversationID }),
      snapshot.providers == before.providers,
      snapshot.conversations.first(where: { $0.id == groupID })?.memberBotIDs == [otherBotID],
      store.currentNeedsMembershipRepair, page.messages.count == 2,
      page.messages.last?.speakerNameSnapshot == "Research Partner",
      store.draft == "Keep this group draft after deleting one member"
    else { throw WorkspaceError.invalidStore }
    print(
      "NATIVE_DELETION_SMOKE=PASS offlineFixture=true botDeleted=true directConversationDeleted=true ownedRoutineDeleted=true groupHistoryKept=true sharedProviderKept=true degradedGroupReadable=true restarted=true"
    )
    return reopened
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
      document.formatVersion == WorkspaceExportDocument.currentFormatVersion,
      document.summary.botCount == 2,
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
    store.selectedTargetBotIDs[conversationID] = [targetID]
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
    store.selectedTargetBotIDs[conversationID] = [targetID]
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

  /// Exercises native editor/controller and run controls with a synthetic provider/store only.
  private func verifyRoutineFlow(
    repository: CoreDataWorkspaceRepository, url: URL, botID: UUID, groupID: UUID,
    small: Bool, arguments: [String]
  ) async throws -> CoreDataWorkspaceRepository {
    let credentials = SmokeCredentials()
    let provider = ProviderConfig(
      name: "Offline routine fixture", apiRoot: URL(string: "https://fixture.invalid/v1")!,
      modelID: "routine-fixture", credentialReference: "routine-smoke")
    await credentials.write(Data("offline-routine-fixture".utf8), for: provider.credentialReference)
    try await repository.apply(.saveProvider(provider))
    try await store.connect(repository, credentials: credentials, provider: SmokeChatProvider())
    store.selectedID = groupID
    store.beginRoutineEditing()
    guard let target = store.routineEditTarget, target.preferredOwnerID == nil else {
      throw RoutineSmokeFailure(stage: "create-target")
    }
    let editor = RoutineEditorController(store: store, target: target)
    await editor.load()?.value
    editor.setOwnerID(botID)
    editor.setName("Daily project check-in")
    editor.setPrompt("Summarize the fictional project's progress and one next step.")
    editor.setTriggerKind(.daily)
    editor.setDailyHour(9)
    editor.setDailyMinute(15)
    editor.setTimezoneID("Asia/Bangkok")
    editor.setProviderID(provider.id)
    editor.setAuthorizedTransmission(true)
    await editor.save()?.value
    guard editor.shouldDismiss, editor.errorMessage == nil,
      let routine = try await repository.snapshot().routines.first(where: {
        $0.name == "Daily project check-in"
      })
    else { throw RoutineSmokeFailure(stage: "editor-save") }
    store.routineEditTarget = nil
    store.routineEditorDirty = false
    // Wait for actual sheet transitions, not a guessed animation duration.
    await Task.yield()
    try await waitForRoutineSmoke("create-sheet-dismissed") { self.window?.attachedSheet == nil }
    store.beginRoutineEditing(routine)
    try await waitForRoutineSmoke("editor-render") {
      self.store.routineEditTarget?.routineID == routine.id && self.window?.attachedSheet != nil
    }
    try await Task.sleep(for: .milliseconds(150))
    writeSnapshot(small: small, arguments: arguments + ["--routine-editor"])
    store.routineEditTarget = nil
    store.routineEditorDirty = false
    await Task.yield()
    try await waitForRoutineSmoke("editor-dismissed") { self.window?.attachedSheet == nil }
    store.draft = "Keep the group's draft during the routine run."
    try await store.flushDrafts()
    try await store.startRoutineRunNow(routine, authorizedTransmission: true).value
    await store.coordinator?.waitForIdle()
    let history = try await repository.routineRuns(routineID: routine.id)
    guard history.count == 1, history.first?.status == .completed,
      history.first?.ownerBotID == botID, history.first?.conversationID != groupID,
      store.draft == "Keep the group's draft during the routine run."
    else { throw RoutineSmokeFailure(stage: "run-completed") }
    // Resume through the same detached editor and consent gate, then explicitly pause.
    store.beginRoutineEditing(routine)
    guard let resumeTarget = store.routineEditTarget else {
      throw RoutineSmokeFailure(stage: "resume-target")
    }
    let resumeEditor = RoutineEditorController(store: store, target: resumeTarget)
    await resumeEditor.load()?.value
    resumeEditor.setEnabled(true)
    resumeEditor.setAuthorizedTransmission(true)
    await resumeEditor.save()?.value
    guard resumeEditor.shouldDismiss, resumeEditor.errorMessage == nil,
      let enabled = try await repository.snapshot().routines.first(where: { $0.id == routine.id }),
      enabled.enabled, enabled.nextRunAt != nil
    else { throw RoutineSmokeFailure(stage: "resume-save") }
    store.routineEditTarget = nil
    store.routineEditorDirty = false
    try await store.startRoutinePause(enabled).value
    try await store.prepareForClose()
    try await repository.close()
    let reopened = try await CoreDataWorkspaceRepository.open(at: url)
    persistentRepository = reopened
    try await store.connect(reopened, credentials: credentials, provider: SmokeChatProvider())
    await store.routineHost?.waitForReconciliation()
    let restored = try await reopened.routineRuns(routineID: routine.id)
    guard restored == history,
      let paused = store.routineDefinitions.first(where: { $0.id == routine.id }), !paused.enabled,
      paused.trigger == .daily(hour: 9, minute: 15), paused.timezoneID == "Asia/Bangkok"
    else { throw RoutineSmokeFailure(stage: "restart") }
    store.selectedID = groupID
    store.openRoutine(routine.id)
    await store.routineHistoryTask?.value
    // The detail view starts its own refresh. Its newer request deliberately supersedes
    // the first task, so that task finishing does not prove the visible projection is ready.
    try await waitForRoutineSmoke("history-projection") {
      self.store.routineDetailTarget?.id == routine.id && self.store.routineHistory == history
        && self.window?.attachedSheet != nil
    }
    print(
      "NATIVE_ROUTINE_SMOKE=PASS offline=true explicitGroupOwner=true dailyEditor=true runNow=true directOutput=true groupDraftKept=true resumePause=true historyRestored=true"
    )
    return reopened
  }

  private func waitForRoutineSmoke(_ stage: String, condition: @MainActor () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while !condition() {
      guard clock.now < deadline else { throw RoutineSmokeFailure(stage: stage) }
      try await Task.sleep(for: .milliseconds(10))
    }
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
    store.selectedTargetBotIDs[conversationID] = [targetID]
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
    store.selectedTargetBotIDs[conversationID] = [targetID]
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

  /// Offline, isolated exercise of the native ordered-recipient disclosure and send path.
  /// It leaves a second reviewed round visible so the normal snapshot captures the minimum UI.
  private func verifyGroupRoundFlow(
    repository: CoreDataWorkspaceRepository, conversationID: UUID, orderedTargetIDs: [UUID],
    small: Bool, arguments: [String]
  ) async throws {
    try await store.connect(
      repository, credentials: SessionAwareCredentialStore(persistent: SmokeCredentials()),
      provider: SmokeChatProvider(), displayName: "Smoke workspace")
    _ = try await store.saveProvider(
      id: nil, name: "Offline group fixture", apiRoot: "https://fixture.invalid/v1",
      modelID: "smoke-round", secret: "offline-fixture-credential",
      allowsLoopbackHTTP: false, credentialLifetime: .session)
    store.selectedID = conversationID
    store.selectedTargetBotIDs[conversationID] = orderedTargetIDs
    store.draft = "Review this fictional launch plan in order."
    store.performSend()
    await store.sendTask?.value
    guard let disclosure = store.attachmentConfirmationTarget,
      disclosure.isRound, disclosure.requestCount == 2,
      disclosure.targetBots == ["Writing Partner", "Research Partner"]
    else { throw WorkspaceError.invalidStore }
    guard let accepted = store.confirmAttachmentSend() else { throw WorkspaceError.invalidStore }
    await accepted.value
    await store.coordinator?.waitForIdle()

    let snapshot = try await repository.snapshot()
    let page = try await repository.messages(conversationID: conversationID)
    let generations = snapshot.generations.filter { $0.roundIndex != nil }.sorted {
      $0.roundIndex! < $1.roundIndex!
    }
    let userMessages = page.messages.filter { $0.role == .user }
    let replies = page.messages.filter { $0.role == .assistant }
    guard generations.count == 2,
      generations.map(\.targetBotID) == orderedTargetIDs,
      generations.allSatisfy({ $0.state == .completed }), userMessages.count == 1,
      replies.map(\.speakerBotID) == orderedTargetIDs,
      replies.map(\.speakerNameSnapshot) == ["Writing Partner", "Research Partner"]
    else { throw WorkspaceError.invalidStore }

    let longNames = [
      "Architecture & Safety — กรุงเทพมหานคร",
      "ข้อมูลและหลักฐาน — Data Evidence Reviewer",
      "Release Reliability — naïve café audit 🔎",
      "การเข้าถึงและประสบการณ์ผู้ใช้ — Accessibility",
      "Privacy Boundary Reviewer — München & Zürich",
      "Final Synthesis Partner — 東京・กรุงเทพฯ",
    ]
    var displayTargets: [UUID] = []
    for (index, name) in longNames.enumerated() {
      displayTargets.append(
        try await store.performCreateBot(
          name: name, description: "Offline group disclosure fixture \(index + 1)",
          color: index.isMultiple(of: 2) ? "blue" : "magenta",
          shape: index.isMultiple(of: 2) ? .circle : .square))
    }
    let displayConversation = try await store.performCreateGroup(
      name: "International six-member review board", members: displayTargets)
    store.selectedTargetBotIDs[displayConversation] = displayTargets
    store.draft = "A six-member round is staged only for this native disclosure snapshot."
    let originalAppearance = store.preferences.appearance
    for appearance in [WorkspaceAppearance.light, .dark] {
      store.preferences.appearance = appearance
      try await Task.sleep(for: .milliseconds(100))
      writeSnapshot(
        small: small,
        arguments: arguments + [
          "--group-composer",
          appearance == .light ? "--group-composer-light" : "--group-composer-dark",
        ])
    }
    store.preferences.appearance = originalAppearance
    store.performSend()
    await store.sendTask?.value
    guard store.attachmentConfirmationTarget?.isRound == true,
      store.attachmentConfirmationTarget?.requestCount == 6,
      store.attachmentConfirmationTarget?.targetBots == longNames
    else {
      throw WorkspaceError.invalidStore
    }
    print(
      "NATIVE_GROUP_ROUND_SMOKE=PASS offlineFixture=true orderedTargets=2 separateRequests=2 oneUserMessage=true attributedReplies=2 explicitConfirmation=true stopPreservesCompletedCoveredByTests=true renderedDisclosureRecipients=6 minimumComposerLightDark=true physicalInputTested=false"
    )
  }

  /// Offline, isolated exercise of typed identity-bound group mention routing and disclosure.
  private func verifyMentionFlow(
    repository: CoreDataWorkspaceRepository, conversationID: UUID, manualTargetIDs: [UUID],
    mentionedTargetIDs: [UUID], small: Bool, arguments: [String]
  ) async throws {
    try await store.connect(
      repository, credentials: SessionAwareCredentialStore(persistent: SmokeCredentials()),
      provider: SmokeChatProvider(), displayName: "Smoke workspace")
    _ = try await store.saveProvider(
      id: nil, name: "Offline mention fixture", apiRoot: "https://fixture.invalid/v1",
      modelID: "smoke-mentions", secret: "offline-fixture-credential",
      allowsLoopbackHTTP: false, credentialLifetime: .session)
    store.selectedID = conversationID
    store.selectedTargetBotIDs[conversationID] = manualTargetIDs
    let members = store.currentMentionMembers
    func token(_ id: UUID) throws -> String {
      guard let member = members.first(where: { $0.id == id }) else {
        throw WorkspaceError.invalidMembers
      }
      return try GroupMentions.token(for: member)
    }

    // Even one mention is an explicit routed round and must stop at disclosure first.
    store.draft = try "\(token(mentionedTargetIDs[0])) Review this fictional plan."
    store.performSend()
    await store.sendTask?.value
    guard let singleDisclosure = store.attachmentConfirmationTarget,
      singleDisclosure.isRound, singleDisclosure.mentionRouting != nil,
      singleDisclosure.targetBotIDs == [mentionedTargetIDs[0]], singleDisclosure.requestCount == 1
    else { throw WorkspaceError.invalidStore }
    store.cancelAttachmentConfirmation()
    await Task.yield()

    // Typed order overrides the deliberately opposite manual selection.
    let readableMessage = "Review this fictional launch plan in typed order."
    let orderedMentionPrefix = try mentionedTargetIDs.map(token).joined(separator: " ")
    let mentionDraft = "\(orderedMentionPrefix) \(readableMessage)"
    let expectedStoredText = GroupMentions.resolve(mentionDraft, members: members).messageText
    store.draft = mentionDraft
    let originalAppearance = store.preferences.appearance
    for appearance in [WorkspaceAppearance.light, .dark] {
      store.preferences.appearance = appearance
      try await Task.sleep(for: .milliseconds(100))
      writeSnapshot(
        small: small,
        arguments: arguments + [
          appearance == .light ? "--mention-composer-light" : "--mention-composer-dark"
        ])
    }
    store.preferences.appearance = originalAppearance
    store.performSend()
    await store.sendTask?.value
    guard let disclosure = store.attachmentConfirmationTarget,
      disclosure.isRound, disclosure.mentionRouting != nil,
      disclosure.targetBotIDs == mentionedTargetIDs, disclosure.requestCount == 2
    else { throw WorkspaceError.invalidStore }
    guard let accepted = store.confirmAttachmentSend() else { throw WorkspaceError.invalidStore }
    await accepted.value
    await store.coordinator?.waitForIdle()

    let page = try await repository.messages(conversationID: conversationID)
    let userMessages = page.messages.filter { $0.role == .user }
    let replies = page.messages.filter { $0.role == .assistant }
    guard userMessages.count == 1, replies.count == mentionedTargetIDs.count,
      replies.map(\.speakerBotID) == mentionedTargetIDs,
      userMessages[0].text == expectedStoredText,
      !mentionedTargetIDs.contains(where: {
        userMessages[0].text.lowercased().contains($0.uuidString.lowercased())
      }),
      store.draft.isEmpty
    else { throw WorkspaceError.invalidStore }

    // Equal display names remain distinct through canonical IDs and disclosure labels.
    let duplicateName = "Twin Reviewer — ผู้ตรวจคู่"
    var duplicateIDs: [UUID] = []
    for index in 0...1 {
      duplicateIDs.append(
        try await store.performCreateBot(
          name: duplicateName, description: "Duplicate mention fixture \(index + 1)",
          color: index == 0 ? "blue" : "magenta", shape: index == 0 ? .circle : .square))
    }
    let duplicateConversation = try await store.performCreateGroup(
      name: "Identity-bound duplicate reviewers", members: duplicateIDs)
    store.selectedTargetBotIDs[duplicateConversation] = Array(duplicateIDs.reversed())
    let duplicateMembers = store.currentMentionMembers
    let duplicateTokens = try duplicateIDs.map { id in
      guard let member = duplicateMembers.first(where: { $0.id == id }) else {
        throw WorkspaceError.invalidMembers
      }
      return try GroupMentions.token(for: member)
    }
    store.draft = duplicateTokens.joined(separator: " ") + " Compare the fictional proposal."
    store.performSend()
    await store.sendTask?.value
    guard let duplicateDisclosure = store.attachmentConfirmationTarget,
      duplicateDisclosure.mentionRouting != nil,
      duplicateDisclosure.targetBotIDs == duplicateIDs,
      duplicateDisclosure.targetBots.count == 2,
      duplicateDisclosure.targetBots[0] != duplicateDisclosure.targetBots[1],
      duplicateDisclosure.targetBots.allSatisfy({ $0.hasPrefix("\(duplicateName) · ") })
    else { throw WorkspaceError.invalidStore }
    for appearance in [WorkspaceAppearance.light, .dark] {
      store.preferences.appearance = appearance
      try await Task.sleep(for: .milliseconds(150))
      writeSnapshot(
        small: small,
        arguments: arguments + [
          appearance == .light ? "--mention-confirmation-light" : "--mention-confirmation-dark"
        ])
    }
    store.cancelAttachmentConfirmation()
    await Task.yield()

    // Unknown handles fail closed inline and never fall back to the manual recipient list.
    store.draft = "@unknown Review the fictional proposal."
    guard store.currentMentionResolution?.issues.first == .unknownMember,
      store.effectiveTargetBotIDs.isEmpty
    else { throw WorkspaceError.invalidStore }
    for appearance in [WorkspaceAppearance.light, .dark] {
      store.preferences.appearance = appearance
      try await Task.sleep(for: .milliseconds(100))
      writeSnapshot(
        small: small,
        arguments: arguments + [
          appearance == .light ? "--mention-invalid-light" : "--mention-invalid-dark"
        ])
    }
    store.preferences.appearance = originalAppearance
    print(
      "NATIVE_MENTION_SMOKE=PASS offlineFixture=true typedOrderOverridesManual=true singleMentionRequiresReview=true oneUserMessage=true orderedAttributedReplies=2 storedUserHasNoUUIDSuffix=true duplicateNamesIDDisambiguated=true invalidMentionInlineError=true actualPhysicalInputTested=false"
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
    // Size relative to the visible screen instead of a fixed 580x740, so the
    // window has room to show the full form (Connection/Provider fields included)
    // without relying on scroll gestures that some input methods don't deliver
    // reliably to this NSHostingView. Clamped to the view's own minSize below
    // and a sane upper bound so it doesn't balloon on very large displays.
    let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
    let settingsWidth = min(max(screenFrame.width * 0.55, 520), 900)
    // Use nearly the full visible height (minus a small margin so the title
    // bar and traffic lights aren't flush against the menu bar) rather than a
    // fixed fraction — on a small display (e.g. 1280x800 points) 85% of the
    // screen is smaller than this window used to be by default, defeating the
    // point of sizing to the screen at all.
    let settingsHeight = min(max(screenFrame.height - 40, 620), 1200)
    let settings = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: settingsWidth, height: settingsHeight),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
    )
    settings.title = "Bot Workspace Settings"
    settings.contentMinSize = NSSize(width: 520, height: 620)
    settings.isReleasedWhenClosed = false
    settings.appearance = nil
    settings.contentView = NSHostingView(
      rootView: ProviderSettingsView(
        store: store, discovery: discovery ?? ModelDiscoveryController()))
    settings.delegate = self
    settingsWindow = settings
    settings.center()
    settings.makeKeyAndOrderFront(nil)
  }

  @objc private func workspaceWillSleep(_ notification: Notification) {
    store.routineHost?.suspend()
  }
  @objc private func workspaceDidWake(_ notification: Notification) { store.routineHost?.wake() }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if sender === window, store.routineEditTarget != nil {
      guard !store.isRoutineSaving, discardRoutineChangesIfNeeded() else { return false }
      store.routineEditTarget = nil
      store.routineEditorDirty = false
    }
    if sender === window, store.botDeletionTarget != nil {
      guard !store.isDeletingBot else { return false }
      store.cancelBotDeletion()
    }
    if sender === window, store.editTarget != nil {
      guard !store.isProfileSaving, discardProfileChangesIfNeeded() else { return false }
      store.editTarget = nil
      store.profileEditorDirty = false
    }
    guard sender === settingsWindow else { return true }
    return !store.isProviderSaving && discardProviderChangesIfNeeded()
  }

  func windowWillClose(_ notification: Notification) {
    if let closing = notification.object as? NSWindow, closing === window {
      store.workspaceIsForeground = false
    }
    guard let closing = notification.object as? NSWindow, closing === settingsWindow else { return }
    closing.contentView = nil
    settingsWindow = nil
    store.providerSettingsDirty = false
    store.appearanceSettingsDirty = false
  }

  private func discardProviderChangesIfNeeded() -> Bool {
    guard store.providerSettingsDirty || store.appearanceSettingsDirty else { return true }
    guard !store.isProviderSaving else { return false }
    let alert = NSAlert()
    alert.messageText = "Discard unsaved Settings changes?"
    alert.informativeText =
      "Unsaved appearance and provider edits, including any entered credential, will be discarded."
    alert.addButton(withTitle: "Keep Editing")
    alert.addButton(withTitle: "Discard Changes")
    guard alert.runModal() == .alertSecondButtonReturn else { return false }
    // Keep dirty state until the window actually closes. A later draft/storage
    // failure may cancel termination and leave these edit buffers visible.
    return true
  }
  private func discardRoutineChangesIfNeeded() -> Bool {
    guard store.routineEditorDirty, !store.isRoutineSaving else { return true }
    let alert = NSAlert()
    alert.messageText = "Discard unsaved routine changes?"
    alert.informativeText =
      "The routine edits and authorization changes have not been saved. Existing runs and chat messages are kept."
    alert.addButton(withTitle: "Keep Editing")
    alert.addButton(withTitle: "Discard Changes")
    return alert.runModal() == .alertSecondButtonReturn
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
    let groupComposer = arguments.contains("--group-composer")
    let mentionConfirmation =
      arguments.contains("--mention-confirmation-light")
      || arguments.contains("--mention-confirmation-dark")
    let mentionState = arguments.last { $0.hasPrefix("--mention-") }
    let target =
      groupComposer || (mentionState != nil && !mentionConfirmation)
      ? window
      : mentionConfirmation || arguments.contains("--verify-profiles")
        || arguments.contains("--deletion-confirmation")
        || arguments.contains("--verify-routines")
        || arguments.contains("--attachment-confirmation")
        || arguments.contains("--verify-group-rounds")
        ? window?.attachedSheet
        : arguments.contains("--settings") || arguments.contains("--verify-export")
          ? settingsWindow : window
    guard let view = target?.contentView?.superview else { return }
    view.layoutSubtreeIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
    let appearanceState = arguments.last { $0.hasPrefix("--appearance-") }
    let state: String
    if let mentionState {
      state = String(mentionState.dropFirst(2))
    } else {
      state =
        groupComposer
        ? (arguments.contains("--group-composer-light")
          ? "group-composer-light" : "group-composer-dark")
        : arguments.last(where: { $0.hasPrefix("--unread-") }).map { String($0.dropFirst(2)) }
          ?? appearanceState.map {
            String($0.dropFirst(2))
              + (arguments.contains("--settings") ? "-settings" : "-workspace")
          }
          ?? (arguments.contains("--attachment-confirmation")
            ? "attachment-confirmation"
            : arguments.contains("--verify-group-rounds")
              ? "group-round-confirmation"
              : arguments.contains("--verify-routines")
                ? (arguments.contains("--routine-editor") ? "routine-editor" : "routine-history")
                : arguments.contains("--deletion-confirmation")
                  ? "delete-confirmation"
                  : arguments.contains("--verify-deletion")
                    ? "degraded-group"
                    : arguments.contains("--verify-export")
                      ? "export-settings"
                      : arguments.contains("--verify-profiles")
                        ? (arguments.contains("--edit-group") ? "edit-group" : "edit-bot")
                        : arguments.contains("--verify-codex-fixture")
                          || arguments.contains("--verify-codex-stdin")
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
                                  ? "group" : arguments.contains("--picker") ? "picker" : "chat")
    }
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(
      "native-shell-\(small ? "small" : "desktop")-\(state).png")
    do {
      try data.write(to: file)
      print("NATIVE_SNAPSHOT=\(file.path)")
    } catch { print("Snapshot failed: \(error.localizedDescription)") }
  }
}

private struct RoutineSmokeFailure: LocalizedError {
  let stage: String
  var errorDescription: String? { "Offline routine smoke failed at \(stage)." }
}

private struct UnreadSmokeFailure: LocalizedError {
  let stage: String
  var errorDescription: String? { "Offline unread smoke failed at \(stage)." }
}
