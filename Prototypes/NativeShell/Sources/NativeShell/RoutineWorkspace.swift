import Foundation
import WorkspaceCore

struct RoutineDetailTarget: Equatable, Identifiable { let id: UUID }

enum RoutineControlError: Error, LocalizedError {
  case consentRequired, providerChanged, unavailableOwner, busy
  var errorDescription: String? {
    switch self {
    case .consentRequired:
      "Review and authorize the routine's prompt, chat context and destination first."
    case .providerChanged:
      "The bound provider is missing or changed. Edit the routine and explicitly choose its destination again."
    case .unavailableOwner:
      "Choose an available owner from this conversation. Output belongs to that bot's direct chat."
    case .busy: "Another routine action is in progress, or this workspace is closing."
    }
  }
}

extension PreviewWorkspace {
  var visibleRoutineDefinitions: [Routine] {
    let owners = Set(current?.memberIDs ?? [])
    return routineDefinitions.filter { owners.contains($0.ownerBotID) }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  var currentRoutine: Routine? {
    routineDefinitions.first { $0.id == routineDetailTarget?.id }
  }

  var canOpenRoutine: Bool {
    isPersistent && !isLoading && !isClosing && !isDeletingBot && !isProfileSaving
      && !isRoutineSaving && editTarget == nil && botDeletionTarget == nil
      && routineEditTarget == nil && panel == nil
  }

  func beginRoutineEditing(_ routine: Routine? = nil) {
    guard canOpenRoutine, let current else { return }
    let owners = current.memberIDs.filter { id in bots.contains { $0.id == id } }
    guard !owners.isEmpty else { return }
    routineEditorDirty = false
    routineError = nil
    routineEditTarget = RoutineEditTarget(
      routineID: routine?.id, allowedOwnerIDs: routine.map { [$0.ownerBotID] } ?? owners,
      preferredOwnerID: routine?.ownerBotID ?? (current.kind == .direct ? owners.first : nil))
  }

  func openRoutine(_ id: UUID) {
    guard canOpenRoutine, routineDefinitions.contains(where: { $0.id == id }) else { return }
    routineDetailTarget = RoutineDetailTarget(id: id)
    routineHistory = []
    routineDeletionPlan = nil
    routineError = nil
    reloadRoutineHistory()
  }

  func closeRoutine() {
    guard routineEditTarget == nil else { return }
    routineHistoryRequest += 1
    routineHistoryTask?.cancel()
    routineDetailTarget = nil
    routineHistory = []
    routineDeletionPlan = nil
    routineHistoryLoading = false
    composerFocusRequest += 1
  }

  func loadRoutineForEditing(id: UUID) async throws -> Routine {
    guard let repository else { throw WorkspaceError.storeUnavailable }
    let context = replyContextGeneration
    let snapshot = try await repository.snapshot()
    guard context == replyContextGeneration else { throw WorkspaceError.staleRevision }
    guard let routine = snapshot.routines.first(where: { $0.id == id }) else {
      throw WorkspaceError.missingRecord
    }
    return routine
  }

  /// Claim before returning to AppKit. An accepted save belongs to its captured workspace,
  /// not to the conversation selected when its suspended repository write completes.
  func startRoutineSave(
    expected: Routine?, replacement: Routine, authorizedTransmission: Bool
  ) throws -> Task<Void, Error> {
    guard !isRoutineSaving, let target = routineEditTarget,
      target.routineID == expected?.id,
      target.allowedOwnerIDs.contains(replacement.ownerBotID)
    else { throw RoutineControlError.unavailableOwner }
    if let expected {
      guard replacement.id == expected.id, replacement.ownerBotID == expected.ownerBotID else {
        throw WorkspaceError.editConflict
      }
    }
    guard !replacement.enabled || authorizedTransmission else {
      throw RoutineControlError.consentRequired
    }
    if replacement.enabled, replacement.providerBinding == nil {
      throw RoutineControlError.providerChanged
    }
    // Validate trigger/timezone regardless of pause state; no implicit calendar/zone selection.
    _ = try RoutineSchedule.next(
      after: routineNow(), trigger: replacement.trigger, timezoneID: replacement.timezoneID)
    let task = try startRoutineOperation(key: "save") { repository, _ in
      if let expected {
        try await repository.apply(.editRoutine(expected: expected, replacement: replacement))
      } else {
        try await repository.apply(.createRoutine(replacement))
      }
    }
    isRoutineSaving = true
    return task
  }

  func startRoutineRunNow(_ expected: Routine, authorizedTransmission: Bool) throws -> Task<
    Void, Error
  > {
    guard authorizedTransmission else { throw RoutineControlError.consentRequired }
    return try startRoutineOperation(key: "run-\(expected.id)") { repository, scheduler in
      // Scheduler checks the binding again after credential I/O. Never use composer selection.
      _ = try await scheduler.runNow(routineID: expected.id, expected: expected)
    }
  }

  func startRoutinePause(_ expected: Routine) throws -> Task<Void, Error> {
    var paused = expected
    paused.enabled = false
    paused.nextRunAt = nil
    return try startRoutineOperation(key: "pause-\(expected.id)") { repository, _ in
      try await repository.apply(.editRoutine(expected: expected, replacement: paused))
    }
  }

  func startRoutineStop(_ runID: UUID) throws -> Task<Void, Error> {
    try startRoutineOperation(key: "stop-\(runID)") { _, scheduler in
      try await scheduler.stop(runID: runID)
    }
  }

  func loadRoutineDeletionPlan() async {
    guard let id = routineDetailTarget?.id, let repository else { return }
    let context = replyContextGeneration
    do {
      let plan = try await repository.routineDeletionPlan(routineID: id)
      guard context == replyContextGeneration, routineDetailTarget?.id == id else { return }
      routineDeletionPlan = plan
    } catch {
      guard context == replyContextGeneration, routineDetailTarget?.id == id else { return }
      routineError = Self.routineErrorMessage(error)
    }
  }

  func startRoutineDeletion(_ plan: RoutineDeletionPlan, stopActive: Bool) throws -> Task<
    Void, Error
  > {
    guard plan.activeRunIDs.isEmpty || stopActive else { throw BotDeletionError.activeWork }
    return try startRoutineOperation(key: "delete-\(plan.routine.id)") { repository, scheduler in
      // The history count is checked atomically before preventing new scheduled claims.
      // If stop/delete later fails, this explicitly accepted deletion leaves the routine paused.
      try await repository.apply(
        .pauseRoutineForDeletion(expected: plan.routine, expectedRunIDs: plan.runIDs))
      var paused = plan.routine
      paused.enabled = false
      paused.nextRunAt = nil
      for runID in plan.activeRunIDs { try await scheduler.stop(runID: runID) }
      try await repository.apply(.deleteRoutine(expected: paused, expectedRunIDs: plan.runIDs))
    }
  }

  private func startRoutineOperation(
    key: String,
    operation: @escaping @MainActor (any WorkspaceRepository, RoutineScheduler) async throws -> Void
  ) throws -> Task<Void, Error> {
    guard isPersistent, !isClosing, !isLoading, !isDeletingBot, !routineShutdownStarted,
      !pendingRoutineActions.contains(key), let repository, let host = routineHost
    else { throw RoutineControlError.busy }
    let context = replyContextGeneration
    pendingRoutineActions.insert(key)
    routineError = nil
    let task = Task {
      defer {
        pendingRoutineActions.remove(key)
        routineTasks[key] = nil
        if key == "save" { isRoutineSaving = false }
      }
      do {
        try await operation(repository, host.scheduler)
        guard context == replyContextGeneration else { throw WorkspaceError.staleRevision }
        try await refreshRoutinePresentation()
        if let id = routineDetailTarget?.id,
          !routineDefinitions.contains(where: { $0.id == id })
        {
          closeRoutine()
        }
      } catch {
        if context == replyContextGeneration {
          routineError = Self.routineErrorMessage(error)
          try? await refreshRoutinePresentation()
        }
        throw error
      }
    }
    routineTasks[key] = task
    return task
  }

  func performRoutineAction(_ action: () throws -> Task<Void, Error>) {
    do {
      let task = try action()
      Task { _ = try? await task.value }
    } catch { routineError = Self.routineErrorMessage(error) }
  }

  func startRoutineHost() {
    guard let repository, let coordinator else { return }
    let context = replyContextGeneration
    let scheduler = RoutineScheduler(
      repository: repository, coordinator: coordinator, now: routineNow)
    routineShutdownStarted = false
    routineHost = RoutineHost(scheduler: scheduler, polling: routinePollingEnabled) { [weak self] in
      do {
        try await scheduler.reconcile()
        guard let self, context == replyContextGeneration else { return }
        try await refreshRoutinePresentation()
      } catch is CancellationError {
      } catch {
        guard let self, context == replyContextGeneration, !routineShutdownStarted else { return }
        routineError = Self.routineErrorMessage(error)
      }
    }
    routineHost?.wake()
  }

  func shutdownRoutines() async {
    routineShutdownStarted = true
    routineHistoryRequest += 1
    routineHistoryTask?.cancel()
    await routineHost?.shutdown()
    for task in Array(routineTasks.values) { _ = try? await task.value }
    await routineEditorSaveTask?.value
    routineHost = nil
  }

  func refreshRoutinePresentation() async throws {
    guard let repository else { return }
    let context = replyContextGeneration
    let snapshot = try await repository.snapshot()
    guard context == replyContextGeneration else { return }
    routineDefinitions = snapshot.routines
    if let id = routineDetailTarget?.id {
      if snapshot.routines.contains(where: { $0.id == id }) {
        try await refreshRoutineHistory(id)
      } else {
        closeRoutine()
      }
    }
  }

  @discardableResult func reloadRoutineHistory() -> Task<Void, Never>? {
    guard let id = routineDetailTarget?.id else { return nil }
    routineHistoryTask?.cancel()
    routineHistoryTask = Task {
      do { try await refreshRoutineHistory(id) } catch {
        guard routineDetailTarget?.id == id, !Task.isCancelled else { return }
        routineError = Self.routineErrorMessage(error)
      }
    }
    return routineHistoryTask
  }

  private func refreshRoutineHistory(_ id: UUID) async throws {
    guard let repository else { return }
    let context = replyContextGeneration
    routineHistoryRequest += 1
    let request = routineHistoryRequest
    routineHistoryLoading = true
    defer { if request == routineHistoryRequest { routineHistoryLoading = false } }
    var runs = try await repository.routineRuns(routineID: id, limit: 100)
    // A wall-clock rollback can place a new active run behind 100 future-dated records.
    // Always expose it so Stop remains reachable, without loading the full history into the UI.
    let plan = try await repository.routineDeletionPlan(routineID: id)
    for activeID in plan.activeRunIDs where !runs.contains(where: { $0.id == activeID }) {
      runs.insert(try await repository.routineRun(id: activeID), at: 0)
    }
    guard context == replyContextGeneration, request == routineHistoryRequest,
      routineDetailTarget?.id == id, !Task.isCancelled
    else { return }
    routineHistory = runs
  }

  static func routineErrorMessage(_ error: Error) -> String {
    if let error = error as? RoutineControlError { return error.localizedDescription }
    if let error = error as? BotDeletionError { return error.localizedDescription }
    return providerErrorMessage(error)
  }
}
