import WorkspaceCore
import XCTest

@testable import NativeShell

@MainActor final class ProfileWorkspaceTests: XCTestCase {
  private func fixture() async throws -> (PreviewWorkspace, CoreDataWorkspaceRepository, URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ProfileWorkspaceTests-\(UUID())")
    let url = directory.appendingPathComponent("workspace.sqlite")
    let repository = try await CoreDataWorkspaceRepository.open(at: url)
    let workspace = PreviewWorkspace(seed: false)
    try await workspace.connect(repository, displayName: "Editing fixture")
    addTeardownBlock {
      await workspace.draftSaveTask?.cancel()
      try? await workspace.prepareForClose()
      try? await repository.close()
      try? FileManager.default.removeItem(at: directory)
    }
    return (workspace, repository, url)
  }

  private func bot(_ workspace: PreviewWorkspace, _ name: String) async throws -> UUID {
    try await workspace.performCreateBot(
      name: name, description: "Original", color: "green", shape: .circle)
  }

  func testNativeBotEditPreservesIdentityProviderVisibilityRoutineAndDraftAfterReopen() async throws
  {
    let (workspace, repository, url) = try await fixture()
    let id = try await bot(workspace, "Original")
    let conversationID = try XCTUnwrap(workspace.selectedID)
    workspace.draft = "Keep this draft 👩🏽‍💻"
    try await workspace.flushDrafts()
    workspace.draftSaveTask?.cancel()
    try await workspace.performAddRoutine(name: "Paused", prompt: "No work", interval: 90)
    let target = ProfileEditTarget.bot(id)
    let expected = try await workspace.loadProfile(for: target)
    let provider = ProviderConfig(
      name: "Fixture", apiRoot: URL(string: "https://fixture.invalid/v1")!, modelID: "model",
      credentialReference: "fixture")
    try await repository.apply(.saveProvider(provider))
    let beforeSnapshot = try await repository.snapshot()
    var current = try XCTUnwrap(beforeSnapshot.bots.first { $0.id == id })
    current.providerConfigID = provider.id
    try await repository.apply(.updateBot(current))
    try await repository.apply(.setHidden(botID: id, at: Date(timeIntervalSince1970: 42)))
    _ = try await bot(workspace, "Other")
    let selected = workspace.selectedID
    try await workspace.saveProfile(
      for: target, expected: expected,
      replacement: .bot(
        BotProfile(
          name: "  Edited  ", description: "New description", color: "violet", shape: .drop)))
    XCTAssertEqual(workspace.selectedID, selected)
    XCTAssertEqual(workspace.drafts[conversationID], "Keep this draft 👩🏽‍💻")
    XCTAssertEqual(workspace.conversations.first { $0.id == conversationID }?.title, "Edited")
    try await workspace.prepareForClose()
    try await repository.close()
    let reopened = try await CoreDataWorkspaceRepository.open(at: url)
    let snapshot = try await reopened.snapshot()
    let edited = try XCTUnwrap(snapshot.bots.first { $0.id == id })
    XCTAssertEqual(edited.name, "Edited")
    XCTAssertEqual(edited.createdAt, current.createdAt)
    XCTAssertEqual(edited.description, "New description")
    XCTAssertEqual(edited.shape, .drop)
    XCTAssertEqual(edited.color, "violet")
    XCTAssertEqual(edited.providerConfigID, provider.id)
    XCTAssertEqual(edited.hiddenAt, Date(timeIntervalSince1970: 42))
    XCTAssertEqual(snapshot.routines.count, 1)
    XCTAssertEqual(
      snapshot.drafts.first { $0.conversationID == conversationID }?.text, "Keep this draft 👩🏽‍💻")
    XCTAssertEqual(
      snapshot.conversations.filter { $0.memberBotIDs == [id] }.map(\.id), [conversationID])
    try await reopened.close()
  }

