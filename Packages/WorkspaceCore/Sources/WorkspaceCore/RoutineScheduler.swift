import Foundation

/// Foreground scheduling service. The host calls reconcile on launch/wake and while awake;
/// there is no hidden timer, login item, background helper, or execution-while-asleep promise.
/// Time is injectable, and each effect is preceded by an atomic persisted occurrence claim.
public actor RoutineScheduler {
  private let repository: any WorkspaceRepository
  private let coordinator: GenerationCoordinator
  private let now: @Sendable () -> Date
  private var isReconciling = false
  private var stopped = false
  private var dispatches: [UUID: Task<Void, Error>] = [:]
  private var operations = 0
  private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []

  public init(
    repository: any WorkspaceRepository, coordinator: GenerationCoordinator,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.repository = repository
    self.coordinator = coordinator
    self.now = now
  }

  /// At most one due occurrence per routine, including after long sleep or relaunch. Older
  /// occurrences become one explicit skipped-range record rather than thousands of catch-up jobs.
  public func reconcile() async throws {
    guard !stopped else { throw WorkspaceError.storeClosed }
    guard !isReconciling else { return }
    operations += 1
    defer { finishOperation() }
    isReconciling = true
    defer { isReconciling = false }
    let instant = now()
    let snapshot = try await repository.snapshot()
    var firstFailure: Error?
    for routine in snapshot.routines where routine.enabled {
      try Task.checkCancellation()
      guard !stopped else { throw WorkspaceError.storeClosed }
      do {
        guard let first = routine.nextRunAt else {
          // Legacy records may have enabled=true without a schedule. Establish the first future
          // occurrence only; don't invent a missed run or borrow the chat's provider selection.
          var initialized = routine
          initialized.nextRunAt = try RoutineSchedule.next(
            after: instant, trigger: routine.trigger, timezoneID: routine.timezoneID)
          try await repository.apply(.editRoutine(expected: routine, replacement: initialized))
          continue
        }
        guard
          let due = try RoutineSchedule.due(
            from: first, through: instant, trigger: routine.trigger, timezoneID: routine.timezoneID)
        else { continue }
        guard
          let conversation = snapshot.conversations.first(where: {
            $0.kind == .direct && $0.memberBotIDs == [routine.ownerBotID]
          })
        else { throw WorkspaceError.missingRecord }
        let occurrence = try RoutineSchedule.occurrenceID(
          scheduleID: routine.scheduleID ?? routine.id, at: due.latest,
          trigger: routine.trigger, timezoneID: routine.timezoneID)
        let run = makeRun(
          routine, conversationID: conversation.id, at: instant,
          occurrenceID: occurrence, scheduledAt: due.latest)
        let skipped: RoutineRun? =
          due.skippedCount > 0
          ? RoutineRun(
            routineID: routine.id, ownerBotID: routine.ownerBotID, conversationID: conversation.id,
            name: routine.name, prompt: routine.prompt, providerBinding: routine.providerBinding,
            createdAt: instant,
            generationID: nil, status: .skipped, endedAt: instant, error: .supersededOccurrence,
            skippedCount: due.skippedCount, firstSkippedAt: due.firstSkippedAt,
            lastSkippedAt: due.lastSkippedAt)
          : nil
        do {
          try await repository.apply(
            .claimRoutineRun(expected: routine, run: run, skipped: skipped, nextRunAt: due.next))
        } catch WorkspaceError.identityConflict {
          // Another invocation or an existing active run owns this occurrence. No transport call.
          continue
        } catch WorkspaceError.editConflict {
          // A user edited or paused it while the snapshot was being read. Reconcile fresh later.
          continue
        } catch WorkspaceError.missingRecord {
          continue
        }
        try await dispatch(run)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        // One corrupt/edited schedule or unavailable destination must not starve unrelated bots.
        // Keep the actionable error for the host, but reconcile the other definitions first.
        if firstFailure == nil { firstFailure = error }
      }
    }
    if let firstFailure { throw firstFailure }
  }

  /// Explicit action; permitted while paused and never advances the scheduled occurrence.
  @discardableResult public func runNow(routineID: UUID) async throws -> UUID {
    guard !stopped else { throw WorkspaceError.storeClosed }
    operations += 1
    defer { finishOperation() }
    let snapshot = try await repository.snapshot()
    guard !stopped else { throw WorkspaceError.storeClosed }
    guard let routine = snapshot.routines.first(where: { $0.id == routineID }),
      let conversation = snapshot.conversations.first(where: {
        $0.kind == .direct && $0.memberBotIDs == [routine.ownerBotID]
      })
    else { throw WorkspaceError.missingRecord }
    let run = makeRun(routine, conversationID: conversation.id, at: now())
    try Task.checkCancellation()
    try await repository.apply(
      .claimRoutineRun(expected: routine, run: run, skipped: nil, nextRunAt: nil))
    try await dispatch(run)
    return run.id
  }

  public func stop(runID: UUID) async throws {
    guard !stopped else { throw WorkspaceError.storeClosed }
    operations += 1
    defer { finishOperation() }
    dispatches[runID]?.cancel()
    try await coordinator.cancelRoutine(runID)
    if let task = dispatches[runID] { _ = try? await task.value }
  }

  /// Stops accepting new work and joins accepted claims, stops and credential/pre-dispatch tasks.
  /// The host subsequently
  /// shuts down the shared GenerationCoordinator to stop already-started chat and routine work.
  public func shutdown() async {
    stopped = true
    let tasks = Array(dispatches.values)
    for task in tasks { task.cancel() }
    for task in tasks { _ = try? await task.value }
    if operations > 0 {
      await withCheckedContinuation { shutdownWaiters.append($0) }
    }
  }

  private func finishOperation() {
    operations -= 1
    if operations == 0 {
      let waiters = shutdownWaiters
      shutdownWaiters.removeAll()
      for waiter in waiters { waiter.resume() }
    }
  }

  private func dispatch(_ run: RoutineRun) async throws {
    if stopped || Task.isCancelled {
      try await repository.apply(
        .finishRoutineRun(
          id: run.id, status: .cancelled, at: max(now(), run.createdAt), error: .cancelled))
      throw CancellationError()
    }
    let task = Task { try await coordinator.submitRoutine(run.id) }
    dispatches[run.id] = task
    defer { dispatches[run.id] = nil }
    try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  private func makeRun(
    _ routine: Routine, conversationID: UUID, at instant: Date,
    occurrenceID: String? = nil, scheduledAt: Date? = nil
  ) -> RoutineRun {
    RoutineRun(
      routineID: routine.id, ownerBotID: routine.ownerBotID, conversationID: conversationID,
      name: routine.name, prompt: routine.prompt, providerBinding: routine.providerBinding,
      occurrenceID: occurrenceID, scheduledAt: scheduledAt, createdAt: instant,
      generationID: UUID())
  }
}
