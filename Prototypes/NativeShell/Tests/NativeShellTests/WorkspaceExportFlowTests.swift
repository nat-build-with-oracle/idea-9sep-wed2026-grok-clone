import Foundation
import XCTest

@testable import NativeShell
@testable import WorkspaceCore

@MainActor
final class WorkspaceExportFlowTests: XCTestCase {
  func testCancelledDestinationDoesNotFlushOrWrite() async throws {
    let fixture = try await makeFixture()
    fixture.workspace.draft = "not persisted"
    fixture.workspace.draftSaveTask?.cancel()
    let writes = WriteRecorder()

    let task = try XCTUnwrap(
      fixture.workspace.performWorkspaceExport(
        destination: ImmediateExportDestination(url: nil),
        write: { data, url in await writes.write(data, url) }))
    await task.value

    let storedDrafts = try await fixture.repository.snapshot().drafts
    let writeCount = await writes.count
    XCTAssertTrue(storedDrafts.isEmpty)
    XCTAssertEqual(writeCount, 0)
    XCTAssertNil(fixture.workspace.exportStatus)
    XCTAssertNil(fixture.workspace.exportError)
  }

  func testStartingExportClaimsSingleFlightSynchronously() async throws {
    let fixture = try await makeFixture()
    let chooser = PausedExportDestination()

    let first = fixture.workspace.performWorkspaceExport(destination: chooser)
    let second = fixture.workspace.performWorkspaceExport(destination: chooser)

    XCTAssertNotNil(first)
    XCTAssertNil(second)
    XCTAssertTrue(fixture.workspace.isExporting)
    await chooser.waitUntilChoosing()
    chooser.resume(with: nil)
    await first?.value
  }

  func testSynchronousSelectionCancellationPreventsChooserAndWrite() async throws {
    let fixture = try await makeFixture()
    let chooser = CountingExportDestination()
    let writes = WriteRecorder()

    let task = try XCTUnwrap(
      fixture.workspace.performWorkspaceExport(
        destination: chooser, write: { data, url in await writes.write(data, url) }))
    fixture.workspace.cancelExportSelection?()
    await task.value

    let chooseCount = chooser.chooseCount
    let writeCount = await writes.count
    XCTAssertEqual(chooseCount, 0)
    XCTAssertEqual(writeCount, 0)
  }

  func testPrepareForCloseCancelsPausedChooserWithoutWriting() async throws {
    let fixture = try await makeFixture()
    let chooser = PausedExportDestination()
    let writes = WriteRecorder()
    let export = try XCTUnwrap(
      fixture.workspace.performWorkspaceExport(
        destination: chooser, write: { data, url in await writes.write(data, url) }))
    await chooser.waitUntilChoosing()

    try await fixture.workspace.prepareForClose()
    await export.value

    let writeCount = await writes.count
    XCTAssertEqual(chooser.cancelCount, 1)
    XCTAssertEqual(writeCount, 0)
    XCTAssertNil(fixture.workspace.exportStatus)
    XCTAssertNil(fixture.workspace.exportError)
  }

