import SwiftUI

private struct BotDeletionSheetPolicy: NSViewRepresentable {
  func makeNSView(context: Context) -> ProfileSheetPolicyView { ProfileSheetPolicyView() }
  func updateNSView(_ nsView: ProfileSheetPolicyView, context: Context) {}
}

struct BotDeletionView: View {
  @ObservedObject var store: PreviewWorkspace

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Permanently delete bot?").font(.title2.weight(.semibold))
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          if store.isLoadingBotDeletion {
            ProgressView("Checking affected records…")
          } else if let plan = store.botDeletionPlan {
            Text(plan.name).font(.headline).textSelection(.enabled)
            Text(
              "Delete \(plan.directConversationCount) direct conversations, \(plan.messageCount) messages, \(plan.draftCount) drafts, \(plan.generationCount) generation records, \(plan.routineCount) owned routines and \(plan.routineRunCount) routine history records."
            )
            Text(
              "Stop \(plan.activeGenerationIDs.count) active or queued replies in affected conversations. Completed and partial group history stays, with recorded speaker names."
            )
            if !plan.activeRoutineRunIDs.isEmpty {
              Text(
                "Stop \(plan.activeRoutineRunIDs.count) active routine runs, including any waiting to connect."
              )
            }
            if !plan.affectedGroups.isEmpty {
              VStack(alignment: .leading, spacing: 7) {
                Text("Remove from \(plan.affectedGroupCount) groups:").font(.headline)
                ForEach(plan.affectedGroups) { group in
                  Text(
                    "• \(group.title) — \(group.remainingMemberBotIDs.count) members remain"
                      + (group.remainingMemberBotIDs.count < 2 ? "; repair before sending" : "")
                  )
                }
              }
            }
            Text(
              "Provider configurations and stored credentials are kept. This cannot be undone. Cancel and export first if you need a copy."
            ).font(.callout).foregroundStyle(ShellTheme.secondary)
          }
          if let error = store.botDeletionError {
            Text(error).foregroundStyle(.orange)
            Button("Review Current Impact") { store.reloadBotDeletionPlan() }
              .disabled(store.isDeletingBot || store.isLoadingBotDeletion)
              .accessibilityIdentifier("bot-delete-reload")
          }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
      }.frame(maxHeight: 400)
      HStack {
        Button("Cancel") { store.cancelBotDeletion() }
          .keyboardShortcut(.cancelAction).disabled(store.isDeletingBot)
        Spacer()
        if store.isDeletingBot { ProgressView().controlSize(.small) }
        Button("Delete Bot", role: .destructive) { store.confirmBotDeletion() }
          .disabled(
            store.botDeletionPlan == nil || store.isDeletingBot || store.isLoadingBotDeletion
          )
          .accessibilityIdentifier("bot-delete-confirm")
      }
    }
    .padding(26).frame(width: 500)
    .foregroundStyle(ShellTheme.foreground).background(ShellTheme.sidebar)
    .background(BotDeletionSheetPolicy())
    .preferredColorScheme(.dark)
    .interactiveDismissDisabled(true)
    .onExitCommand { store.cancelBotDeletion() }
    .accessibilityIdentifier("bot-delete-sheet")
  }
}
