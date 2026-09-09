import Foundation
import XCTest

@testable import NativeShell
@testable import WorkspaceCore

@MainActor
final class ProviderWorkspaceTests: XCTestCase {
  func testSaveProviderKeepsSecretOutOfPersistedMetadata() async throws {
    let (repository, _) = try await openRepository()
    let credentials = RecordingCredentialStore()
    let workspace = PreviewWorkspace(seed: false)
    try await workspace.connect(repository, credentials: credentials, provider: ScriptedProvider())

    let providerID = try await workspace.saveProvider(
      id: nil, name: "  Test Provider  ", apiRoot: "https://fixture.invalid/v1",
      modelID: "  fixture-model  ", secret: "test-only-secret", allowsLoopbackHTTP: false)

    let savedProviders = try await repository.snapshot().providers
    let configuration = try XCTUnwrap(savedProviders.first(where: { $0.id == providerID }))
    XCTAssertEqual(configuration.name, "Test Provider")
    XCTAssertEqual(configuration.modelID, "fixture-model")
    XCTAssertNotEqual(configuration.credentialReference, "test-only-secret")
    let savedSecret = await credentials.secret(for: configuration.credentialReference)
    XCTAssertEqual(savedSecret, Data("test-only-secret".utf8))
    XCTAssertEqual(workspace.selectedProviderID, providerID)
  }

  func testInvalidProviderURLIsRejectedBeforeCredentialWrite() async throws {
    let (repository, _) = try await openRepository()
    let credentials = RecordingCredentialStore()
    let workspace = PreviewWorkspace(seed: false)
    try await workspace.connect(repository, credentials: credentials, provider: ScriptedProvider())

    do {
      _ = try await workspace.saveProvider(
        id: nil, name: "Unsafe", apiRoot: "http://example.com/v1", modelID: "model",
        secret: "must-not-be-written", allowsLoopbackHTTP: false)
      XCTFail("Expected invalid provider URL")
    } catch {
      XCTAssertEqual(error as? WorkspaceError, .invalidProvider)
    }

    let writes = await credentials.writtenReferences()
    let providers = try await repository.snapshot().providers
    XCTAssertTrue(writes.isEmpty)
    XCTAssertTrue(providers.isEmpty)
  }

  func testCredentialWriteFailureDoesNotPersistProviderMetadata() async throws {
    let (repository, _) = try await openRepository()
    let credentials = RecordingCredentialStore()
    await credentials.failNextWrite()
    let workspace = PreviewWorkspace(seed: false)
    try await workspace.connect(repository, credentials: credentials, provider: ScriptedProvider())

    do {
      _ = try await workspace.saveProvider(
        id: nil, name: "Provider", apiRoot: "https://fixture.invalid/v1", modelID: "model",
        secret: "rejected-secret", allowsLoopbackHTTP: false)
      XCTFail("Expected credential write failure")
    } catch {
      XCTAssertEqual(error as? ProviderError, .keychain(-50))
    }

    let providers = try await repository.snapshot().providers
    let secrets = await credentials.allSecrets()
    XCTAssertTrue(providers.isEmpty)
    XCTAssertTrue(secrets.isEmpty)
  }

