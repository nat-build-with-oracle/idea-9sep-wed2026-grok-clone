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

@MainActor final class ShellAppDelegate: NSObject, NSApplicationDelegate {
  private let store = PreviewWorkspace(seed: false)
  private var persistentRepository: CoreDataWorkspaceRepository?
  private var window: NSWindow?
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
    guard store.isPersistent, !readyToQuit else { return .terminateNow }
    guard !preparingToQuit else { return .terminateCancel }
    preparingToQuit = true
    window?.makeFirstResponder(nil)
    store.isClosing = true
    // Do not enter AppKit's terminateLater nested loop while a MainActor task owns this call.
    // Cancel this request, flush asynchronously, then issue a prepared synchronous termination.
    Task {
      do {
        try await store.flushDrafts()
        try await persistentRepository?.close()
        readyToQuit = true
        sender.terminate(nil)
      } catch {
        preparingToQuit = false
        store.isClosing = false
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
        try await store.connect(first)
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
        let reopened = try await CoreDataWorkspaceRepository.open(at: url)
        persistentRepository = reopened
        try await store.connect(reopened)
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
        try await Task.sleep(for: .milliseconds(300))
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
    file.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w", target: window))
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
  @objc private func settings() { store.panel = .settings }
  @objc private func search() {
    store.sidebarVisible = true
    store.searchFocusRequest += 1
  }
  @objc private func toggleSidebar() { store.sidebarVisible.toggle() }
  @objc private func toggleDetails() { store.inspectorPreferred.toggle() }

  private func writeSnapshot(small: Bool, arguments: [String]) {
    guard let view = window?.contentView?.superview else { return }
    view.layoutSubtreeIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
    let state =
      arguments.contains("--verify-workspace")
      ? "durable-workspace"
      : arguments.contains("--group") ? "group" : arguments.contains("--picker") ? "picker" : "chat"
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(
      "native-shell-\(small ? "small" : "desktop")-\(state).png")
    do {
      try data.write(to: file)
      print("NATIVE_SNAPSHOT=\(file.path)")
    } catch { print("Snapshot failed: \(error.localizedDescription)") }
  }
}
