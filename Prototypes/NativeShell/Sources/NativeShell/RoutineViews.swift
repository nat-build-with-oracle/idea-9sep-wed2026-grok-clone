import SwiftUI
import WorkspaceCore

struct RoutineInspectorSection: View {
  @ObservedObject var store: PreviewWorkspace
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Routines").foregroundStyle(ShellTheme.secondary)
        Spacer()
        ShellIconButton(symbol: "plus", label: "Add routine") {
          if store.isPersistent { store.beginRoutineEditing() } else { store.panel = .routine }
        }
        .accessibilityIdentifier("add-routine")
        .disabled(store.current == nil || (store.isPersistent && !store.canOpenRoutine))
      }
      if store.isPersistent {
        ForEach(store.visibleRoutineDefinitions) { routine in
          Button {
            store.openRoutine(routine.id)
          } label: {
            VStack(alignment: .leading, spacing: 5) {
              Label(routine.name, systemImage: "clock")
              Text(routineScheduleLabel(routine)).font(.system(size: 12))
              if store.current?.kind == .group {
                Text(
                  "Owner: \(store.bots.first { $0.id == routine.ownerBotID }?.name ?? "Unavailable") · direct chat"
                )
                .font(.system(size: 11))
              }
              Text(routine.enabled ? "Enabled · while app is awake" : "Paused")
                .font(.system(size: 11)).foregroundStyle(ShellTheme.secondary)
              if let next = routine.nextRunAt, routine.enabled {
                Text("Next: \(next.formatted(date: .abbreviated, time: .shortened))")
                  .font(.system(size: 11)).foregroundStyle(ShellTheme.secondary)
              }
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
          }.buttonStyle(.plain).padding(.vertical, 5)
            .accessibilityIdentifier("routine-\(routine.id)")
        }
        if store.visibleRoutineDefinitions.isEmpty {
          Text("No routines yet").font(.system(size: 12))
        }
        Text("No runs while the app is closed, the Mac is asleep, or you are logged out.")
          .font(.system(size: 11)).foregroundStyle(ShellTheme.secondary)
        if let error = store.routineError {
          Text(error).font(.system(size: 11)).foregroundStyle(ShellTheme.warning)
        }
      } else {
        ForEach(store.routines.filter { $0.botID == store.currentBot?.id }) { routine in
          Text("\(routine.name) · paused sample").font(.system(size: 12))
        }
        Text("Sample only. Scheduling is unavailable.").font(.system(size: 11))
      }
    }.fixedSize(horizontal: false, vertical: true)
  }
}

func routineScheduleLabel(_ routine: Routine) -> String {
  switch routine.trigger {
  case .interval(let minutes): "Every \(minutes) minutes · \(routine.timezoneID)"
  case .daily(let hour, let minute):
    String(format: "Daily %02d:%02d · %@", hour, minute, routine.timezoneID)
  }
}