  func testMetadataWriteFailureRemovesReplacementAndPreservesExistingCredential() async throws {
    let (base, _) = try await openRepository()
    let repository = ProviderSaveFailingRepository(base: base)
    let credentials = RecordingCredentialStore()
    let workspace = PreviewWorkspace(seed: false)
    try await workspace.connect(repository, credentials: credentials, provider: ScriptedProvider())
    let providerID = try await workspace.saveProvider(
      id: nil, name: "Original", apiRoot: "https://fixture.invalid/v1", modelID: "old-model",
      secret: "old-secret", allowsLoopbackHTTP: false)
    let initialProviders = try await base.snapshot().providers
    let original = try XCTUnwrap(initialProviders.first)
    await repository.failNextProviderSave()

    do {
      _ = try await workspace.saveProvider(
        id: providerID, name: "Replacement", apiRoot: "https://fixture.invalid/v1",
        modelID: "new-model", secret: "new-secret", allowsLoopbackHTTP: false)
      XCTFail("Expected metadata persistence failure")
    } catch {
      XCTAssertEqual(error as? WorkspaceError, .storeUnavailable)
    }

    let providers = try await base.snapshot().providers
    let oldSecret = await credentials.secret(for: original.credentialReference)
    let secrets = await credentials.allSecrets()
    XCTAssertEqual(providers, [original])
    XCTAssertEqual(oldSecret, Data("old-secret".utf8))
    XCTAssertEqual(secrets.count, 1)
    let removed = await credentials.removedReferences()
    XCTAssertEqual(removed.count, 1)
    XCTAssertNotEqual(removed.first, original.credentialReference)
  }

  func testBlankCredentialEditRetainsExistingCredentialReferenceAndSecret() async throws {
    let (repository, _) = try await openRepository()
    let credentials = RecordingCredentialStore()
    let workspace = PreviewWorkspace(seed: false)
    try await workspace.connect(repository, credentials: credentials, provider: ScriptedProvider())
    let providerID = try await workspace.saveProvider(
      id: nil, name: "Original", apiRoot: "https://fixture.invalid/v1", modelID: "old-model",
      secret: "existing-secret", allowsLoopbackHTTP: false)
    let initialProviders = try await repository.snapshot().providers
    let original = try XCTUnwrap(initialProviders.first)

    _ = try await workspace.saveProvider(
      id: providerID, name: "Renamed", apiRoot: "https://fixture.invalid/v1",
      modelID: "new-model", secret: "", allowsLoopbackHTTP: false)

    let editedProviders = try await repository.snapshot().providers
    let edited = try XCTUnwrap(editedProviders.first)
    XCTAssertEqual(edited.id, original.id)
    XCTAssertEqual(edited.credentialReference, original.credentialReference)
    let secret = await credentials.secret(for: edited.credentialReference)
    let writes = await credentials.writtenReferences()
    let removals = await credentials.removedReferences()
    XCTAssertEqual(secret, Data("existing-secret".utf8))
    XCTAssertEqual(writes.count, 1)
    XCTAssertTrue(removals.isEmpty)
  }

  func testSubmitDraftPersistsStreamedAttributedReply() async throws {
    let (repository, _) = try await openRepository()
    let credentials = RecordingCredentialStore()
    let provider = ScriptedProvider()
    let workspace = PreviewWorkspace(seed: false)
    try await workspace.connect(repository, credentials: credentials, provider: provider)
    _ = try await saveFixtureProvider(in: workspace)
    let botID = try await workspace.performCreateBot(
      name: "Research Partner", description: "Answer carefully", color: "green", shape: .circle)
    let conversationID = try XCTUnwrap(workspace.selectedID)
    workspace.draft = "What changed?"
    workspace.draftSaveTask?.cancel()
    var starts = provider.starts.makeAsyncIterator()

    let generationID = try await workspace.submitDraft()
    let start = await starts.next()
    XCTAssertEqual(start, 0)
    provider.send(.text("A grounded answer"), to: 0)
    provider.send(.finished, to: 0, finish: true)
    await workspace.coordinator?.waitForIdle()

    let snapshot = try await repository.snapshot()
    let page = try await repository.messages(conversationID: conversationID)
    XCTAssertEqual(snapshot.generations.first(where: { $0.id == generationID })?.state, .completed)
    XCTAssertEqual(page.messages.map(\.role), [.user, .assistant])
    XCTAssertEqual(page.messages.map(\.text), ["What changed?", "A grounded answer"])
    XCTAssertEqual(page.messages.last?.speakerBotID, botID)
    XCTAssertEqual(page.messages.last?.speakerNameSnapshot, "Research Partner")
    XCTAssertEqual(workspace.currentMessages.last?.speakerName, "Research Partner")
    XCTAssertEqual(workspace.draft, "")
  }

