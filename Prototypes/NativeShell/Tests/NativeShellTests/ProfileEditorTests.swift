import AppKit
import XCTest

@testable import NativeShell
@testable import WorkspaceCore

@MainActor
final class ProfileEditorTests: XCTestCase {
  func testSheetAllowsApplicationDelegateToOwnTerminationChecks() {
    _ = NSApplication.shared
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 520, height: 500),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    XCTAssertTrue(window.preventsApplicationTerminationWhenModal)
    window.contentView = ProfileSheetPolicyView()
    XCTAssertFalse(window.preventsApplicationTerminationWhenModal)
    window.close()
  }

  func testBotValidationMatchesCoreAndSuccessfulSaveUsesTrimmedProfile() async throws {
    let id = UUID()
    let original = BotProfile(
      name: "Helper", description: "Notes", color: "green", shape: .circle)
    let service = ImmediateProfileService(snapshot: .bot(original))
    let controller = ProfileEditorController(service: service, target: .bot(id))
    try await XCTUnwrap(controller.load()).value

    controller.setName("   ")
    XCTAssertEqual(controller.validationMessage, WorkspaceError.invalidName.localizedDescription)
    XCTAssertFalse(controller.canSave)
    controller.setName("  Renamed  ")
    controller.setDescription(String(repeating: "x", count: 8_001))
    XCTAssertEqual(
      controller.validationMessage, WorkspaceError.invalidDescription.localizedDescription)
    controller.setDescription("Updated")

    try await XCTUnwrap(controller.save()).value

    XCTAssertEqual(service.savedTargets, [.bot(id)])
    XCTAssertEqual(service.savedExpected, [.bot(original)])
    XCTAssertEqual(
      service.savedReplacements,
      [.bot(BotProfile(name: "Renamed", description: "Updated", color: "green", shape: .circle))])
    XCTAssertFalse(controller.isDirty)
    XCTAssertFalse(service.profileEditorDirty)
    XCTAssertTrue(controller.shouldDismiss)
  }

  func testCancelKeepsWorkspaceUnchangedAndRequiresDirtyConfirmation() async throws {
    let original = BotProfile(name: "One", description: "", color: "blue", shape: .square)
    let service = ImmediateProfileService(snapshot: .bot(original))
    let controller = ProfileEditorController(service: service, target: .bot(UUID()))
    try await XCTUnwrap(controller.load()).value
    controller.setName("Unsaved")

    controller.requestCancel()
    XCTAssertTrue(controller.isConfirmingDiscard)
    XCTAssertFalse(controller.shouldDismiss)
    XCTAssertTrue(service.savedReplacements.isEmpty)
    XCTAssertTrue(service.profileEditorDirty)

    controller.confirmDiscard()
    XCTAssertTrue(controller.shouldDismiss)
    XCTAssertTrue(service.savedReplacements.isEmpty)
  }

  func testSaveFailurePreservesDraftAndReloadRequiresExplicitDiscard() async throws {
    let original = GroupProfile(title: "Team", memberBotIDs: [Self.one, Self.two])
    let latest = GroupProfile(title: "Server title", memberBotIDs: [Self.one, Self.two])
    let service = ImmediateProfileService(snapshot: .group(original))
    service.saveError = WorkspaceError.editConflict
    let controller = ProfileEditorController(service: service, target: .group(UUID()))
    try await XCTUnwrap(controller.load()).value
    controller.setName("My title")

    try await XCTUnwrap(controller.save()).value
    XCTAssertEqual(controller.name, "My title")
    XCTAssertTrue(controller.isDirty)
    XCTAssertFalse(controller.shouldDismiss)
    XCTAssertEqual(controller.errorMessage, WorkspaceError.editConflict.localizedDescription)

    service.snapshot = .group(latest)
    XCTAssertNil(controller.requestReload())
    XCTAssertTrue(controller.isConfirmingReload)
    try await XCTUnwrap(controller.confirmReload()).value
    XCTAssertEqual(controller.name, "Server title")
    XCTAssertFalse(controller.isDirty)
    XCTAssertFalse(service.profileEditorDirty)
  }

  func testEditingDuringInFlightSaveKeepsNewerDraftOpen() async throws {
    let original = BotProfile(name: "Bot", description: "", color: "green", shape: .circle)
    let service = SuspendedSaveService(snapshot: .bot(original))
    let controller = ProfileEditorController(service: service, target: .bot(UUID()))
    try await XCTUnwrap(controller.load()).value
    controller.setName("Submitted")
    let save = try XCTUnwrap(controller.save())
    await service.waitForSave()

    controller.setDescription("Typed while saving")
    service.finishSave()
    await save.value

    XCTAssertFalse(controller.shouldDismiss)
    XCTAssertTrue(controller.isDirty)
    XCTAssertEqual(controller.descriptionText, "Typed while saving")
    XCTAssertEqual(controller.errorMessage, "Saved. Newer edits remain in this form.")
  }

  func testLateLoadCannotOverwriteNewerLoad() async throws {
    let service = SuspendedLoadService()
    let target = ProfileEditTarget.bot(UUID())
    let controller = ProfileEditorController(service: service, target: target)
    let first = try XCTUnwrap(controller.load())
    await service.waitForLoadCount(1)
    let second = try XCTUnwrap(controller.requestReload())
    await service.waitForLoadCount(2)

    service.finishLoad(
      1, with: .bot(BotProfile(name: "New", description: "", color: "blue", shape: .circle)))
    await second.value
    service.finishLoad(
      0, with: .bot(BotProfile(name: "Old", description: "", color: "green", shape: .circle)))
    await first.value

    XCTAssertEqual(controller.name, "New")
    XCTAssertFalse(controller.isDirty)
  }

  func testCancelWhileLoadingRejectsLateResultAndClearsSharedDirtyState() async throws {
    let service = SuspendedLoadService()
    let controller = ProfileEditorController(service: service, target: .bot(UUID()))
    let load = try XCTUnwrap(controller.load())
    await service.waitForLoadCount(1)

    controller.requestCancel()
    service.finishLoad(
      0,
      with: .bot(BotProfile(name: "Late", description: "", color: "green", shape: .circle)))
    await load.value

    XCTAssertTrue(controller.shouldDismiss)
    XCTAssertNil(controller.baseline)
    XCTAssertEqual(controller.name, "")
    XCTAssertFalse(service.profileEditorDirty)
  }

  func testGroupMembersStayOrderedAndHiddenBotCannotBeReadded() async throws {
    let service = ImmediateProfileService(
      snapshot: .group(
        GroupProfile(title: "Team", memberBotIDs: [Self.one, Self.two, Self.hidden])))
    let controller = ProfileEditorController(service: service, target: .group(UUID()))
    try await XCTUnwrap(controller.load()).value

    controller.removeMember(Self.hidden)
    controller.addMember(Self.hidden)
    XCTAssertEqual(controller.memberIDs, [Self.one, Self.two])
    controller.addMember(Self.three)
    XCTAssertEqual(controller.memberIDs, [Self.one, Self.two, Self.three])
    controller.moveMember(from: IndexSet(integer: 2), to: 0)
    XCTAssertEqual(controller.memberIDs, [Self.three, Self.one, Self.two])
    XCTAssertNil(controller.validationMessage)
  }

  private static let one = UUID()
  private static let two = UUID()
  private static let three = UUID()
  private static let hidden = UUID()
  fileprivate static let bots = [
    PreviewBot(id: one, name: "One"), PreviewBot(id: two, name: "Two"),
    PreviewBot(id: three, name: "Three"),
    {
      var bot = PreviewBot(id: hidden, name: "Hidden")
      bot.isHidden = true
      return bot
    }(),
  ]
}

