import Combine
import Foundation
import WorkspaceCore

enum AvatarKind: String, CaseIterable, Identifiable {
  case circle, square, drop, capsule
  var id: String { rawValue }
}

struct PreviewBot: Identifiable {
  let id: UUID
  var name: String
  var description: String
  var color: String
  var shape: AvatarKind
  var isHidden = false

  init(
    id: UUID = UUID(), name: String, description: String = "", color: String = "green",
    shape: AvatarKind = .circle
  ) {
    self.id = id
    self.name = name
    self.description = description
    self.color = color
    self.shape = shape
  }
}

struct PreviewConversation: Identifiable {
  enum Kind { case direct, group }
  let id: UUID
  var title: String
  var kind: Kind
  var memberIDs: [UUID]
}

struct PreviewMessage: Identifiable {
  enum Role { case user, assistant, event }
  let id: UUID
  let role: Role
  let text: String
  let timestamp: String?
  let speakerName: String?
  let replyToID: UUID?
  let sequence: Int64?
  init(
    _ role: Role, _ text: String, timestamp: String? = nil, id: UUID = UUID(),
    speakerName: String? = nil, replyToID: UUID? = nil, sequence: Int64? = nil
  ) {
    self.id = id
    self.role = role
    self.text = text
    self.timestamp = timestamp
    self.speakerName = speakerName
    self.replyToID = replyToID
    self.sequence = sequence
  }
}

struct PreviewRoutine: Identifiable {
  var id = UUID()
  let botID: UUID
  var name: String
  var intervalMinutes: Int
  var enabled: Bool
}

enum PreviewError: Error, Equatable, LocalizedError {
  case invalidName, invalidMembers, missingConversation, invalidInterval
  var errorDescription: String? {
    switch self {
    case .invalidName: "Use a name between 1 and 80 characters."
    case .invalidMembers: "Choose two to six different available bots."
    case .missingConversation: "This conversation is no longer available."
    case .invalidInterval: "Use an interval of at least five minutes."
    }
  }
}

enum ComposerInputPolicy {
  static func shouldSubmit(
    isReturn: Bool, shift: Bool, hasMarkedText: Bool, otherModifiers: Bool = false
  ) -> Bool {
    isReturn && !shift && !hasMarkedText && !otherModifiers
  }
}

/// Presentation projection. Sample mode is in-memory; durable mode delegates mutations to WorkspaceCore.
@MainActor final class PreviewWorkspace: ObservableObject {
  enum PickerMode { case closed, single, group }
  enum Panel: String, Identifiable {
    case settings, newBot, templates, routine, profile
    var id: String { rawValue }
  }

  @Published var bots: [PreviewBot] = []
  @Published var conversations: [PreviewConversation] = []
  @Published var messages: [UUID: [PreviewMessage]] = [:]
  @Published var drafts: [UUID: String] = [:]
  @Published var draftReplyIDs: [UUID: UUID] = [:]
  @Published var replyPreviews: [UUID: [UUID: ReplyPreview]] = [:]
  @Published var transcriptJumpRequest: TranscriptJumpRequest?
  @Published var isJumpingToReply = false
  var replyContextGeneration = 0
  var replyChoiceRequests: [UUID: Int] = [:]
  var replyJumpGeneration = 0
  @Published var routines: [PreviewRoutine] = []
  @Published var selectedID: UUID?
  @Published var search = ""
  @Published var pickerQuery = ""
  @Published var pickerMode: PickerMode = .closed
  @Published var selectedRecipients: [UUID] = []
  @Published var highlightedRecipient = 0
  @Published var inspectorPreferred = true
  @Published var sidebarVisible = true
  @Published var panel: Panel?
  @Published var editTarget: ProfileEditTarget?
  @Published var profileEditorDirty = false
  @Published var isProfileSaving = false
  var profileEditorSaveTask: Task<Void, Never>?
  var profileSaveWaiters: [CheckedContinuation<Void, Never>] = []
  @Published var notice: String?
  @Published var name = "Demo User"
  @Published var searchFocusRequest = 0
  @Published var composerFocusRequest = 0
  @Published var showHidden = false
  @Published var isPersistent = false
  @Published var isLoading = false
  @Published var storageError: String?
  @Published var isSaving = false
  @Published var isClosing = false
  @Published var isExporting = false
  @Published var exportStatus: String?
  @Published var exportError: String?
  var exportTask: Task<Void, Never>?
  var isExportWriting = false
  var cancelExportSelection: (() -> Void)?
  @Published var hasOlderMessages = false
  @Published var persistentSearchIDs: Set<UUID>?
  @Published var providers: [ProviderConfig] = []
  @Published var selectedProviderID: UUID?
  @Published var selectedTargetBotIDs: [UUID: UUID] = [:]
  @Published var generations: [Generation] = []
  @Published var isSubmitting = false
  @Published var isProviderSaving = false
  @Published var providerSettingsDirty = false
  @Published var pendingGenerationActions: Set<UUID> = []
  var coordinator: GenerationCoordinator?
  var credentials: (any CredentialStore)?
  var chatProvider: (any ChatProvider)?
  var sendTask: Task<Void, Never>?
  var providerSaveWaiters: [CheckedContinuation<Void, Never>] = []
  var coordinatorStopped = false
  var providerShutdownStarted = false
  var openSettingsAction: (() -> Void)?
  var repository: (any WorkspaceRepository)?
  var dirtyDrafts: Set<UUID> = []
  var draftVersions: [UUID: Int] = [:]
  var draftSaveTask: Task<Void, Never>?
  var draftFlushTask: Task<Void, Error>?
  var selectionRequest = 0
  var olderCursor: Int64?
  var retryOpening: (() -> Void)?
  var searchRequest = 0