struct RoutineDetailView: View {
  @ObservedObject var store: PreviewWorkspace
  let target: RoutineDetailTarget
  @State private var runConfirmation: Routine?
  @State private var showingRunConfirmation = false
  @State private var showingDeletion = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text(store.currentRoutine?.name ?? "Routine").font(.title2.bold())
        Spacer()
        Button("Done") { store.closeRoutine() }.keyboardShortcut(.cancelAction)
      }.padding(20)
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          if let routine = store.currentRoutine {
            let owner =
              store.bots.first { $0.id == routine.ownerBotID }?.name ?? "Unavailable owner"
            Text("Owner: \(owner). All output goes to this bot's direct chat, not the group.")
            Text(routineScheduleLabel(routine)).foregroundStyle(ShellTheme.secondary)
            Text(routine.prompt).textSelection(.enabled).accessibilityLabel("Routine prompt")
            Text(transmissionDescription(routine, owner: owner)).font(.callout)
              .foregroundStyle(ShellTheme.secondary)
            if let next = routine.nextRunAt, routine.enabled {
              Text("Next planned: \(next.formatted(date: .complete, time: .shortened))")
            } else {
              Text("Paused — no scheduled runs.")
            }
            Text(
              "Only while this app is open and the Mac is awake. Pause prevents new scheduled runs; an active run may finish unless you choose Stop."
            )
            .font(.callout).foregroundStyle(ShellTheme.secondary)
            HStack {
              Button("Edit") { store.beginRoutineEditing(routine) }
                .accessibilityIdentifier("routine-edit")
              Button("Run Now") {
                runConfirmation = routine
                showingRunConfirmation = true
              }
              .accessibilityIdentifier("routine-run-now")
              .disabled(
                !store.pendingRoutineActions.isEmpty
                  || store.routineHistory.contains { !$0.status.isTerminal })
              if routine.enabled {
                Button("Pause") {
                  store.performRoutineAction { try store.startRoutinePause(routine) }
                }
                .accessibilityIdentifier("routine-pause")
              } else {
                Button("Resume…") { store.beginRoutineEditing(routine) }
                  .help("Review the destination and enable scheduling in the editor.")
                  .accessibilityIdentifier("routine-resume")
              }
              Spacer()
              Button("Delete…", role: .destructive) {
                Task {
                  await store.loadRoutineDeletionPlan()
                  showingDeletion = store.routineDeletionPlan != nil
                }
              }.disabled(!store.pendingRoutineActions.isEmpty)
                .accessibilityIdentifier("routine-delete")
            }.buttonStyle(.bordered)
          }
          if let error = store.routineError {
            Text(error).foregroundStyle(ShellTheme.warning).textSelection(.enabled)
          }
          Divider()
          HStack {
            Text("Run history").font(.headline)
            Spacer()
            if store.routineHistoryLoading { ProgressView().controlSize(.small) }
            Button("Refresh") { store.reloadRoutineHistory() }
          }
          Text("Latest 100 records plus any active run. Export includes the full history.").font(
            .caption)
          if store.routineHistory.isEmpty {
            Text("No runs yet.").foregroundStyle(ShellTheme.secondary)
          }
          ForEach(store.routineHistory) { run in
            VStack(alignment: .leading, spacing: 6) {
              HStack {
                Text(run.status.rawValue.capitalized).fontWeight(.semibold)
                Text(
                  run.status == .skipped
                    ? "Scheduled summary" : run.occurrenceID == nil ? "Manual" : "Scheduled"
                ).font(.caption)
                Spacer()
                if !run.status.isTerminal {
                  Button("Stop") {
                    store.performRoutineAction { try store.startRoutineStop(run.id) }
                  }
                  .accessibilityLabel("Stop \(run.name) run")
                  .disabled(store.pendingRoutineActions.contains("stop-\(run.id)"))
                }
              }
              Text(run.createdAt.formatted(date: .abbreviated, time: .standard)).font(.caption)
              if let failure = run.error {
                Text(routineFailureLabel(failure)).font(.callout).foregroundStyle(
                  ShellTheme.warning)
              }
              if run.skippedCount > 0, let first = run.firstSkippedAt, let last = run.lastSkippedAt
              {
                Text(
                  "\(run.skippedCount) older occurrences skipped: \(first.formatted()) – \(last.formatted())"
                )
                .font(.caption)
              }
              if let binding = run.providerBinding {
                Text("\(binding.apiRoot.host() ?? "Unknown host") · \(binding.modelID)").font(
                  .caption)
              }
              if store.conversations.contains(where: { $0.id == run.conversationID }) {
                Button("Open owner's chat") {
                  store.closeRoutine()
                  store.select(run.conversationID)
                }
                .font(.caption)
              }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
              .background(ShellTheme.bubble, in: RoundedRectangle(cornerRadius: 8))
          }
        }.padding(20)
      }
    }
    .frame(width: 600, height: 550).background(ShellTheme.sidebar)
    .background(ProfileSheetPolicyViewBridge())
    .sheet(item: $store.routineEditTarget) { RoutineEditorView(store: store, target: $0) }
    .alert("Run this routine now?", isPresented: $showingRunConfirmation) {
      Button("Cancel", role: .cancel) { runConfirmation = nil }
      Button("Run Now") {
        if let expected = runConfirmation {
          store.performRoutineAction {
            try store.startRoutineRunNow(expected, authorizedTransmission: true)
          }
        }
        runConfirmation = nil
      }
    } message: {
      if let routine = runConfirmation {
        Text(
          transmissionDescription(
            routine, owner: store.bots.first { $0.id == routine.ownerBotID }?.name ?? "the owner")
            + " This is one new run, even while paused. Its calendar schedule is unchanged.")
      }
    }
    .alert("Delete routine and its history?", isPresented: $showingDeletion) {
      Button("Cancel", role: .cancel) { store.routineDeletionPlan = nil }
      if let plan = store.routineDeletionPlan {
        Button(plan.activeRunIDs.isEmpty ? "Delete" : "Stop and Delete", role: .destructive) {
          store.performRoutineAction { try store.startRoutineDeletion(plan, stopActive: true) }
          store.routineDeletionPlan = nil
        }
      }
    } message: {
      if let plan = store.routineDeletionPlan {
        Text(
          "Delete “\(plan.routine.name)” and all \(plan.runIDs.count) history records. \(plan.activeRunIDs.count) active runs will be stopped. Chat messages and drafts are kept. Future scheduling is paused first; if deletion fails, the routine remains paused for review."
        )
      }
    }
    .task(id: target.id) {
      let context = store.replyContextGeneration
      while !Task.isCancelled, store.routineDetailTarget == target {
        do {
          try await store.refreshRoutinePresentation()
          try await Task.sleep(for: .seconds(1))
        } catch is CancellationError { return } catch {
          guard !Task.isCancelled, store.routineDetailTarget == target,
            context == store.replyContextGeneration
          else { return }
          store.routineError = PreviewWorkspace.routineErrorMessage(error)
          return
        }
      }
    }
  }
}