  func testGroupEditPreservesHistoryAndInFlightReplyButClearsRemovedFutureTarget() async throws {
    let (workspace, repository, _) = try await fixture()
    let first = try await bot(workspace, "First")
    let second = try await bot(workspace, "Second")
    let third = try await bot(workspace, "Third")
    let group = try await workspace.performCreateGroup(name: "Together", members: [first, second])
    workspace.selectedTargetBotIDs[group] = [first]
    let expected = try await workspace.loadProfile(for: .group(group))
    let command = SendCommand(conversationID: group, targetBotID: first, text: "Previous question")
    try await repository.apply(.beginGeneration(command))
    try await repository.apply(
      .applyGenerationEvent(
        GenerationEvent(
          generationID: command.generationID,
          attemptID: command.attemptID, sequence: 1, kind: .started)))
    try await repository.apply(
      .applyGenerationEvent(
        GenerationEvent(
          generationID: command.generationID,
          attemptID: command.attemptID, sequence: 2, kind: .delta("Previous reply"))))
    workspace.draft = "Future question"
    try await workspace.flushDrafts()
    try await workspace.saveProfile(
      for: .group(group), expected: expected,
      replacement: .group(GroupProfile(title: "New team", memberBotIDs: [third, second])))
    XCTAssertNil(workspace.selectedTargetBotID)
    XCTAssertNil(workspace.selectedTargetBotIDs[group])
    XCTAssertEqual(workspace.current?.memberIDs, [third, second])
    XCTAssertEqual(workspace.draft, "Future question")
    try await repository.apply(
      .applyGenerationEvent(
        GenerationEvent(
          generationID: command.generationID,
          attemptID: command.attemptID, sequence: 3, kind: .delta(" completed"))))
    try await repository.apply(
      .applyGenerationEvent(
        GenerationEvent(
          generationID: command.generationID,
          attemptID: command.attemptID, sequence: 4, kind: .completed)))
    let messages = try await repository.messages(conversationID: group).messages
    XCTAssertEqual(messages.count, 2)
    XCTAssertEqual(messages.last?.speakerBotID, first)
    XCTAssertEqual(messages.last?.speakerNameSnapshot, "First")
    XCTAssertEqual(messages.last?.text, "Previous reply completed")
    do {
      try await repository.apply(
        .beginGeneration(
          SendCommand(conversationID: group, targetBotID: first, text: "Not a member")))
      XCTFail("Removed members cannot receive future sends")
    } catch { XCTAssertEqual(error as? WorkspaceError, .invalidMembers) }
  }

  func testStaleEditorCannotOverwriteNewProfileAndReloadSeesLatest() async throws {
    let (workspace, repository, _) = try await fixture()
    let id = try await bot(workspace, "Before")
    let target = ProfileEditTarget.bot(id)
    let old = try await workspace.loadProfile(for: target)
    let beforeSnapshot = try await repository.snapshot()
    var current = try XCTUnwrap(beforeSnapshot.bots.first { $0.id == id })
    current.name = "Changed elsewhere"
    try await repository.apply(.updateBot(current))
    do {
      try await workspace.saveProfile(
        for: target, expected: old,
        replacement: .bot(
          BotProfile(
            name: "Stale overwrite", description: "", color: "green", shape: .circle)))
      XCTFail("Must reject")
    } catch { XCTAssertEqual(error as? WorkspaceError, .editConflict) }
    let latest = try await workspace.loadProfile(for: target)
    XCTAssertEqual(latest, .bot(BotProfile(current)))
    XCTAssertFalse(workspace.isProfileSaving)
  }

  func testPreviewEditingUsesSameValidationAndPreservesHiddenMembers() async throws {
    let workspace = PreviewWorkspace(seed: false)
    let first = try await bot(workspace, "First")
    let second = try await bot(workspace, "Second")
    let group = try await workspace.performCreateGroup(name: "Team", members: [first, second])
    let expected = try await workspace.loadProfile(for: .group(group))
    workspace.bots[0].isHidden = true
    try await workspace.saveProfile(
      for: .group(group), expected: expected,
      replacement: .group(GroupProfile(title: "Renamed", memberBotIDs: [second, first])))
    XCTAssertEqual(workspace.current?.memberIDs, [second, first])
    let botSnapshot = try await workspace.loadProfile(for: .bot(first))
    do {
      try await workspace.saveProfile(
        for: .bot(first), expected: botSnapshot,
        replacement: .bot(
          BotProfile(
            name: "Valid", description: String(repeating: "x", count: 8001), color: "green",
            shape: .circle)))
      XCTFail("Same description limit must apply to preview")
    } catch { XCTAssertEqual(error as? WorkspaceError, .invalidDescription) }
    XCTAssertEqual(workspace.bots.first?.description, "Original")
  }

  func testSaveRejectsMismatchedKindsAndClosingWithoutMutation() async throws {
    let (workspace, repository, _) = try await fixture()
    let id = try await bot(workspace, "Unchanged")
    let original = try await workspace.loadProfile(for: .bot(id))
    do {
      try await workspace.saveProfile(
        for: .bot(id), expected: original,
        replacement: .group(GroupProfile(title: "Invalid", memberBotIDs: [])))
      XCTFail("Kind mismatch should fail")
    } catch { XCTAssertEqual(error as? WorkspaceError, .identityConflict) }
    workspace.isClosing = true
    do {
      try await workspace.saveProfile(for: .bot(id), expected: original, replacement: original)
      XCTFail("Closing must prevent a new save")
    } catch { XCTAssertTrue(error is ProviderSetupError) }
    workspace.isClosing = false
    let snapshot = try await repository.snapshot()
    XCTAssertEqual(snapshot.bots.count, 1)
    XCTAssertEqual(snapshot.bots.first?.name, "Unchanged")
  }