  func testExportFlushesLatestDraftAndExcludesCredentialReference() async throws {
    let fixture = try await makeFixture()
    let secretReference = "credential-reference-secret-sentinel"
    try await fixture.repository.apply(
      .saveProvider(
        ProviderConfig(
          name: "Fixture", apiRoot: URL(string: "https://fixture.invalid/v1")!,
          modelID: "fixture-model", credentialReference: secretReference)))
    fixture.workspace.draft = "latest unsaved draft"
    fixture.workspace.draftSaveTask?.cancel()
    let writes = WriteRecorder()

    let task = try XCTUnwrap(
      fixture.workspace.performWorkspaceExport(
        destination: ImmediateExportDestination(
          url: fixture.directory.appendingPathComponent("out.json")),
        write: { data, url in await writes.write(data, url) }))
    await task.value

    let recordedData = await writes.onlyData
    let data = try XCTUnwrap(recordedData)
    let document = try JSONDecoder().decode(WorkspaceExportDocument.self, from: data)
    XCTAssertEqual(document.drafts.first?.text, "latest unsaved draft")
    XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(secretReference))
    XCTAssertNotNil(fixture.workspace.exportStatus)
    XCTAssertNil(fixture.workspace.exportError)
  }

  func testDraftSaveFailureDoesNotWriteAndKeepsDraftDirtyForRetry() async throws {
    let base = try await makeFixture()
    let repository = FailingDraftExportRepository(base: base.repository)
    let workspace = PreviewWorkspace(seed: false)
    try await workspace.connect(repository)
    workspace.draft = "retry-secret-sentinel"
    workspace.draftSaveTask?.cancel()
    await repository.failNextDraftSave()
    let writes = WriteRecorder()

    let task = try XCTUnwrap(
      workspace.performWorkspaceExport(
        destination: ImmediateExportDestination(
          url: base.directory.appendingPathComponent("out.json")),
        write: { data, url in await writes.write(data, url) }))
    await task.value

    let writeCount = await writes.count
    XCTAssertEqual(writeCount, 0)
    XCTAssertEqual(workspace.draft, "retry-secret-sentinel")
    XCTAssertEqual(workspace.exportError, WorkspaceExportFlowError.failed.localizedDescription)
    XCTAssertFalse(workspace.exportError?.contains("retry-secret-sentinel") == true)
    XCTAssertNil(workspace.exportStatus)
    try await workspace.flushDrafts()
    let savedDraft = try await base.repository.snapshot().drafts.first
    XCTAssertEqual(savedDraft?.text, "retry-secret-sentinel")
  }

  func testByteLimitFailureDoesNotWriteOrReportSuccess() async throws {
    let fixture = try await makeFixture()
    let writes = WriteRecorder()

    let task = try XCTUnwrap(
      fixture.workspace.performWorkspaceExport(
        destination: ImmediateExportDestination(
          url: fixture.directory.appendingPathComponent("out.json")),
        maxBytes: 1,
        write: { data, url in await writes.write(data, url) }))
    await task.value

    let writeCount = await writes.count
    XCTAssertEqual(writeCount, 0)
    XCTAssertNil(fixture.workspace.exportStatus)
    XCTAssertTrue(fixture.workspace.exportError?.contains("exceeding") == true)
  }

  func testWorkspaceChangeWhileChooserIsPausedDoesNotWrite() async throws {
    let fixture = try await makeFixture()
    let replacement = try await makeFixture()
    let chooser = PausedExportDestination(ignoresCancellation: true)
    let writes = WriteRecorder()
    let task = try XCTUnwrap(
      fixture.workspace.performWorkspaceExport(
        destination: chooser, write: { data, url in await writes.write(data, url) }))
    await chooser.waitUntilChoosing()

    try await fixture.workspace.connect(replacement.repository)
    chooser.resume(with: fixture.directory.appendingPathComponent("out.json"))
    await task.value

    let writeCount = await writes.count
    XCTAssertEqual(writeCount, 0)
    XCTAssertNil(fixture.workspace.exportStatus)
    XCTAssertNil(fixture.workspace.exportError)
  }

  func testWorkspaceChangeWhileSnapshotIsPausedDoesNotWrite() async throws {
    let base = try await makeFixture()
    let repository = PausedExportRepository(base: base.repository)
    let workspace = PreviewWorkspace(seed: false)
    try await workspace.connect(repository)
    let writes = WriteRecorder()
    let task = try XCTUnwrap(
      workspace.performWorkspaceExport(
        destination: ImmediateExportDestination(
          url: base.directory.appendingPathComponent("out.json")),
        write: { data, url in await writes.write(data, url) }))
    await repository.waitUntilExportPaused()

    let replacement = try await makeFixture()
    try await workspace.connect(replacement.repository)
    await repository.resumeExport()
    await task.value

    let writeCount = await writes.count
    XCTAssertEqual(writeCount, 0)
    XCTAssertNil(workspace.exportStatus)
    XCTAssertNil(workspace.exportError)
  }

  func testPrepareForCloseWaitsForAcceptedWrite() async throws {
    let fixture = try await makeFixture()
    let writer = PausedWriter()
    let export = try XCTUnwrap(
      fixture.workspace.performWorkspaceExport(
        destination: ImmediateExportDestination(
          url: fixture.directory.appendingPathComponent("out.json")),
        write: { data, url in try await writer.write(data, url) }))
    await writer.waitUntilWriting()
    let completion = CloseCompletion()
    let close = Task {
      await completion.markStarted()
      try await fixture.workspace.prepareForClose()
      await completion.markFinished()
    }

    await completion.waitUntilStarted()
    await Task.yield()
    let finishedBeforeRelease = await completion.finished
    XCTAssertFalse(finishedBeforeRelease)
    XCTAssertTrue(fixture.workspace.isExporting)
    await writer.resumeSuccessfully()
    try await close.value
    await export.value
    XCTAssertNotNil(fixture.workspace.exportStatus)
  }

  func testConnectWaitsForAcceptedWriteBeforeReplacingWorkspace() async throws {
    let fixture = try await makeFixture()
    let replacement = try await makeFixture()
    let replacementSelection = try XCTUnwrap(replacement.workspace.selectedID)
    let writer = PausedWriter()
    let export = try XCTUnwrap(
      fixture.workspace.performWorkspaceExport(
        destination: ImmediateExportDestination(
          url: fixture.directory.appendingPathComponent("out.json")),
        write: { data, url in try await writer.write(data, url) }))
    await writer.waitUntilWriting()
    let completion = CloseCompletion()
    let connect = Task {
      await completion.markStarted()
      try await fixture.workspace.connect(replacement.repository)
      await completion.markFinished()
    }

    await completion.waitUntilStarted()
    await Task.yield()
    let finishedBeforeRelease = await completion.finished
    XCTAssertFalse(finishedBeforeRelease)
    XCTAssertTrue(fixture.workspace.isExportWriting)
    await writer.resumeSuccessfully()
    try await connect.value
    await export.value
    XCTAssertEqual(fixture.workspace.selectedID, replacementSelection)
    XCTAssertFalse(fixture.workspace.isExportWriting)
  }

  func testFailedAcceptedWritePreventsCloseAndNeverReportsSuccess() async throws {
    let fixture = try await makeFixture()
    let writer = PausedWriter()
    _ = try XCTUnwrap(
      fixture.workspace.performWorkspaceExport(
        destination: ImmediateExportDestination(
          url: fixture.directory.appendingPathComponent("out.json")),
        write: { data, url in try await writer.write(data, url) }))
    await writer.waitUntilWriting()
    let close = Task { try await fixture.workspace.prepareForClose() }
    await writer.resumeThrowing()

    do {
      try await close.value
      XCTFail("A failed accepted export must prevent close")
    } catch {
      guard case WorkspaceExportFlowError.failed = error else {
        return XCTFail("Expected sanitized export failure, got \(type(of: error))")
      }
    }
    XCTAssertNil(fixture.workspace.exportStatus)
    XCTAssertEqual(
      fixture.workspace.exportError, WorkspaceExportFlowError.failed.localizedDescription)
  }

  private func makeFixture() async throws -> ExportFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "WorkspaceExportFlowTests-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let repository = try await CoreDataWorkspaceRepository.open(
      at: directory.appendingPathComponent("workspace.sqlite"))
    addTeardownBlock {
      try await repository.close()
      try? FileManager.default.removeItem(at: directory)
    }
    let workspace = PreviewWorkspace(seed: false)
    try await workspace.connect(repository)
    _ = try await workspace.performCreateBot(
      name: "Export fixture", description: "", color: "green", shape: .circle)
    return ExportFixture(workspace: workspace, repository: repository, directory: directory)
  }
}