  init(seed: Bool = true) {
    if seed { seedReference() }
  }

  var current: PreviewConversation? { conversations.first { $0.id == selectedID } }
  var currentBot: PreviewBot? {
    guard let current, current.kind == .direct, let member = current.memberIDs.first else {
      return nil
    }
    return bots.first { $0.id == member }
  }
  var currentMessages: [PreviewMessage] { selectedID.flatMap { messages[$0] } ?? [] }
  var draft: String {
    get { selectedID.flatMap { drafts[$0] } ?? "" }
    set {
      if let selectedID {
        drafts[selectedID] = newValue
        if isPersistent { scheduleDraftSave(selectedID) }
      }
    }
  }

  var visibleConversations: [PreviewConversation] {
    conversations.filter { item in
      let isHidden =
        item.kind == .direct
        && bots.first(where: { $0.id == item.memberIDs.first })?.isHidden == true
      guard showHidden || !isHidden else { return false }
      let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
      if isPersistent, !query.isEmpty { return persistentSearchIDs?.contains(item.id) == true }
      return query.isEmpty || item.title.localizedStandardContains(query)
        || (messages[item.id] ?? []).contains { $0.text.localizedStandardContains(query) }
    }
  }

  var availableRecipients: [PreviewBot] {
    bots.filter {
      !$0.isHidden && !selectedRecipients.contains($0.id)
        && (pickerQuery.isEmpty || $0.name.localizedStandardContains(pickerQuery))
    }
  }

  func select(_ id: UUID) {
    guard conversations.contains(where: { $0.id == id }) else { return }
    if isPersistent {
      selectionRequest += 1
      let request = selectionRequest
      Task {
        do {
          try await flushDrafts()
          guard request == selectionRequest else { return }
          selectedID = id
          pickerMode = .closed
          notice = nil
          composerFocusRequest += 1
          try await loadMessages(id)
        } catch { storageError = error.localizedDescription }
      }
      return
    }
    selectedID = id
    pickerMode = .closed
    notice = nil
    composerFocusRequest += 1
  }

  func openPicker(group: Bool = false) {
    pickerMode = group ? .group : .single
    pickerQuery = ""
    selectedRecipients = []
    highlightedRecipient = 0
    notice = nil
  }

  func selectRecipient(_ id: UUID) {
    if pickerMode == .group {
      guard selectedRecipients.count < 6, !selectedRecipients.contains(id) else { return }
      selectedRecipients.append(id)
      pickerQuery = ""
      highlightedRecipient = 0
    } else if let conversation = conversations.first(where: {
      $0.kind == .direct && $0.memberIDs == [id]
    }) {
      select(conversation.id)
    }
  }

  @discardableResult func createBot(
    name: String, description: String, color: String, shape: AvatarKind
  ) throws -> UUID {
    let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (1...80).contains(cleanName.count) else { throw PreviewError.invalidName }
    let bot = PreviewBot(name: cleanName, description: description, color: color, shape: shape)
    let conversation = PreviewConversation(
      id: UUID(), title: cleanName, kind: .direct, memberIDs: [bot.id])
    bots.append(bot)
    conversations.insert(conversation, at: 0)
    messages[conversation.id] = []
    select(conversation.id)
    panel = nil
    return bot.id
  }