@MainActor
private final class ImmediateProfileService: ProfileEditingWorkspace {
  var bots = ProfileEditorTests.bots
  var profileEditorDirty = false
  var profileEditorSaveTask: Task<Void, Never>?
  var snapshot: ProfileEditSnapshot
  var saveError: Error?
  var savedTargets: [ProfileEditTarget] = []
  var savedExpected: [ProfileEditSnapshot] = []
  var savedReplacements: [ProfileEditSnapshot] = []

  init(snapshot: ProfileEditSnapshot) { self.snapshot = snapshot }
  func loadProfile(for target: ProfileEditTarget) async throws -> ProfileEditSnapshot { snapshot }
  func startProfileSave(
    for target: ProfileEditTarget, expected: ProfileEditSnapshot,
    replacement: ProfileEditSnapshot
  ) throws -> Task<Void, Error> {
    Task {
      savedTargets.append(target)
      savedExpected.append(expected)
      savedReplacements.append(replacement)
      if let saveError { throw saveError }
      snapshot = replacement
    }
  }
}

@MainActor
private final class SuspendedSaveService: ProfileEditingWorkspace {
  var bots = ProfileEditorTests.bots
  var profileEditorDirty = false
  var profileEditorSaveTask: Task<Void, Never>?
  let snapshot: ProfileEditSnapshot
  private var continuation: CheckedContinuation<Void, Never>?
  private var saveStarted = false
  init(snapshot: ProfileEditSnapshot) { self.snapshot = snapshot }
  func loadProfile(for target: ProfileEditTarget) async throws -> ProfileEditSnapshot { snapshot }
  func startProfileSave(
    for target: ProfileEditTarget, expected: ProfileEditSnapshot,
    replacement: ProfileEditSnapshot
  ) throws -> Task<Void, Error> {
    Task {
      saveStarted = true
      await withCheckedContinuation { continuation = $0 }
    }
  }
  func waitForSave() async {
    while !saveStarted { await Task.yield() }
  }
  func finishSave() {
    continuation?.resume()
    continuation = nil
  }
}

@MainActor
private final class SuspendedLoadService: ProfileEditingWorkspace {
  var bots = ProfileEditorTests.bots
  var profileEditorDirty = false
  var profileEditorSaveTask: Task<Void, Never>?
  private var continuations: [CheckedContinuation<ProfileEditSnapshot, Error>] = []
  func loadProfile(for target: ProfileEditTarget) async throws -> ProfileEditSnapshot {
    try await withCheckedThrowingContinuation { continuations.append($0) }
  }
  func startProfileSave(
    for target: ProfileEditTarget, expected: ProfileEditSnapshot,
    replacement: ProfileEditSnapshot
  ) throws -> Task<Void, Error> { Task {} }
  func waitForLoadCount(_ count: Int) async {
    while continuations.count < count { await Task.yield() }
  }
  func finishLoad(_ index: Int, with snapshot: ProfileEditSnapshot) {
    continuations[index].resume(returning: snapshot)
  }
}
