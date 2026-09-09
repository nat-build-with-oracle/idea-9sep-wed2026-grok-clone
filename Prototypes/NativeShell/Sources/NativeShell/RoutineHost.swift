import Foundation
import WorkspaceCore

/// App-owned awake scheduling, not a background service. One reconciliation at a time;
/// shutdown joins even a cancelled reconciliation before the workspace can be replaced.
@MainActor final class RoutineHost {
  let scheduler: RoutineScheduler
  private let reconcile: @MainActor () async -> Void
  private let polling: Bool
  private var ticker: Task<Void, Never>?
  private var reconciliation: Task<Void, Never>?
  private var awake = false
  private var stopped = false
  private var reconcileAgain = false

  init(
    scheduler: RoutineScheduler, polling: Bool = true,
    reconcile: @escaping @MainActor () async -> Void
  ) {
    self.scheduler = scheduler
    self.polling = polling
    self.reconcile = reconcile
  }

  func wake() {
    guard !stopped else { return }
    awake = true
    requestReconciliation()
    guard polling, ticker == nil else { return }
    ticker = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(30)) } catch { return }
        guard let self, !stopped, awake else { return }
        requestReconciliation()
      }
    }
  }

  func suspend() {
    awake = false
    reconcileAgain = false
    ticker?.cancel()
    ticker = nil
    reconciliation?.cancel()
  }

  func requestReconciliation() {
    guard awake, !stopped else { return }
    guard reconciliation == nil else {
      reconcileAgain = true
      return
    }
    reconciliation = Task { [weak self] in
      guard let self else { return }
      await reconcile()
      reconciliation = nil
      if reconcileAgain {
        reconcileAgain = false
        requestReconciliation()
      }
    }
  }

  func waitForReconciliation() async { await reconciliation?.value }

  func shutdown() async {
    stopped = true
    suspend()
    // Scheduler shutdown rejects new effects and joins a suspended claim/credential lookup.
    await scheduler.shutdown()
    await reconciliation?.value
  }
}