  @discardableResult func createGroup(name: String, members: [UUID]) throws -> UUID {
    let unique = Array(Set(members))
    guard (2...6).contains(members.count), unique.count == members.count,
      members.allSatisfy({ member in bots.contains { $0.id == member && !$0.isHidden } })
    else {
      throw PreviewError.invalidMembers
    }
    let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (1...80).contains(cleanName.count) else { throw PreviewError.invalidName }
    let conversation = PreviewConversation(
      id: UUID(), title: cleanName, kind: .group, memberIDs: members)
    conversations.insert(conversation, at: 0)
    messages[conversation.id] = []
    select(conversation.id)
    return conversation.id
  }

  func saveLocalMessage() throws {
    guard let selectedID, conversations.contains(where: { $0.id == selectedID }) else {
      throw PreviewError.missingConversation
    }
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    messages[selectedID, default: []].append(
      PreviewMessage(
        .user, text, timestamp: "Just now · preview only", replyToID: draftReplyIDs[selectedID]))
    drafts[selectedID] = ""
    draftReplyIDs[selectedID] = nil
    notice = "Preview message only. No AI provider is connected; this session is not saved to disk."
  }

  func addRoutine(name: String, interval: Int) throws {
    let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (1...80).contains(clean.count) else { throw PreviewError.invalidName }
    guard interval >= 5 else { throw PreviewError.invalidInterval }
    guard let bot = currentBot else { throw PreviewError.missingConversation }
    routines.append(
      PreviewRoutine(botID: bot.id, name: clean, intervalMinutes: interval, enabled: false))
    panel = nil
    notice = "Routine added to the preview. Scheduling is not connected."
  }

  func toggleHidden(_ conversation: PreviewConversation) {
    guard conversation.kind == .direct,
      let index = bots.firstIndex(where: { $0.id == conversation.memberIDs.first })
    else { return }
    bots[index].isHidden.toggle()
  }

  func seedReference() {
    let fixtures: [(String, String, AvatarKind, String)] = [
      ("New Bot", "green", .circle, "Your everyday assistant"),
      ("Network Helper", "magenta", .square, "Infrastructure and networking"),
      ("Projects Manager", "magenta", .drop, "Keep projects moving"),
      ("Research Helper", "gray", .drop, "Research and compare options"),
      ("Workspace Guide", "gray", .capsule, "Coordinate your workspace"),
      ("Reading Buddy", "violet", .square, "A research teammate"),
      ("Sandbox", "blue", .circle, "A space to try things"),
    ]
    let previews = [
      "A fictional daily planning example…", "Sample network checklist, not a live connection.",
      "A demo project outline is ready to explore.", "Compare these fictional options.",
      "Welcome to the sample workspace.", "A sample reading list for your next project.",
      "นี่คือตัวอย่างพื้นที่ทำงาน ไม่มีการเชื่อมต่อบริการภายนอก",
    ]
    for (index, fixture) in fixtures.enumerated() {
      let bot = PreviewBot(
        name: fixture.0, description: fixture.3, color: fixture.1, shape: fixture.2)
      let conversation = PreviewConversation(
        id: UUID(), title: bot.name, kind: .direct, memberIDs: [bot.id])
      bots.append(bot)
      conversations.append(conversation)
      messages[conversation.id] = [
        PreviewMessage(.assistant, previews[index], timestamp: "Sample conversation")
      ]
    }
    guard let first = conversations.first, let botID = first.memberIDs.first else { return }
    selectedID = first.id
    messages[first.id] = [
      PreviewMessage(
        .assistant,
        "Welcome! This is a fictional sample conversation for exploring the native layout."),
      PreviewMessage(.user, "Show me an example of a daily project check-in."),
      PreviewMessage(
        .assistant,
        "A sample check-in could summarize the current milestone, open questions and a small next step. Nothing is scheduled or sent from this preview."
      ),
      PreviewMessage(.event, "Sample routine  ◷ Project check-in — paused"),
      PreviewMessage(
        .assistant,
        "For this fictional project, the first milestone is an outline. Gather a few notes, choose one question to answer and keep the result easy to review. This is example content, not work performed by a connected model."
      ),
      PreviewMessage(
        .assistant,
        "Sample afternoon check-in: the outline has three sections and one open question. The next step could be a short draft. These details are invented for the preview, not read from a real project.",
        timestamp: "Today 2:50 PM"),
      PreviewMessage(
        .assistant,
        "Sample review note: keep the draft focused on a single question. Save the remaining ideas for another session. The preview does not connect to your files, accounts or external services.",
        timestamp: "Today 5:45 PM"),
      PreviewMessage(
        .assistant,
        "Sample evening check-in: leave a short note about the next step and return when ready. This fictional conversation exists only to demonstrate the interface; the routine remains paused.",
        timestamp: "Today 9:06 PM"),
    ]
    routines = [
      PreviewRoutine(botID: botID, name: "Project check-in", intervalMinutes: 180, enabled: false)
    ]
  }
}