  func testMissingCredentialKeepsDraftAndNeverStartsTransport() async throws {
    let (repository, _) = try await openRepository()
    let credentials = RecordingCredentialStore()
    let provider = ScriptedProvider()
    let workspace = PreviewWorkspace(seed: false)
    try await workspace.connect(repository, credentials: credentials, provider: provider)
    _ = try await saveFixtureProvider(in: workspace)
    await credentials.failReads()
    _ = try await workspace.performCreateBot(
      name: "Helper", description: "", color: "green", shape: .circle)
    let conversationID = try XCTUnwrap(workspace.selectedID)
    workspace.draft = "Keep this draft"
    workspace.draftSaveTask?.cancel()

    do {
      _ = try await workspace.submitDraft()
      XCTFail("Expected missing credential")
    } catch {
      XCTAssertEqual(error as? ProviderError, .missingCredential)
    }

    let snapshot = try await repository.snapshot()
    XCTAssertEqual(workspace.draft, "Keep this draft")
    XCTAssertEqual(
      snapshot.drafts.first(where: { $0.conversationID == conversationID })?.text,
      "Keep this draft")
    XCTAssertTrue(snapshot.generations.isEmpty)
    let page = try await repository.messages(conversationID: conversationID)
    XCTAssertTrue(page.messages.isEmpty)
    XCTAssertEqual(provider.callCount, 0)
  }

  func testGroupSubmitRequiresExplicitTargetBeforeCreatingMessage() async throws {
    let (repository, _) = try await openRepository()
    let credentials = RecordingCredentialStore()
    let provider = ScriptedProvider()
    let workspace = PreviewWorkspace(seed: false)
    try await workspace.connect(repository, credentials: credentials, provider: provider)
    _ = try await saveFixtureProvider(in: workspace)
    let first = try await workspace.performCreateBot(
      name: "First", description: "", color: "green", shape: .circle)
    let second = try await workspace.performCreateBot(
      name: "Second", description: "", color: "blue", shape: .square)
    let groupID = try await workspace.performCreateGroup(name: "Team", members: [first, second])
    workspace.draft = "Who should answer?"
    workspace.draftSaveTask?.cancel()

    do {
      _ = try await workspace.submitDraft()
      XCTFail("Expected explicit group target requirement")
    } catch {
      XCTAssertEqual(error as? ProviderSetupError, .targetRequired)
    }

    XCTAssertNil(workspace.selectedTargetBotIDs[groupID])
    XCTAssertEqual(provider.callCount, 0)
    let snapshot = try await repository.snapshot()
    let page = try await repository.messages(conversationID: groupID)
    XCTAssertTrue(snapshot.generations.isEmpty)
    XCTAssertTrue(page.messages.isEmpty)
  }

