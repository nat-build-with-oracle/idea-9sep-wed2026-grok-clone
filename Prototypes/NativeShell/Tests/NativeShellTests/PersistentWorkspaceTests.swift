import WorkspaceCore
import XCTest

@testable import NativeShell

@MainActor
final class PersistentWorkspaceTests: XCTestCase {
  func testCreatedBotsAndGroupRestoreIntoProjectionAfterReopen() async throws {
    let storeURL = try temporaryStoreURL()
    let repository = try await CoreDataWorkspaceRepository.open(at: storeURL)
    let workspace = PreviewWorkspace(seed: false)
    try await workspace.connect(repository)

    let firstBotID = try await workspace.performCreateBot(
      name: "  First  ", description: "One", color: "blue", shape: .square)
    let secondBotID = try await workspace.performCreateBot(
      name: "Second", description: "Two", color: "violet", shape: .drop)
    let groupID = try await workspace.performCreateGroup(
      name: "  Together  ", members: [secondBotID, firstBotID])
    XCTAssertEqual(workspace.selectedID, groupID)
    try await repository.close()

    let reopenedRepository = try await CoreDataWorkspaceRepository.open(at: storeURL)
    addTeardownBlock { try await reopenedRepository.close() }
    let restored = PreviewWorkspace(seed: false)
    try await restored.connect(reopenedRepository)

    XCTAssertEqual(Set(restored.bots.map(\.id)), [firstBotID, secondBotID])
    XCTAssertEqual(restored.bots.first(where: { $0.id == firstBotID })?.name, "First")
    let restoredGroup = try XCTUnwrap(restored.conversations.first(where: { $0.id == groupID }))
    XCTAssertEqual(restoredGroup.title, "Together")
    XCTAssertEqual(restoredGroup.memberIDs, [secondBotID, firstBotID])
    if case .group = restoredGroup.kind {} else { XCTFail("Expected restored group projection") }
  }

  func testFlushedDraftRestoresForSelectedConversationAfterReopen() async throws {
    let storeURL = try temporaryStoreURL()
    let repository = try await CoreDataWorkspaceRepository.open(at: storeURL)
    let workspace = PreviewWorkspace(seed: false)
    try await workspace.connect(repository)
    _ = try await workspace.performCreateBot(
      name: "Helper", description: "", color: "green", shape: .circle)
    let conversationID = try XCTUnwrap(workspace.selectedID)
    workspace.draft = "สวัสดี\nlocal draft 👩🏽‍💻"

    try await workspace.flushDrafts()
    workspace.draftSaveTask?.cancel()
    try await repository.close()

    let reopenedRepository = try await CoreDataWorkspaceRepository.open(at: storeURL)
    addTeardownBlock { try await reopenedRepository.close() }
    let restored = PreviewWorkspace(seed: false)
    try await restored.connect(reopenedRepository)

    XCTAssertEqual(restored.selectedID, conversationID)
    XCTAssertEqual(restored.draft, "สวัสดี\nlocal draft 👩🏽‍💻")
  }

  func testPausedRoutineRestoresWithIntervalAfterReopen() async throws {
    let storeURL = try temporaryStoreURL()
    let repository = try await CoreDataWorkspaceRepository.open(at: storeURL)
    let workspace = PreviewWorkspace(seed: false)
    try await workspace.connect(repository)
    let botID = try await workspace.performCreateBot(
      name: "Helper", description: "", color: "green", shape: .circle)

    try await workspace.performAddRoutine(
      name: "  Check updates  ", prompt: "Summarize changes", interval: 90)
    try await repository.close()

    let reopenedRepository = try await CoreDataWorkspaceRepository.open(at: storeURL)
    addTeardownBlock { try await reopenedRepository.close() }
    let restored = PreviewWorkspace(seed: false)
    try await restored.connect(reopenedRepository)

    let routine = try XCTUnwrap(restored.routines.first)
    XCTAssertEqual(routine.botID, botID)
    XCTAssertEqual(routine.name, "Check updates")
    XCTAssertEqual(routine.intervalMinutes, 90)
    XCTAssertFalse(routine.enabled)
  }

  func testProviderUnconfiguredSendRetainsDraftAndCreatesNoMessage() async throws {
    let storeURL = try temporaryStoreURL()
    let repository = try await CoreDataWorkspaceRepository.open(at: storeURL)
    addTeardownBlock { try await repository.close() }
    let workspace = PreviewWorkspace(seed: false)
    try await workspace.connect(repository)
    _ = try await workspace.performCreateBot(
      name: "Helper", description: "", color: "green", shape: .circle)
    let conversationID = try XCTUnwrap(workspace.selectedID)
    workspace.draft = "Do not lose this"
    try await workspace.flushDrafts()
    workspace.draftSaveTask?.cancel()

    workspace.performSend()
    try await workspace.flushDrafts()
    let messagePage = try await repository.messages(conversationID: conversationID)
    let snapshot = try await repository.snapshot()

    XCTAssertEqual(workspace.draft, "Do not lose this")
    XCTAssertTrue(workspace.currentMessages.isEmpty)
    XCTAssertTrue(messagePage.messages.isEmpty)
    XCTAssertEqual(
      snapshot.drafts.first(where: {
        $0.conversationID == conversationID
      })?.text,
      "Do not lose this")
    XCTAssertEqual(
      workspace.notice,
      "No AI provider is connected. Your draft is saved locally; no message has been sent.")
  }