  func testControllerClaimsSaveSynchronouslyBeforeQuitCanDiscardIt() async throws {
    let (workspace, repository, _) = try await fixture()
    let id = try await bot(workspace, "Before")
    let controller = ProfileEditorController(store: workspace, target: .bot(id))
    await controller.load()?.value
    controller.setName("Accepted")
    let save = try XCTUnwrap(controller.save())
    // No suspension between Save returning and the quit/window-close guard observing ownership.
    XCTAssertTrue(workspace.isProfileSaving)
    controller.requestCancel()
    XCTAssertFalse(controller.isConfirmingDiscard)
    workspace.isClosing = true
    try await workspace.prepareForClose()
    await save.value
    XCTAssertTrue(controller.shouldDismiss)
    XCTAssertFalse(workspace.isProfileSaving)
    let snapshot = try await repository.snapshot()
    XCTAssertEqual(snapshot.bots.first?.name, "Accepted")
  }

  func testCloseWaitObservesNewerUnsavedEditsAfterControllerSaveCompletes() async throws {
    let (workspace, base, _) = try await fixture()
    let id = try await bot(workspace, "Before")
    let repository = PausingProfileRepository(base: base)
    try await workspace.connect(repository, displayName: "Editing fixture")
    let controller = ProfileEditorController(store: workspace, target: .bot(id))
    await controller.load()?.value
    controller.setName("Accepted")
    let save = try XCTUnwrap(controller.save())
    await repository.waitUntilPaused()
    controller.setDescription("Late unsaved input")
    workspace.isClosing = true
    await repository.release()
    try await workspace.prepareForClose()
    // Termination can now recheck this dirty state instead of assuming the accepted save was all.
    XCTAssertTrue(workspace.profileEditorDirty)
    XCTAssertFalse(controller.shouldDismiss)
    XCTAssertFalse(workspace.isProfileSaving)
    await save.value
    let snapshot = try await base.snapshot()
    XCTAssertEqual(snapshot.bots.first?.name, "Accepted")
    XCTAssertEqual(snapshot.bots.first?.description, "Original")
  }

  func testQuitWaitsForInFlightProfileSaveAndConcurrentSaveIsRejected() async throws {
    let (workspace, base, _) = try await fixture()
    let id = try await bot(workspace, "Before")
    let repository = PausingProfileRepository(base: base)
    try await workspace.connect(repository, displayName: "Editing fixture")
    let expected = try await workspace.loadProfile(for: .bot(id))
    let save = Task {
      try await workspace.saveProfile(
        for: .bot(id), expected: expected,
        replacement: .bot(
          BotProfile(name: "After", description: "", color: "green", shape: .circle)))
    }
    await repository.waitUntilPaused()
    XCTAssertTrue(workspace.isProfileSaving)
    do {
      try await workspace.saveProfile(for: .bot(id), expected: expected, replacement: expected)
      XCTFail("Concurrent save should fail")
    } catch { XCTAssertTrue(error is ProviderSetupError) }
    let quit = Task { try await workspace.prepareForClose() }
    while workspace.profileSaveWaiters.isEmpty { await Task.yield() }
    await repository.release()
    try await save.value
    try await quit.value
    XCTAssertFalse(workspace.isProfileSaving)
    XCTAssertEqual(workspace.bots.first?.name, "After")
    XCTAssertTrue(workspace.coordinatorStopped)
  }
}

private actor PausingProfileRepository: WorkspaceRepository {
  let base: CoreDataWorkspaceRepository
  private var paused = false
  private var observers: [CheckedContinuation<Void, Never>] = []
  private var releaseContinuation: CheckedContinuation<Void, Never>?
  init(base: CoreDataWorkspaceRepository) { self.base = base }
  func snapshot() async throws -> WorkspaceSnapshot { try await base.snapshot() }
  func apply(_ mutation: WorkspaceMutation, expectedRevision: Int64?) async throws -> Int64 {
    if case .editBot = mutation {
      paused = true
      for observer in observers { observer.resume() }
      observers.removeAll()
      await withCheckedContinuation { releaseContinuation = $0 }
    }
    return try await base.apply(mutation, expectedRevision: expectedRevision)
  }
  func waitUntilPaused() async {
    if paused { return }
    await withCheckedContinuation { observers.append($0) }
  }
  func release() {
    releaseContinuation?.resume()
    releaseContinuation = nil
  }
  func messages(conversationID: UUID, beforeSequence: Int64?, limit: Int) async throws
    -> MessagePage
  {
    try await base.messages(
      conversationID: conversationID, beforeSequence: beforeSequence, limit: limit)
  }
  func search(_ query: String, includeHidden: Bool) async throws -> [Conversation] {
    try await base.search(query, includeHidden: includeHidden)
  }
}