  func testCancelledPartialReplyRejectsLateEventsAndRetryReusesOriginalUser() async throws {
    let (repository, _) = try await openRepository()
    let credentials = RecordingCredentialStore()
    let provider = ScriptedProvider()
    let workspace = PreviewWorkspace(seed: false)
    try await workspace.connect(repository, credentials: credentials, provider: provider)
    _ = try await saveFixtureProvider(in: workspace)
    _ = try await workspace.performCreateBot(
      name: "Helper", description: "", color: "green", shape: .circle)
    let conversationID = try XCTUnwrap(workspace.selectedID)
    workspace.draft = "Original question"
    workspace.draftSaveTask?.cancel()
    var starts = provider.starts.makeAsyncIterator()

    let generationID = try await workspace.submitDraft()
    let firstStart = await starts.next()
    XCTAssertEqual(firstStart, 0)
    provider.send(.text("Partial"), to: 0)
    try await waitUntil {
      try await repository.messages(conversationID: conversationID).messages.last?.text == "Partial"
    }
    let startedGenerations = try await repository.snapshot().generations
    let originalAttempt = try XCTUnwrap(
      startedGenerations.first(where: { $0.id == generationID })?.attemptID)
    try await workspace.cancelReply(generationID)
    provider.send(.text(" late"), to: 0)
    provider.send(.finished, to: 0, finish: true)
    let cancelledGenerations = try await repository.snapshot().generations
    XCTAssertEqual(
      cancelledGenerations.first(where: { $0.id == generationID })?.state, .cancelled)
    // The UI contract permits retry as soon as cancelReply returns; it must not depend on a race
    // with teardown of the old transport task.
    try await workspace.retryReply(generationID)
    let retryStart = await starts.next()
    XCTAssertEqual(retryStart, 1)
    provider.send(.text("New answer"), to: 1)
    provider.send(.finished, to: 1, finish: true)
    await workspace.coordinator?.waitForIdle()

    let page = try await repository.messages(conversationID: conversationID)
    let completedGenerations = try await repository.snapshot().generations
    let generation = try XCTUnwrap(
      completedGenerations.first(where: { $0.id == generationID }))
    XCTAssertEqual(page.messages.filter { $0.role == .user }.map(\.text), ["Original question"])
    XCTAssertEqual(
      page.messages.filter { $0.role == .assistant }.map(\.text), ["Partial", "New answer"])
    XCTAssertEqual(page.messages.filter { $0.role == .event }.count, 1)
    XCTAssertEqual(generation.state, .completed)
    XCTAssertNotEqual(generation.attemptID, originalAttempt)
  }

  func testDraftEditedWhileCredentialReadIsPausedSurvivesOriginalSubmission() async throws {
    let (repository, _) = try await openRepository()
    let credentials = RecordingCredentialStore()
    let provider = ScriptedProvider()
    let workspace = PreviewWorkspace(seed: false)
    try await workspace.connect(repository, credentials: credentials, provider: provider)
    _ = try await saveFixtureProvider(in: workspace)
    _ = try await workspace.performCreateBot(
      name: "Helper", description: "", color: "green", shape: .circle)
    let conversationID = try XCTUnwrap(workspace.selectedID)
    workspace.draft = "Original draft"
    workspace.draftSaveTask?.cancel()
    await credentials.pauseNextRead()
    var starts = provider.starts.makeAsyncIterator()

    let submission = Task { try await workspace.submitDraft() }
    await credentials.waitUntilReadIsPaused()
    workspace.draft = "Newer draft"
    workspace.draftSaveTask?.cancel()
    await credentials.resumeRead()
    _ = try await submission.value
    let start = await starts.next()
    XCTAssertEqual(start, 0)
    provider.send(.text("Answer"), to: 0)
    provider.send(.finished, to: 0, finish: true)
    await workspace.coordinator?.waitForIdle()
    try await workspace.flushDrafts()

    let snapshot = try await repository.snapshot()
    let page = try await repository.messages(conversationID: conversationID)
    XCTAssertEqual(page.messages.filter { $0.role == .user }.map(\.text), ["Original draft"])
    XCTAssertEqual(workspace.draft, "Newer draft")
    XCTAssertEqual(
      snapshot.drafts.first(where: { $0.conversationID == conversationID })?.text, "Newer draft")
  }

  func testPrepareForCloseNeverStartsReplyQueuedBehindActiveConversation() async throws {
    let (repository, _) = try await openRepository()
    let credentials = RecordingCredentialStore()
    let provider = ScriptedProvider()
    let workspace = PreviewWorkspace(seed: false)
    try await workspace.connect(repository, credentials: credentials, provider: provider)
    _ = try await saveFixtureProvider(in: workspace)
    _ = try await workspace.performCreateBot(
      name: "Helper", description: "", color: "green", shape: .circle)
    workspace.draft = "First question"
    workspace.draftSaveTask?.cancel()
    var starts = provider.starts.makeAsyncIterator()

    _ = try await workspace.submitDraft()
    let firstStart = await starts.next()
    XCTAssertEqual(firstStart, 0)
    workspace.draft = "Queued question"
    workspace.draftSaveTask?.cancel()
    _ = try await workspace.submitDraft()
    XCTAssertEqual(provider.callCount, 1)

    try await workspace.prepareForClose()

    let generations = try await repository.snapshot().generations
    XCTAssertEqual(provider.callCount, 1)
    XCTAssertEqual(generations.count, 2)
    XCTAssertTrue(generations.allSatisfy { $0.state == .cancelled })
  }