  func testFailedCreateBotNeverChangesProjectedBots() async throws {
    let storeURL = try temporaryStoreURL()
    let baseRepository = try await CoreDataWorkspaceRepository.open(at: storeURL)
    addTeardownBlock { try await baseRepository.close() }
    let repository = CreateBotFailingRepository(base: baseRepository)
    let workspace = PreviewWorkspace(seed: false)
    try await workspace.connect(repository)
    let botIDsBefore = workspace.bots.map(\.id)
    let conversationIDsBefore = workspace.conversations.map(\.id)

    do {
      _ = try await workspace.performCreateBot(
        name: "Rejected", description: "", color: "green", shape: .circle)
      XCTFail("Expected repository create failure")
    } catch {
      XCTAssertEqual(error as? WorkspaceError, .storeUnavailable)
    }

    let storedBots = try await baseRepository.snapshot().bots
    XCTAssertEqual(workspace.bots.map(\.id), botIDsBefore)
    XCTAssertEqual(workspace.conversations.map(\.id), conversationIDsBefore)
    XCTAssertTrue(storedBots.isEmpty)
  }

  func testFlushDraftsPersistsNewerEditThatArrivesDuringFirstSave() async throws {
    let storeURL = try temporaryStoreURL()
    let baseRepository = try await CoreDataWorkspaceRepository.open(at: storeURL)
    addTeardownBlock { try await baseRepository.close() }
    let repository = PauseFirstDraftRepository(base: baseRepository)
    let workspace = PreviewWorkspace(seed: false)
    try await workspace.connect(repository)
    _ = try await workspace.performCreateBot(
      name: "Helper", description: "", color: "green", shape: .circle)
    let conversationID = try XCTUnwrap(workspace.selectedID)
    workspace.draft = "first edit"
    workspace.draftSaveTask?.cancel()

    let flush = Task { try await workspace.flushDrafts() }
    await repository.waitUntilFirstDraftSaveIsPaused()
    workspace.draft = "newer edit"
    workspace.draftSaveTask?.cancel()
    await repository.releaseFirstDraftSave()
    try await flush.value
    let snapshot = try await baseRepository.snapshot()

    XCTAssertEqual(
      snapshot.drafts.first(where: { $0.conversationID == conversationID })?.text, "newer edit")
    XCTAssertEqual(workspace.drafts[conversationID], "newer edit")
    XCTAssertTrue(workspace.dirtyDrafts.isEmpty)
  }

  private func temporaryStoreURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "PersistentWorkspaceTests-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return directory.appendingPathComponent("workspace.sqlite")
  }
}

private actor PauseFirstDraftRepository: WorkspaceRepository {
  let base: any WorkspaceRepository
  private var didPauseDraftSave = false
  private var draftSaveIsPaused = false
  private var pauseWaiter: CheckedContinuation<Void, Never>?
  private var releaseContinuation: CheckedContinuation<Void, Never>?

  init(base: any WorkspaceRepository) {
    self.base = base
  }

  func waitUntilFirstDraftSaveIsPaused() async {
    if draftSaveIsPaused { return }
    await withCheckedContinuation { pauseWaiter = $0 }
  }

  func releaseFirstDraftSave() {
    releaseContinuation?.resume()
    releaseContinuation = nil
  }

  func snapshot() async throws -> WorkspaceSnapshot {
    try await base.snapshot()
  }

  func apply(_ mutation: WorkspaceMutation, expectedRevision: Int64?) async throws -> Int64 {
    if case .saveDraft = mutation, !didPauseDraftSave {
      didPauseDraftSave = true
      await withCheckedContinuation { continuation in
        releaseContinuation = continuation
        draftSaveIsPaused = true
        pauseWaiter?.resume()
        pauseWaiter = nil
      }
    }
    return try await base.apply(mutation, expectedRevision: expectedRevision)
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

private actor CreateBotFailingRepository: WorkspaceRepository {
  let base: any WorkspaceRepository

  init(base: any WorkspaceRepository) {
    self.base = base
  }

  func snapshot() async throws -> WorkspaceSnapshot {
    try await base.snapshot()
  }

  func apply(_ mutation: WorkspaceMutation, expectedRevision: Int64?) async throws -> Int64 {
    if case .createBot = mutation { throw WorkspaceError.storeUnavailable }
    return try await base.apply(mutation, expectedRevision: expectedRevision)
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
