import AppKit
import XCTest

@testable import NativeShell
@testable import WorkspaceCore

@MainActor
final class RoutineEditorTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_789_000_000)

  func testSheetAllowsApplicationDelegateToOwnTerminationChecks() {
    _ = NSApplication.shared
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 540, height: 640),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    XCTAssertTrue(window.preventsApplicationTerminationWhenModal)
    window.contentView = RoutineSheetPolicyView()
    XCTAssertFalse(window.preventsApplicationTerminationWhenModal)
    window.close()
  }

  func testNewRoutineHasExplicitOwnerAndDoesNotInventProviderSelection() async throws {
    let service = ImmediateRoutineService()
    let target = RoutineEditTarget(
      allowedOwnerIDs: [Self.owner.id], preferredOwnerID: Self.owner.id)
    let controller = RoutineEditorController(service: service, target: target, now: { self.now })
    XCTAssertNil(controller.load())
    XCTAssertEqual(controller.ownerID, Self.owner.id)
    XCTAssertNil(controller.providerID)
    XCTAssertFalse(controller.isDirty)

    controller.setName("Draft")
    controller.setPrompt("Draft prompt")
    controller.setOwnerID(Self.unavailable.id)
    XCTAssertEqual(controller.validationMessage, "Choose an available owner for this routine.")
    controller.setOwnerID(Self.owner.id)
    controller.setName("  Morning check  ")
    controller.setPrompt("Summarize the next step")
    controller.setIntervalMinutes(525_601)
    XCTAssertEqual(controller.validationMessage, WorkspaceError.invalidRoutine.localizedDescription)
    controller.setIntervalMinutes(525_600)
    XCTAssertTrue(controller.canSave)
    try await XCTUnwrap(controller.save()).value

    let saved = try XCTUnwrap(service.saved.last)
    XCTAssertEqual(saved.name, "Morning check")
    XCTAssertEqual(saved.ownerBotID, Self.owner.id)
    XCTAssertNil(saved.providerBinding)
    XCTAssertFalse(saved.enabled)
    XCTAssertNil(saved.nextRunAt)
    XCTAssertTrue(controller.shouldDismiss)
  }

  func testEnabledRoutineRequiresProviderAndFreshAuthorizationThenSchedulesInFuture() async throws {
    let service = ImmediateRoutineService()
    let controller = RoutineEditorController(
      service: service,
      target: RoutineEditTarget(
        allowedOwnerIDs: [Self.owner.id], preferredOwnerID: Self.owner.id),
      now: { self.now })
    _ = controller.load()
    controller.setName("Daily")
    controller.setPrompt("Send context")
    controller.setTriggerKind(.daily)
    controller.setDailyHour(9)
    controller.setDailyMinute(30)
    controller.setTimezoneID("Asia/Bangkok")
    controller.setEnabled(true)
    XCTAssertEqual(
      controller.validationMessage,
      "Choose a provider before enabling automatic transmission.")
    controller.setProviderID(Self.provider.id)
    XCTAssertTrue(controller.requiresTransmissionAuthorization)
    XCTAssertEqual(controller.transmissionDisclosureTitle, "Automatic transmission disclosure")
    XCTAssertEqual(
      controller.transmissionAuthorizationLabel, "I authorize these automatic transmissions")
    XCTAssertTrue(
      controller.transmissionDisclosureText.contains(Self.provider.apiRoot.absoluteString))
    XCTAssertTrue(controller.transmissionDisclosureText.contains("Provider charges may apply"))
    XCTAssertFalse(controller.canSave)
    controller.setAuthorizedTransmission(true)
    XCTAssertTrue(controller.canSave)
    try await XCTUnwrap(controller.save()).value

    let saved = try XCTUnwrap(service.saved.last)
    XCTAssertEqual(saved.providerBinding, RoutineProviderBinding(Self.provider))
    XCTAssertEqual(saved.trigger, .daily(hour: 9, minute: 30))
    XCTAssertNotNil(saved.scheduleID)
    XCTAssertEqual(
      saved.nextRunAt,
      try RoutineSchedule.next(
        after: now, trigger: saved.trigger, timezoneID: saved.timezoneID))
    XCTAssertEqual(service.authorizations, [true])
  }

  func testEditingCannotChangeOwnerAndUnchangedScheduleIdentityIsPreserved() async throws {
    let scheduleID = UUID()
    let next = now.addingTimeInterval(300)
    let original = Routine(
      ownerBotID: Self.owner.id, name: "Existing", prompt: "Prompt",
      trigger: .interval(minutes: 5), timezoneID: "UTC", enabled: true,
      nextRunAt: next, providerBinding: RoutineProviderBinding(Self.provider),
      scheduleID: scheduleID)
    let service = ImmediateRoutineService(routine: original)
    let controller = RoutineEditorController(
      service: service,
      target: RoutineEditTarget(routineID: original.id, allowedOwnerIDs: [Self.unavailable.id]),
      now: { self.now })
    try await XCTUnwrap(controller.load()).value
    controller.setOwnerID(Self.unavailable.id)
    XCTAssertEqual(controller.ownerID, Self.owner.id)
    controller.setName("Renamed")
    XCTAssertTrue(controller.requiresTransmissionAuthorization)
    controller.setAuthorizedTransmission(true)
    try await XCTUnwrap(controller.save()).value
    let saved = try XCTUnwrap(service.saved.last)
    XCTAssertEqual(saved.ownerBotID, original.ownerBotID)
    XCTAssertEqual(saved.scheduleID, scheduleID)
    XCTAssertEqual(saved.nextRunAt, next)
  }

  func testPauseClearsNextRunAndResumeCreatesNewScheduleIdentity() async throws {
    let original = Routine(
      ownerBotID: Self.owner.id, name: "Existing", prompt: "Prompt",
      trigger: .interval(minutes: 5), timezoneID: "UTC", enabled: true,
      nextRunAt: now.addingTimeInterval(300),
      providerBinding: RoutineProviderBinding(Self.provider),
      scheduleID: UUID())
    let service = ImmediateRoutineService(routine: original)
    var controller = RoutineEditorController(
      service: service, target: RoutineEditTarget(routineID: original.id), now: { self.now })
    try await XCTUnwrap(controller.load()).value
    controller.setEnabled(false)
    try await XCTUnwrap(controller.save()).value
    let paused = try XCTUnwrap(service.saved.last)
    XCTAssertFalse(paused.enabled)
    XCTAssertNil(paused.nextRunAt)
    XCTAssertEqual(paused.scheduleID, original.scheduleID)

    service.routine = paused
    controller = RoutineEditorController(
      service: service, target: RoutineEditTarget(routineID: original.id), now: { self.now })
    try await XCTUnwrap(controller.load()).value
    controller.setEnabled(true)
    XCTAssertTrue(controller.requiresTransmissionAuthorization)
    controller.setAuthorizedTransmission(true)
    try await XCTUnwrap(controller.save()).value
    let resumed = try XCTUnwrap(service.saved.last)
    XCTAssertNotEqual(resumed.scheduleID, paused.scheduleID)
    XCTAssertEqual(resumed.nextRunAt, now.addingTimeInterval(300))
  }

  func testPausedBoundPromptChangeRequiresAuthorizationButNameOnlyChangeDoesNot() async throws {
    let original = Routine(
      ownerBotID: Self.owner.id, name: "Existing", prompt: "Prompt",
      trigger: .interval(minutes: 5), timezoneID: "UTC",
      providerBinding: RoutineProviderBinding(Self.provider))
    let service = ImmediateRoutineService(routine: original)
    let controller = RoutineEditorController(
      service: service, target: RoutineEditTarget(routineID: original.id), now: { self.now })
    try await XCTUnwrap(controller.load()).value
    controller.setName("Metadata only")
    XCTAssertFalse(controller.requiresTransmissionAuthorization)
    XCTAssertTrue(controller.canSave)
    controller.setPrompt("Different transmitted content")
    XCTAssertTrue(controller.requiresTransmissionAuthorization)
    XCTAssertEqual(controller.transmissionDisclosureTitle, "Paused destination approval")
    XCTAssertEqual(
      controller.transmissionAuthorizationLabel, "I approve this prompt and destination binding")
    XCTAssertTrue(
      controller.transmissionDisclosureText.contains("Saving this paused routine sends nothing"))
    XCTAssertTrue(controller.transmissionDisclosureText.contains("separate confirmation"))
    XCTAssertFalse(controller.canSave)
    controller.setAuthorizedTransmission(true)
    XCTAssertTrue(controller.canSave)
  }

  func testFailedCASPreservesDraftAndExplicitReloadDiscardsIt() async throws {
    let original = Routine(
      ownerBotID: Self.owner.id, name: "Original", prompt: "Prompt",
      trigger: .interval(minutes: 5), timezoneID: "UTC")
    let latest = Routine(
      id: original.id, ownerBotID: Self.owner.id, name: "Server", prompt: "Prompt",
      trigger: .interval(minutes: 5), timezoneID: "UTC")
    let service = ImmediateRoutineService(routine: original)
    service.saveError = WorkspaceError.editConflict
    let controller = RoutineEditorController(
      service: service, target: RoutineEditTarget(routineID: original.id), now: { self.now })
    try await XCTUnwrap(controller.load()).value
    controller.setName("My draft")
    try await XCTUnwrap(controller.save()).value
    XCTAssertEqual(controller.name, "My draft")
    XCTAssertTrue(controller.isDirty)
    XCTAssertFalse(controller.shouldDismiss)
    XCTAssertEqual(controller.errorMessage, WorkspaceError.editConflict.localizedDescription)

    service.routine = latest
    XCTAssertNil(controller.requestReload())
    XCTAssertTrue(controller.isConfirmingReload)
    try await XCTUnwrap(controller.confirmReload()).value
    XCTAssertEqual(controller.name, "Server")
    XCTAssertFalse(controller.isDirty)
    XCTAssertFalse(service.routineEditorDirty)
  }

  func testProviderDestinationChangeAfterConsentRequiresFreshAuthorization() async throws {
    let original = Routine(
      ownerBotID: Self.owner.id, name: "Original", prompt: "Prompt",
      trigger: .interval(minutes: 5), timezoneID: "UTC", enabled: true,
      nextRunAt: now.addingTimeInterval(300),
      providerBinding: RoutineProviderBinding(Self.provider))
    let service = ImmediateRoutineService(routine: original)
    let controller = RoutineEditorController(
      service: service, target: RoutineEditTarget(routineID: original.id), now: { self.now })
    try await XCTUnwrap(controller.load()).value
    XCTAssertFalse(controller.isDirty)
    controller.setAuthorizedTransmission(true)
    XCTAssertFalse(controller.canSave)
    service.providers[0].modelID = "changed-destination-model"
    controller.providersChanged()
    XCTAssertTrue(controller.isDirty)
    XCTAssertTrue(service.routineEditorDirty)
    XCTAssertFalse(controller.authorizedTransmission)
    XCTAssertFalse(controller.canSave)
    controller.setAuthorizedTransmission(true)
    XCTAssertTrue(controller.canSave)
  }

  func testBindingDriftBeforeLoadCanBeReauthorizedAndSavedWithoutUnrelatedEdits() async throws {
    let original = Routine(
      ownerBotID: Self.owner.id, name: "Original", prompt: "Prompt",
      trigger: .interval(minutes: 5), timezoneID: "UTC",
      providerBinding: RoutineProviderBinding(Self.provider))
    let service = ImmediateRoutineService(routine: original)
    service.providers[0].apiRoot = URL(string: "https://replacement.invalid/other-path")!
    let controller = RoutineEditorController(
      service: service, target: RoutineEditTarget(routineID: original.id), now: { self.now })
    try await XCTUnwrap(controller.load()).value

    XCTAssertTrue(controller.isDirty)
    XCTAssertTrue(service.routineEditorDirty)
    XCTAssertTrue(controller.requiresTransmissionAuthorization)
    XCTAssertFalse(controller.canSave)
    controller.setAuthorizedTransmission(true)
    XCTAssertTrue(controller.canSave)
    try await XCTUnwrap(controller.save()).value

    XCTAssertEqual(service.expected.last!, original)
    XCTAssertEqual(
      service.saved.last?.providerBinding, RoutineProviderBinding(service.providers[0]))
    XCTAssertTrue(controller.shouldDismiss)
  }

  func testEditingDuringAcceptedSaveKeepsNewerDraftDirty() async throws {
    let original = Routine(
      ownerBotID: Self.owner.id, name: "Original", prompt: "Prompt",
      trigger: .interval(minutes: 5), timezoneID: "UTC")
    let service = SuspendedRoutineSaveService(routine: original)
    let controller = RoutineEditorController(
      service: service, target: RoutineEditTarget(routineID: original.id), now: { self.now })
    try await XCTUnwrap(controller.load()).value
    controller.setName("Submitted")
    let save = try XCTUnwrap(controller.save())
    await service.waitForSave()
    controller.setPrompt("Newer draft")
    service.finishSave()
    await save.value

    XCTAssertFalse(controller.shouldDismiss)
    XCTAssertTrue(controller.isDirty)
    XCTAssertEqual(controller.name, "Submitted")
    XCTAssertEqual(controller.prompt, "Newer draft")
    XCTAssertEqual(controller.baseline?.name, "Submitted")
    XCTAssertEqual(controller.baseline?.prompt, "Prompt")
    XCTAssertEqual(controller.errorMessage, "Saved. Newer edits remain in this form.")
  }

  func testCancelDuringLoadRejectsLateRoutineAndClearsQuitDirtyState() async throws {
    let service = SuspendedRoutineLoadService()
    let id = UUID()
    let controller = RoutineEditorController(
      service: service, target: RoutineEditTarget(routineID: id), now: { self.now })
    let load = try XCTUnwrap(controller.load())
    await service.waitForLoad()
    controller.requestCancel()
    service.finishLoad(
      Routine(
        id: id, ownerBotID: Self.owner.id, name: "Late", prompt: "Late prompt",
        trigger: .interval(minutes: 5), timezoneID: "UTC"))
    await load.value

    XCTAssertTrue(controller.shouldDismiss)
    XCTAssertNil(controller.baseline)
    XCTAssertFalse(controller.hasLoaded)
    XCTAssertFalse(service.routineEditorDirty)
  }

  fileprivate static let owner = PreviewBot(name: "Owner")
  fileprivate static let unavailable = PreviewBot(name: "Unavailable")
  fileprivate static let provider = ProviderConfig(
    name: "Fixture", apiRoot: URL(string: "https://fixture.invalid/v1")!,
    modelID: "fixture-model", credentialReference: "fixture")
}