  private func saveFixtureProvider(in workspace: PreviewWorkspace) async throws -> UUID {
    try await workspace.saveProvider(
      id: nil, name: "Fixture", apiRoot: "https://fixture.invalid/v1",
      modelID: "fixture-model", secret: "test-only-sentinel", allowsLoopbackHTTP: false)
  }

  func testChangingDestinationRequiresExplicitCredentialReentry() async throws {
    let (repository, _) = try await openRepository()
    let credentials = RecordingCredentialStore()
    let workspace = PreviewWorkspace(seed: false)
    try await workspace.connect(repository, credentials: credentials, provider: ScriptedProvider())
    let id = try await saveFixtureProvider(in: workspace)
    let before = try await repository.snapshot().providers
    let keysBefore = await credentials.allSecrets()
    do {
      _ = try await workspace.saveProvider(
        id: id, name: "Different destination", apiRoot: "https://another.invalid/v1",
        modelID: "fixture-model", secret: "", allowsLoopbackHTTP: false)
      XCTFail("Expected credential re-entry requirement")
    } catch {
      guard case ProviderSetupError.changedDestination = error else {
        return XCTFail("Expected controlled destination error")
      }
    }
    let after = try await repository.snapshot().providers
    let keysAfter = await credentials.allSecrets()
    XCTAssertEqual(after, before)
    XCTAssertEqual(keysAfter, keysBefore)
  }

  func testFailedQuitCanRecoverStorageAndAcceptANewReplyWithoutReplayingQueue() async throws {
    let (repository, _) = try await openRepository()
    let credentials = RecordingCredentialStore()
    let provider = ScriptedProvider()
    let workspace = PreviewWorkspace(seed: false)
    try await workspace.connect(repository, credentials: credentials, provider: provider)
    _ = try await saveFixtureProvider(in: workspace)
    _ = try await workspace.performCreateBot(
      name: "Helper", description: "", color: "green", shape: .circle)
    var starts = provider.starts.makeAsyncIterator()
    workspace.draft = "First"
    _ = try await workspace.submitDraft()
    _ = await starts.next()
    workspace.draft = "Queued"
    _ = try await workspace.submitDraft()
    await repository.injectNextSaveFailure()
    workspace.isClosing = true
    do {
      try await workspace.prepareForClose()
      XCTFail("Expected shutdown save failure")
    } catch { XCTAssertEqual(error as? WorkspaceError, .storeUnavailable) }
    workspace.isClosing = false
    try await workspace.recoverStorage()
    XCTAssertEqual(provider.callCount, 1)
    workspace.draft = "After recovery"
    _ = try await workspace.submitDraft()
    let restarted = await starts.next()
    XCTAssertEqual(restarted, 1)
    provider.send(.text("Recovered reply"), to: 1)
    provider.send(.finished, to: 1, finish: true)
    await workspace.coordinator?.waitForIdle()
    let states = try await repository.snapshot().generations.map(\.state)
    XCTAssertEqual(states.filter { $0 == .cancelled }.count, 2)
    XCTAssertEqual(states.filter { $0 == .completed }.count, 1)
    XCTAssertEqual(provider.callCount, 2)
  }

