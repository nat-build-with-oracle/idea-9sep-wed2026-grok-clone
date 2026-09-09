import Foundation
import XCTest

@testable import NativeShell
@testable import WorkspaceCore

@MainActor
final class CodexProviderSettingsTests: XCTestCase {
  func testSelectedAuthFileIsReadOnceWithinLimitAndNeverModified() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("selected-login.json")
    let source = authFixture(refreshToken: "fixture-refresh-must-not-survive")
    try source.write(to: url, options: .atomic)
    let before = try Data(contentsOf: url)

    let credential = try CodexAuthFileImporter.readCredential(from: url)
    let after = try Data(contentsOf: url)
    let envelope = String(decoding: try credential.sessionData(), as: UTF8.self)

    XCTAssertEqual(after, before)
    XCTAssertEqual(String(describing: credential), "CodexSessionCredential(redacted)")
    XCTAssertFalse(envelope.contains("fixture-refresh-must-not-survive"))
    XCTAssertFalse(envelope.contains("auth_mode"))
    XCTAssertFalse(envelope.contains(url.path))
  }

  func testSelectedAuthFileOverLimitFailsClosed() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("oversized.json")
    try Data(repeating: 65, count: CodexSessionCredential.maximumFileBytes + 1).write(to: url)

    XCTAssertThrowsError(try CodexAuthFileImporter.readCredential(from: url)) { error in
      XCTAssertEqual(error as? ProviderError, .invalidCodexLogin)
    }
  }

  func testSaveCodexUsesFixedRootAndMemoryOnlyCredentialNamespace() async throws {
    let (repository, directory) = try await openRepository()
    defer { try? FileManager.default.removeItem(at: directory) }
    let persistent = CodexRecordingCredentialStore()
    let credentials = SessionAwareCredentialStore(persistent: persistent)
    let workspace = PreviewWorkspace(seed: false)
    try await workspace.connect(repository, credentials: credentials, provider: NoCallProvider())
    let credential = try CodexSessionCredential(authFileData: authFixture())

    let id = try await workspace.saveProvider(
      id: nil, name: "  Codex account  ", apiRoot: CodexResponsesProvider.apiRoot.absoluteString,
      modelID: "gpt-5.6-luna", secret: "", allowsLoopbackHTTP: false,
      credentialLifetime: .keychain, kind: .codexResponses, codexCredential: credential)

    let savedProviders = try await repository.snapshot().providers
    let saved = try XCTUnwrap(savedProviders.first)
    XCTAssertEqual(saved.id, id)
    XCTAssertEqual(saved.name, "Codex account")
    XCTAssertEqual(saved.kind, .codexResponses)
    XCTAssertEqual(saved.apiRoot, CodexResponsesProvider.apiRoot)
    XCTAssertFalse(saved.allowsLoopbackHTTP)
    XCTAssertTrue(CodexSessionCredential.isReference(saved.credentialReference))
    XCTAssertEqual(CredentialLifetime.forReference(saved.credentialReference), .session)
    let persistentWrites = await persistent.writtenReferences()
    XCTAssertTrue(persistentWrites.isEmpty)
    let metadata = String(decoding: try JSONEncoder().encode(saved), as: UTF8.self)
    XCTAssertFalse(metadata.contains("fixture-access-token"))
    XCTAssertFalse(metadata.contains("fixture-refresh-token"))
    try await repository.close()
  }

  func testCodexSessionExpiresAcrossCredentialStoreReconnectBeforeDraftConsumption() async throws {
    let (repository, directory) = try await openRepository()
    defer { try? FileManager.default.removeItem(at: directory) }
    let persistent = CodexRecordingCredentialStore()
    let workspace = PreviewWorkspace(seed: false)
    try await workspace.connect(
      repository, credentials: SessionAwareCredentialStore(persistent: persistent),
      provider: NoCallProvider())
    _ = try await workspace.saveProvider(
      id: nil, name: "Codex", apiRoot: CodexResponsesProvider.apiRoot.absoluteString,
      modelID: "gpt-5.6-luna", secret: "", allowsLoopbackHTTP: false,
      kind: .codexResponses,
      codexCredential: try CodexSessionCredential(authFileData: authFixture()))
    _ = try await workspace.performCreateBot(
      name: "Helper", description: "", color: "green", shape: .circle)

    try await workspace.connect(
      repository, credentials: SessionAwareCredentialStore(persistent: persistent),
      provider: NoCallProvider())
    workspace.draft = "Keep this after restart"
    workspace.draftSaveTask?.cancel()
    do {
      _ = try await workspace.submitDraft()
      XCTFail("A restarted session must require an explicit Codex re-import")
    } catch {
      XCTAssertEqual(error as? ProviderError, .codexLoginRequired)
    }

    XCTAssertEqual(workspace.draft, "Keep this after restart")
    let generations = try await repository.snapshot().generations
    XCTAssertTrue(generations.isEmpty)
    XCTAssertEqual(NoCallProvider.callCount, 0)
    try await repository.close()
  }

  func testCodexPartialReplyCanStopAndRetryWithoutDuplicatingUserMessage() async throws {
    let (repository, directory) = try await openRepository()
    defer { try? FileManager.default.removeItem(at: directory) }
    let provider = CodexScriptedProvider()
    let workspace = PreviewWorkspace(seed: false)
    try await workspace.connect(
      repository,
      credentials: SessionAwareCredentialStore(persistent: CodexRecordingCredentialStore()),
      provider: provider)
    _ = try await workspace.saveProvider(
      id: nil, name: "Codex", apiRoot: CodexResponsesProvider.apiRoot.absoluteString,
      modelID: "gpt-5.6-luna", secret: "", allowsLoopbackHTTP: false,
      kind: .codexResponses,
      codexCredential: try CodexSessionCredential(authFileData: authFixture()))
    let botID = try await workspace.performCreateBot(
      name: "Research Partner", description: "Answer carefully", color: "green", shape: .circle)
    let conversationID = try XCTUnwrap(workspace.selectedID)
    workspace.draft = "Original Codex question"
    workspace.draftSaveTask?.cancel()
    var starts = provider.starts.makeAsyncIterator()

    let generationID = try await workspace.submitDraft()
    let firstStart = await starts.next()
    XCTAssertEqual(firstStart, 0)
    provider.send(.text("Partial Codex answer"), to: 0)
    try await waitUntil {
      try await repository.messages(conversationID: conversationID).messages.last?.text
        == "Partial Codex answer"
    }
    let startedGenerations = try await repository.snapshot().generations
    let originalAttempt = try XCTUnwrap(
      startedGenerations.first(where: { $0.id == generationID })?.attemptID)

    try await workspace.cancelReply(generationID)
    let cancelledGenerations = try await repository.snapshot().generations
    let cancelled = try XCTUnwrap(
      cancelledGenerations.first(where: { $0.id == generationID }))
    XCTAssertEqual(cancelled.state, .cancelled)

    try await workspace.retryReply(generationID)
    let retryStart = await starts.next()
    XCTAssertEqual(retryStart, 1)
    provider.send(.text("Complete Codex answer"), to: 1)
    provider.send(.finished, to: 1, finish: true)
    await workspace.coordinator?.waitForIdle()

    let page = try await repository.messages(conversationID: conversationID)
    let completedGenerations = try await repository.snapshot().generations
    let completed = try XCTUnwrap(
      completedGenerations.first(where: { $0.id == generationID }))
    XCTAssertEqual(
      page.messages.filter { $0.role == .user }.map(\.text), ["Original Codex question"])
    XCTAssertEqual(
      page.messages.filter { $0.role == .assistant }.map(\.text),
      ["Partial Codex answer", "Complete Codex answer"])
    XCTAssertEqual(page.messages.filter { $0.role == .event }.count, 1)
    XCTAssertTrue(
      page.messages.filter { $0.role == .assistant }.allSatisfy {
        $0.speakerBotID == botID && $0.speakerNameSnapshot == "Research Partner"
      })
    XCTAssertEqual(completed.state, .completed)
    XCTAssertNotEqual(completed.attemptID, originalAttempt)
    XCTAssertEqual(provider.callCount, 2)
    try await repository.close()
  }

  func testFailedCodexMetadataReplacementRemovesNewSessionEnvelopeAndPreservesOld() async throws {
    let (base, directory) = try await openRepository()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = CodexProviderSaveFailingRepository(base: base)
    let credentials = CodexRecordingCredentialStore()
    let workspace = PreviewWorkspace(seed: false)
    try await workspace.connect(repository, credentials: credentials, provider: NoCallProvider())
    let id = try await workspace.saveProvider(
      id: nil, name: "Original Codex", apiRoot: CodexResponsesProvider.apiRoot.absoluteString,
      modelID: "gpt-5.6-luna", secret: "", allowsLoopbackHTTP: false,
      kind: .codexResponses,
      codexCredential: try CodexSessionCredential(authFileData: authFixture()))
    let originalProviders = try await base.snapshot().providers
    let original = try XCTUnwrap(originalProviders.first)
    let storedOriginalEnvelope = await credentials.secret(for: original.credentialReference)
    let originalEnvelope = try XCTUnwrap(storedOriginalEnvelope)
    await repository.failNextProviderSave()

    do {
      _ = try await workspace.saveProvider(
        id: id, name: "Replacement Codex", apiRoot: CodexResponsesProvider.apiRoot.absoluteString,
        modelID: "gpt-5.6-luna", secret: "", allowsLoopbackHTTP: false,
        kind: .codexResponses,
        codexCredential: try CodexSessionCredential(
          authFileData: Data(
            "{\"auth_mode\":\"chatgpt\",\"tokens\":{\"access_token\":\"replacement-access\"}}".utf8)
        ))
      XCTFail("Expected metadata persistence failure")
    } catch {
      XCTAssertEqual(error as? WorkspaceError, .storeUnavailable)
    }

    let savedProviders = try await base.snapshot().providers
    let retainedEnvelope = await credentials.secret(for: original.credentialReference)
    let writes = await credentials.writtenReferences()
    let removals = await credentials.removedReferences()
    XCTAssertEqual(savedProviders, [original])
    XCTAssertEqual(retainedEnvelope, originalEnvelope)
    XCTAssertEqual(writes.count, 2)
    XCTAssertEqual(removals.count, 1)
    XCTAssertEqual(removals.first, writes.last)
    XCTAssertNotEqual(removals.first, writes.first)
    try await base.close()
  }

  func testKindSwitchRequiresFreshMatchingCredentialAndNeverCopiesGenericKey() async throws {
    let (repository, directory) = try await openRepository()
    defer { try? FileManager.default.removeItem(at: directory) }
    let persistent = CodexRecordingCredentialStore()
    let credentials = SessionAwareCredentialStore(persistent: persistent)
    let workspace = PreviewWorkspace(seed: false)
    try await workspace.connect(repository, credentials: credentials, provider: NoCallProvider())
    let id = try await workspace.saveProvider(
      id: nil, name: "Generic", apiRoot: "https://fixture.invalid/v1", modelID: "model",
      secret: "generic-fixture-key", allowsLoopbackHTTP: false)
    let genericProviders = try await repository.snapshot().providers
    let generic = try XCTUnwrap(genericProviders.first)

    do {
      _ = try await workspace.saveProvider(
        id: id, name: "Codex", apiRoot: CodexResponsesProvider.apiRoot.absoluteString,
        modelID: "gpt-5.6-luna", secret: "", allowsLoopbackHTTP: false,
        kind: .codexResponses)
      XCTFail("Switching kinds must require a fresh matching credential")
    } catch {
      guard case ProviderSetupError.changedProviderKind = error else {
        return XCTFail("Unexpected error: \(type(of: error))")
      }
    }
    let providersAfterRejectedSwitch = try await repository.snapshot().providers
    let genericSecret = await persistent.secret(for: generic.credentialReference)
    XCTAssertEqual(providersAfterRejectedSwitch, [generic])
    XCTAssertEqual(genericSecret, Data("generic-fixture-key".utf8))

    _ = try await workspace.saveProvider(
      id: id, name: "Codex", apiRoot: CodexResponsesProvider.apiRoot.absoluteString,
      modelID: "gpt-5.6-luna", secret: "", allowsLoopbackHTTP: false, kind: .codexResponses,
      codexCredential: try CodexSessionCredential(authFileData: authFixture()))
    let codexProviders = try await repository.snapshot().providers
    let codex = try XCTUnwrap(codexProviders.first)
    XCTAssertEqual(codex.apiRoot, CodexResponsesProvider.apiRoot)
    XCTAssertNotEqual(codex.credentialReference, generic.credentialReference)
    let removedGenericSecret = await persistent.secret(for: generic.credentialReference)
    XCTAssertNil(removedGenericSecret)

    do {
      _ = try await workspace.saveProvider(
        id: id, name: "Generic again", apiRoot: "https://fixture.invalid/v1", modelID: "model",
        secret: "", allowsLoopbackHTTP: false, kind: .chatCompletions)
      XCTFail("A Codex session credential must never be copied to a generic endpoint")
    } catch {
      guard case ProviderSetupError.changedProviderKind = error else {
        return XCTFail("Unexpected error: \(type(of: error))")
      }
    }
    let providersAfterRejectedReturn = try await repository.snapshot().providers
    XCTAssertEqual(providersAfterRejectedReturn, [codex])
    try await repository.close()
  }

  func testGenericProviderRejectsCodexCredentialWithoutWritingAnything() async throws {
    let (repository, directory) = try await openRepository()
    defer { try? FileManager.default.removeItem(at: directory) }
    let persistent = CodexRecordingCredentialStore()
    let workspace = PreviewWorkspace(seed: false)
    try await workspace.connect(repository, credentials: persistent, provider: NoCallProvider())

    do {
      _ = try await workspace.saveProvider(
        id: nil, name: "Wrong type", apiRoot: "https://fixture.invalid/v1", modelID: "model",
        secret: "", allowsLoopbackHTTP: false, kind: .chatCompletions,
        codexCredential: try CodexSessionCredential(authFileData: authFixture()))
      XCTFail("Codex login material must not enter the generic provider path")
    } catch {
      guard case ProviderSetupError.unexpectedCredential = error else {
        return XCTFail("Unexpected error: \(type(of: error))")
      }
    }

    let savedProviders = try await repository.snapshot().providers
    let writes = await persistent.writtenReferences()
    XCTAssertTrue(savedProviders.isEmpty)
    XCTAssertTrue(writes.isEmpty)
    try await repository.close()
  }

  func testCodexSaveRejectsDestinationMutationWithoutWritingCredential() async throws {
    let (repository, directory) = try await openRepository()
    defer { try? FileManager.default.removeItem(at: directory) }
    let persistent = CodexRecordingCredentialStore()
    let credentials = SessionAwareCredentialStore(persistent: persistent)
    let workspace = PreviewWorkspace(seed: false)
    try await workspace.connect(repository, credentials: credentials, provider: NoCallProvider())
    let credential = try CodexSessionCredential(authFileData: authFixture())

    for (root, loopback) in [
      ("https://elsewhere.invalid/codex", false),
      (CodexResponsesProvider.apiRoot.absoluteString, true),
    ] {
      do {
        _ = try await workspace.saveProvider(
          id: nil, name: "Mutated", apiRoot: root, modelID: "gpt-5.6-luna", secret: "",
          allowsLoopbackHTTP: loopback, kind: .codexResponses, codexCredential: credential)
        XCTFail("Codex settings must reject destination or HTTP mutations")
      } catch {
        XCTAssertEqual(error as? WorkspaceError, .invalidProvider)
      }
    }

    let savedProviders = try await repository.snapshot().providers
    let persistentWrites = await persistent.writtenReferences()
    XCTAssertTrue(savedProviders.isEmpty)
    XCTAssertTrue(persistentWrites.isEmpty)
    try await repository.close()
  }

  private func authFixture(refreshToken: String = "fixture-refresh-token") -> Data {
    Data(
      """
      {"auth_mode":"chatgpt","tokens":{"access_token":"fixture-access-token","account_id":"fixture-account","refresh_token":"\(refreshToken)"}}
      """.utf8)
  }

  private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "CodexProviderSettingsTests-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func openRepository() async throws -> (CoreDataWorkspaceRepository, URL) {
    let directory = try makeTemporaryDirectory()
    let repository = try await CoreDataWorkspaceRepository.open(
      at: directory.appendingPathComponent("workspace.sqlite"))
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
    throw CodexSettingsTestError.timedOut
  }
}

private enum CodexSettingsTestError: Error { case timedOut }

private actor CodexRecordingCredentialStore: CredentialStore {
  private var secrets: [String: Data] = [:]
  private var writes: [String] = []
  private var removals: [String] = []

  func read(_ reference: String) async throws -> Data {
    guard let value = secrets[reference] else { throw ProviderError.missingCredential }
    return value
  }

  func write(_ secret: Data, for reference: String) async throws {
    writes.append(reference)
    secrets[reference] = secret
  }

  func remove(_ reference: String) async throws {
    removals.append(reference)
    secrets[reference] = nil
  }
  func secret(for reference: String) -> Data? { secrets[reference] }
  func writtenReferences() -> [String] { writes }
  func removedReferences() -> [String] { removals }
}

private actor CodexProviderSaveFailingRepository: WorkspaceRepository {
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

private final class CodexScriptedProvider: ChatProvider, @unchecked Sendable {
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

private struct NoCallProvider: ChatProvider {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var calls = 0
  static var callCount: Int { lock.withLock { calls } }

  func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
    Self.lock.withLock { Self.calls += 1 }
    return AsyncThrowingStream { $0.finish(throwing: ProviderError.invalidResponse) }
  }
}