@MainActor
private final class ImmediateRoutineService: RoutineEditingWorkspace {
  var bots = [RoutineEditorTests.owner, RoutineEditorTests.unavailable]
  var providers = [RoutineEditorTests.provider]
  var routineEditorDirty = false
  var routineEditorSaveTask: Task<Void, Never>?
  var routine: Routine?
  var saveError: Error?
  var saved: [Routine] = []
  var expected: [Routine?] = []
  var authorizations: [Bool] = []

  init(routine: Routine? = nil) { self.routine = routine }

  func loadRoutineForEditing(id: UUID) async throws -> Routine {
    guard let routine, routine.id == id else { throw WorkspaceError.missingRecord }
    return routine
  }

  func startRoutineSave(
    expected: Routine?, replacement: Routine, authorizedTransmission: Bool
  ) throws -> Task<Void, Error> {
    Task {
      self.expected.append(expected)
      saved.append(replacement)
      authorizations.append(authorizedTransmission)
      if let saveError { throw saveError }
      routine = replacement
    }
  }
}

@MainActor
private final class SuspendedRoutineSaveService: RoutineEditingWorkspace {
  var bots = [RoutineEditorTests.owner]
  var providers = [RoutineEditorTests.provider]
  var routineEditorDirty = false
  var routineEditorSaveTask: Task<Void, Never>?
  let routine: Routine
  private var saveStarted = false
  private var continuation: CheckedContinuation<Void, Never>?

  init(routine: Routine) { self.routine = routine }

  func loadRoutineForEditing(id: UUID) async throws -> Routine { routine }

  func startRoutineSave(
    expected: Routine?, replacement: Routine, authorizedTransmission: Bool
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
private final class SuspendedRoutineLoadService: RoutineEditingWorkspace {
  var bots = [RoutineEditorTests.owner]
  var providers = [RoutineEditorTests.provider]
  var routineEditorDirty = false
  var routineEditorSaveTask: Task<Void, Never>?
  private var continuation: CheckedContinuation<Routine, Error>?

  func loadRoutineForEditing(id: UUID) async throws -> Routine {
    try await withCheckedThrowingContinuation { continuation = $0 }
  }

  func startRoutineSave(
    expected: Routine?, replacement: Routine, authorizedTransmission: Bool
  ) throws -> Task<Void, Error> { Task {} }

  func waitForLoad() async {
    while continuation == nil { await Task.yield() }
  }

  func finishLoad(_ routine: Routine) {
    continuation?.resume(returning: routine)
    continuation = nil
  }
}