private struct ExportFixture {
  let workspace: PreviewWorkspace
  let repository: CoreDataWorkspaceRepository
  let directory: URL
}

@MainActor
private final class ImmediateExportDestination: WorkspaceExportDestinationChoosing {
  let url: URL?
  init(url: URL?) { self.url = url }
  func choose() async -> URL? { url }
  func cancel() {}
}

@MainActor
private final class CountingExportDestination: WorkspaceExportDestinationChoosing {
  private(set) var chooseCount = 0
  func choose() async -> URL? {
    chooseCount += 1
    return nil
  }
  func cancel() {}
}

@MainActor
private final class PausedExportDestination: WorkspaceExportDestinationChoosing {
  private let ignoresCancellation: Bool
  private var choiceContinuation: CheckedContinuation<URL?, Never>?
  private var waiter: CheckedContinuation<Void, Never>?
  private var isChoosing = false
  private(set) var cancelCount = 0

  init(ignoresCancellation: Bool = false) { self.ignoresCancellation = ignoresCancellation }

  func choose() async -> URL? {
    isChoosing = true
    waiter?.resume()
    waiter = nil
    return await withCheckedContinuation { choiceContinuation = $0 }
  }

  func waitUntilChoosing() async {
    if isChoosing { return }
    await withCheckedContinuation { waiter = $0 }
  }