  private func openRepository() async throws -> (CoreDataWorkspaceRepository, URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ProviderWorkspaceTests-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let repository = try await CoreDataWorkspaceRepository.open(
      at: directory.appendingPathComponent("workspace.sqlite"))
    addTeardownBlock {
      try await repository.close()
      try? FileManager.default.removeItem(at: directory)
    }
    return (repository, directory)
  }

  private func waitUntil(
    _ condition: @escaping @Sendable () async throws -> Bool, file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    for _ in 0..<200 {
      if try await condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Timed out waiting for condition", file: file, line: line)
    throw ProviderWorkspaceTestError.timedOut
  }
}

private enum ProviderWorkspaceTestError: Error { case timedOut }

private actor RecordingCredentialStore: CredentialStore {
  private var secrets: [String: Data] = [:]
  private var writes: [String] = []
  private var removals: [String] = []
  private var rejectNextWrite = false
  private var rejectReads = false
  private var shouldPauseNextRead = false
  private var readIsPaused = false
  private var readPauseWaiter: CheckedContinuation<Void, Never>?
  private var readRelease: CheckedContinuation<Void, Never>?

  func failNextWrite() { rejectNextWrite = true }
  func failReads() { rejectReads = true }
  func pauseNextRead() { shouldPauseNextRead = true }

  func waitUntilReadIsPaused() async {
    if readIsPaused { return }
    await withCheckedContinuation { readPauseWaiter = $0 }
  }

  func resumeRead() {
    readRelease?.resume()
    readRelease = nil
  }

  func read(_ reference: String) async throws -> Data {
    if rejectReads { throw ProviderError.missingCredential }
    if shouldPauseNextRead {
      shouldPauseNextRead = false
      readIsPaused = true
      readPauseWaiter?.resume()
      readPauseWaiter = nil
      await withCheckedContinuation { readRelease = $0 }
      readIsPaused = false
    }
    guard let secret = secrets[reference] else { throw ProviderError.missingCredential }
    return secret
  }

  func write(_ secret: Data, for reference: String) throws {
    if rejectNextWrite {
      rejectNextWrite = false
      throw ProviderError.keychain(-50)
    }
    writes.append(reference)
    secrets[reference] = secret
  }

  func remove(_ reference: String) {
    removals.append(reference)
    secrets[reference] = nil
  }

  func secret(for reference: String) -> Data? { secrets[reference] }
  func allSecrets() -> [String: Data] { secrets }
  func writtenReferences() -> [String] { writes }
  func removedReferences() -> [String] { removals }
}

private actor ProviderSaveFailingRepository: WorkspaceRepository {
  private let base: any WorkspaceRepository
  private var rejectNextProviderSave = false

  init(base: any WorkspaceRepository) { self.base = base }
  func failNextProviderSave() { rejectNextProviderSave = true }
  func snapshot() async throws -> WorkspaceSnapshot { try await base.snapshot() }
  func apply(_ mutation: WorkspaceMutation, expectedRevision: Int64?) async throws -> Int64 {
    if case .saveProvider = mutation, rejectNextProviderSave {
      rejectNextProviderSave = false
      throw WorkspaceError.storeUnavailable
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
  func message(id: UUID) async throws -> Message { try await base.message(id: id) }
}

private final class ScriptedProvider: ChatProvider, @unchecked Sendable {
  private let lock = NSLock()
  private var continuations: [AsyncThrowingStream<ChatEvent, Error>.Continuation] = []
  let starts: AsyncStream<Int>
  private let startContinuation: AsyncStream<Int>.Continuation

  init() { (starts, startContinuation) = AsyncStream.makeStream() }
  var callCount: Int { lock.withLock { continuations.count } }

  func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
    AsyncThrowingStream { continuation in
      let index = lock.withLock {
        continuations.append(continuation)
        return continuations.count - 1
      }
      startContinuation.yield(index)
    }
  }

  func send(_ event: ChatEvent, to index: Int, finish: Bool = false) {
    let continuation = lock.withLock { continuations[index] }
    continuation.yield(event)
    if finish { continuation.finish() }
  }
}