private struct ProfileSheetPolicyViewBridge: NSViewRepresentable {
  func makeNSView(context: Context) -> ProfileSheetPolicyView { ProfileSheetPolicyView() }
  func updateNSView(_ nsView: ProfileSheetPolicyView, context: Context) {}
}

func transmissionDescription(_ routine: Routine, owner: String) -> String {
  guard let binding = routine.providerBinding else {
    return
      "No provider is bound. A run will be recorded as blocked until you edit and choose a destination."
  }
  return
    "Sends this prompt and up to 100 recent messages from \(owner)'s direct chat to \(binding.apiRoot.absoluteString), model \(binding.modelID). Provider usage may incur charges."
}

func routineFailureLabel(_ failure: RoutineRun.Failure) -> String {
  switch failure {
  case .missingProvider: "No provider is bound. Edit the routine to choose one."
  case .providerChanged: "The bound provider changed. Review it in the routine editor."
  case .missingCredential: "Credential unavailable. Configure the provider in Settings."
  case .invalidCredential: "The provider rejected the credential. Check Settings."
  case .loginRequired: "Import a valid Codex login explicitly in Settings for this session."
  case .unavailable: "The provider or network was unavailable. Run again explicitly."
  case .rateLimited: "The provider rate-limited this run. No automatic retry."
  case .invalidResponse: "The provider returned an invalid response."
  case .unsupportedContent: "The provider does not support this content."
  case .attachmentTransmissionUnavailable:
    "Recent context includes stored attachments. Attachment transmission is not available yet; nothing was sent."
  case .outputLimit: "The response exceeded the output limit."
  case .storageUnavailable: "Local storage was unavailable."
  case .invalidSchedule: "The schedule is invalid. Edit the routine."
  case .cancelled: "Stopped. Partial text, if any, is kept in the owner's chat."
  case .interrupted: "Interrupted by app exit or restart; not automatically replayed."
  case .supersededOccurrence:
    "Older missed occurrences were skipped instead of sending a catch-up burst."
  }
}