  func resume(with url: URL?) {
    choiceContinuation?.resume(returning: url)
    choiceContinuation = nil
  }

  func cancel() {
    cancelCount += 1
    if !ignoresCancellation { resume(with: nil) }
  }
}

private actor WriteRecorder {
  private(set) var values: [(Data, URL)] = []
  var count: Int { values.count }
  var onlyData: Data? { values.count == 1 ? values[0].0 : nil }
  func write(_ data: Data, _ url: URL) { values.append((data, url)) }
}

private enum ExportTestFailure: Error { case injected }

private actor CloseCompletion {
  private var startWaiter: CheckedContinuation<Void, Never>?
  private(set) var started = false
  private(set) var finished = false

  func markStarted() {
    started = true
    startWaiter?.resume()
    startWaiter = nil
  }

  func waitUntilStarted() async {
    if started { return }
    await withCheckedContinuation { startWaiter = $0 }
  }

  func markFinished() { finished = true }
}

private actor PausedWriter {
  private var continuation: CheckedContinuation<Void, Error>?
  private var waiter: CheckedContinuation<Void, Never>?
  private var writing = false

  func write(_ data: Data, _ url: URL) async throws {
    writing = true
    waiter?.resume()
    waiter = nil
    try await withCheckedThrowingContinuation { continuation = $0 }
  }

  func waitUntilWriting() async {
    if writing { return }
    await withCheckedContinuation { waiter = $0 }
  }

  func resumeSuccessfully() {
    continuation?.resume()
    continuation = nil
  }

  func resumeThrowing() {
    continuation?.resume(throwing: ExportTestFailure.injected)
    continuation = nil
  }
}

private actor FailingDraftExportRepository: WorkspaceRepository {
  let base: any WorkspaceRepository
  private var rejectNextDraft = false
  init(base: any WorkspaceRepository) { self.base = base }
  func failNextDraftSave() { rejectNextDraft = true }
  func snapshot() async throws -> WorkspaceSnapshot { try await base.snapshot() }
  func exportSnapshot() async throws -> WorkspaceExportDocument { try await base.exportSnapshot() }
  func apply(_ mutation: WorkspaceMutation, expectedRevision: Int64?) async throws -> Int64 {
    if case .saveDraft = mutation, rejectNextDraft {
      rejectNextDraft = false
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

private actor PausedExportRepository: WorkspaceRepository {
  let base: any WorkspaceRepository
  private var exportContinuation: CheckedContinuation<Void, Never>?
  private var waiter: CheckedContinuation<Void, Never>?
  private var paused = false
  init(base: any WorkspaceRepository) { self.base = base }
  func waitUntilExportPaused() async {
    if paused { return }
    await withCheckedContinuation { waiter = $0 }
  }
  func resumeExport() {
    exportContinuation?.resume()
    exportContinuation = nil
  }
  func snapshot() async throws -> WorkspaceSnapshot { try await base.snapshot() }
  func exportSnapshot() async throws -> WorkspaceExportDocument {
    let document = try await base.exportSnapshot()
    paused = true
    waiter?.resume()
    waiter = nil
    await withCheckedContinuation { exportContinuation = $0 }
    return document
  }
  func apply(_ mutation: WorkspaceMutation, expectedRevision: Int64?) async throws -> Int64 {
    try await base.apply(mutation, expectedRevision: expectedRevision)
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
