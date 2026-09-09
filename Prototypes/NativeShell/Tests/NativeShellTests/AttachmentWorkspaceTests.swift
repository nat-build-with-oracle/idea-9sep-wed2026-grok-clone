import Foundation
import WorkspaceCore
import XCTest

@testable import NativeShell

@MainActor
final class AttachmentWorkspaceTests: XCTestCase {
  func testChooserCancellationReadsAndSavesNothing() async throws {
    let fixture = try await makeFixture()
    let reader = AttachmentReaderProbe()
    let chooser = AttachmentTestChooser(result: nil)

    let task = try XCTUnwrap(
      fixture.workspace.performAttachmentImport(chooser: chooser, read: reader.read))
    await task.value

    XCTAssertEqual(chooser.chooseCount, 1)
    let readCount = await reader.currentCallCount()
    let snapshot = try await fixture.repository.snapshot()
    XCTAssertEqual(readCount, 0)
    XCTAssertTrue(fixture.workspace.currentDraftAttachmentIDs.isEmpty)
    XCTAssertTrue(snapshot.drafts.isEmpty)
    try await close(fixture)
  }

  func testAttachmentChooserIsClaimedSynchronouslyAndFinishCancelsUnacceptedChoice() async throws {
    let fixture = try await makeFixture()
    let chooser = AttachmentTestChooser(waitForCancellation: true)

    let first = try XCTUnwrap(fixture.workspace.performAttachmentImport(chooser: chooser))
    XCTAssertFalse(fixture.workspace.canChooseAttachments)
    XCTAssertNil(
      fixture.workspace.performAttachmentImport(chooser: AttachmentTestChooser(result: [])))

    try await fixture.workspace.finishAttachmentImport()
    await first.value
    XCTAssertEqual(chooser.cancelCount, 1)
    XCTAssertTrue(fixture.workspace.currentDraftAttachmentIDs.isEmpty)
    try await close(fixture)
  }

  func testMultipleFilesAreCopiedExactlyIntoConversationSelectedBeforeNavigation() async throws {
    let fixture = try await makeFixture()
    let originalConversation = fixture.conversationID
    let first = try AttachmentContent(
      conversationID: originalConversation, originalName: "first.txt", data: Data("alpha".utf8))
    let second = try AttachmentContent(
      conversationID: originalConversation, originalName: "second.md", data: Data("beta 🧪".utf8))
    let reader = AttachmentReaderProbe(result: [first, second], suspend: true)
    let chooser = AttachmentTestChooser(
      result: [
        URL(fileURLWithPath: "/synthetic/first.txt"), URL(fileURLWithPath: "/synthetic/second.md"),
      ])

    let task = try XCTUnwrap(
      fixture.workspace.performAttachmentImport(chooser: chooser, read: reader.read))
    await reader.waitUntilCalled()
    let otherBot = try await fixture.workspace.performCreateBot(
      name: "Other", description: "", color: "blue", shape: .square)
    let otherConversation = try XCTUnwrap(fixture.workspace.selectedID)
    XCTAssertNotEqual(otherBot, fixture.botID)
    await reader.resume()
    await task.value

    let snapshot = try await fixture.repository.snapshot()
    let storedDraft = try XCTUnwrap(
      snapshot.drafts.first { $0.conversationID == originalConversation })
    let storedFirst = try await fixture.repository.attachmentContent(id: first.attachment.id)
    let storedSecond = try await fixture.repository.attachmentContent(id: second.attachment.id)
    XCTAssertEqual(storedDraft.attachmentIDs, [first.attachment.id, second.attachment.id])
    XCTAssertEqual(storedFirst, first)
    XCTAssertEqual(storedSecond, second)
    XCTAssertTrue(
      snapshot.drafts.first {
        $0.conversationID == otherConversation
      }?.attachmentIDs.isEmpty ?? true)
    try await close(fixture)
  }

  func testReadFailureLeavesDraftAndManagedStoreUnchanged() async throws {
    let fixture = try await makeFixture()
    fixture.workspace.draft = "existing text"
    try await fixture.workspace.flushDrafts()
    let before = try await fixture.repository.snapshot().drafts
    let chooser = AttachmentTestChooser(result: [URL(fileURLWithPath: "/synthetic/bad.txt")])

    let task = try XCTUnwrap(
      fixture.workspace.performAttachmentImport(chooser: chooser) { _, _ in
        throw AttachmentWorkflowTestError.syntheticRead
      })
    await task.value

    XCTAssertEqual(fixture.workspace.draft, "existing text")
    XCTAssertTrue(fixture.workspace.currentDraftAttachmentIDs.isEmpty)
    XCTAssertTrue(fixture.workspace.pendingAttachmentPayloads.isEmpty)
    let after = try await fixture.repository.snapshot().drafts
    XCTAssertEqual(after, before)
    try await close(fixture)
  }

  func testCountLimitRejectsWholeBatchWithoutChangingExistingReferences() async throws {
    let fixture = try await makeFixture(connect: false)
    let existing = try (0..<AttachmentLimits.maxCount).map { index in
      try AttachmentContent(
        conversationID: fixture.conversationID, originalName: "existing-\(index).txt", data: Data())
    }
    try await fixture.repository.apply(
      .saveDraftWithAttachments(
        Draft(
          conversationID: fixture.conversationID, text: "kept",
          attachmentIDs: existing.map(\.attachment.id)),
        attachments: existing))
    try await fixture.workspace.connect(fixture.repository, displayName: "Attachment tests")
    let extra = try AttachmentContent(
      conversationID: fixture.conversationID, originalName: "extra.txt", data: Data("x".utf8))

    let task = try XCTUnwrap(
      fixture.workspace.performAttachmentImport(
        chooser: AttachmentTestChooser(result: [URL(fileURLWithPath: "/synthetic/extra.txt")])
      ) { _, _ in [extra] })
    await task.value

    XCTAssertEqual(fixture.workspace.currentDraftAttachmentIDs, existing.map(\.attachment.id))
    XCTAssertTrue(fixture.workspace.pendingAttachmentPayloads.isEmpty)
    await assertThrowsAttachment(.missingAttachment) {
      _ = try await fixture.repository.attachmentContent(id: extra.attachment.id)
    }
    try await close(fixture)
  }

  func testTextEditDuringAttachmentSaveIsPersistedBySoleVersionedWriter() async throws {
    let fixture = try await makeFixture(connect: false)
    let paused = PauseAttachmentSaveRepository(base: fixture.repository)
    try await fixture.workspace.connect(paused, displayName: "Attachment tests")
    fixture.workspace.draft = "before"
    try await fixture.workspace.flushDrafts()
    let content = try AttachmentContent(
      conversationID: fixture.conversationID, originalName: "gated.txt", data: Data("bytes".utf8))
    let task = try XCTUnwrap(
      fixture.workspace.performAttachmentImport(
        chooser: AttachmentTestChooser(result: [URL(fileURLWithPath: "/synthetic/gated.txt")])
      ) { _, _ in [content] })

    await paused.waitUntilPaused()
    fixture.workspace.draft = "newer text"
    fixture.workspace.draftSaveTask?.cancel()
    await paused.resume()
    await task.value

    let snapshot = try await fixture.repository.snapshot()
    let saved = try XCTUnwrap(snapshot.drafts.first { $0.conversationID == fixture.conversationID })
    XCTAssertEqual(saved.text, "newer text")
    XCTAssertEqual(saved.attachmentIDs, [content.attachment.id])
    XCTAssertTrue(fixture.workspace.pendingAttachmentPayloads.isEmpty)
    try await close(fixture)
  }

  func testAcknowledgedAttachmentImportStaysSuccessfulWhenLaterUnrelatedDraftSaveFails()
    async throws
  {
    let fixture = try await makeFixture(connect: false)
    let otherBot = Bot(name: "Other")
    let otherConversationID = UUID()
    try await fixture.repository.apply(
      .createBot(otherBot, conversationID: otherConversationID))
    let repository = PauseAttachmentThenFailDraftRepository(
      base: fixture.repository, failingConversationID: otherConversationID)
    try await fixture.workspace.connect(repository, displayName: "Attachment tests")
    fixture.workspace.selectedID = fixture.conversationID
    let content = try AttachmentContent(
      conversationID: fixture.conversationID, originalName: "acknowledged.txt",
      data: Data("one managed copy".utf8))
    let importTask = try XCTUnwrap(
      fixture.workspace.performAttachmentImport(
        chooser: AttachmentTestChooser(
          result: [URL(fileURLWithPath: "/synthetic/acknowledged.txt")])
      ) { _, _ in [content] })

    await repository.waitUntilAttachmentSaveIsPaused()
    fixture.workspace.drafts[otherConversationID] = "must remain dirty"
    fixture.workspace.scheduleDraftSave(otherConversationID)
    fixture.workspace.draftSaveTask?.cancel()
    await repository.resumeAttachmentSave()
    await importTask.value

    let attachmentSaveCount = await repository.attachmentSaveCount()
    let stored = try await fixture.repository.attachmentContent(id: content.attachment.id)
    let snapshot = try await fixture.repository.snapshot()
    XCTAssertEqual(attachmentSaveCount, 1)
    XCTAssertEqual(stored, content)
    XCTAssertEqual(
      snapshot.drafts.first { $0.conversationID == fixture.conversationID }?.attachmentIDs,
      [content.attachment.id])
    XCTAssertEqual(
      fixture.workspace.draftAttachmentIDs[fixture.conversationID], [content.attachment.id])
    XCTAssertNil(fixture.workspace.attachmentImportFailure)
    XCTAssertTrue(fixture.workspace.notice?.contains("Copied 1 text files") == true)
    XCTAssertEqual(
      fixture.workspace.storageError, WorkspaceError.storeUnavailable.localizedDescription)
    XCTAssertTrue(fixture.workspace.dirtyDrafts.contains(otherConversationID))

    await repository.allowOtherDraftSave()
    try await fixture.workspace.flushDrafts()
    try await close(fixture)
  }

  func testFailedAttachmentTransactionRollsBackBatchAndLeavesNoGhostPayload() async throws {
    let fixture = try await makeFixture(connect: false)
    let failing = FailAttachmentSaveRepository(base: fixture.repository)
    try await fixture.workspace.connect(failing, displayName: "Attachment tests")
    fixture.workspace.draft = "old text"
    try await fixture.workspace.flushDrafts()
    await failing.failNextAttachmentSave()
    let content = try AttachmentContent(
      conversationID: fixture.conversationID, originalName: "rejected.txt",
      data: Data("no ghost".utf8))

    let task = try XCTUnwrap(
      fixture.workspace.performAttachmentImport(
        chooser: AttachmentTestChooser(result: [URL(fileURLWithPath: "/synthetic/rejected.txt")])
      ) { _, _ in [content] })
    await task.value

    XCTAssertEqual(fixture.workspace.draft, "old text")
    XCTAssertTrue(fixture.workspace.currentDraftAttachmentIDs.isEmpty)
    XCTAssertNil(fixture.workspace.pendingAttachmentPayloads[content.attachment.id])
    XCTAssertNil(fixture.workspace.attachmentMetadata[content.attachment.id])
    await assertThrowsAttachment(.missingAttachment) {
      _ = try await fixture.repository.attachmentContent(id: content.attachment.id)
    }
    try await close(fixture)
  }

  func testRemovingDraftReferencesCollectsUnsharedBytesButRetainsMessageSharedBytesAfterReopen()
    async throws
  {
    let fixture = try await makeFixture(connect: false)
    let draftOnly = try AttachmentContent(
      conversationID: fixture.conversationID, originalName: "draft.txt", data: Data("draft".utf8))
    let shared = try AttachmentContent(
      conversationID: fixture.conversationID, originalName: "shared.txt", data: Data("shared".utf8))
    try await fixture.repository.apply(
      .saveDraftWithAttachments(
        Draft(
          conversationID: fixture.conversationID, text: "send",
          attachmentIDs: [shared.attachment.id]),
        attachments: [shared]))
    try await fixture.repository.apply(
      .beginGeneration(
        SendCommand(
          conversationID: fixture.conversationID, targetBotID: fixture.botID, text: "send",
          attachmentIDs: [shared.attachment.id])))
    try await fixture.repository.apply(
      .saveDraftWithAttachments(
        Draft(
          conversationID: fixture.conversationID, text: "new",
          attachmentIDs: [draftOnly.attachment.id, shared.attachment.id]),
        attachments: [draftOnly]))
    try await fixture.workspace.connect(fixture.repository, displayName: "Attachment tests")

    fixture.workspace.removeDraftAttachment(draftOnly.attachment.id, in: fixture.conversationID)
    fixture.workspace.removeDraftAttachment(shared.attachment.id, in: fixture.conversationID)
    try await fixture.workspace.flushDrafts()
    await fixture.workspace.shutdownRoutines()
    try await fixture.workspace.coordinator?.shutdown()
    try await fixture.repository.close()
    let reopened = try await CoreDataWorkspaceRepository.open(at: fixture.storeURL)

    await assertThrowsAttachment(.missingAttachment) {
      _ = try await reopened.attachmentContent(id: draftOnly.attachment.id)
    }
    let reopenedShared = try await reopened.attachmentContent(id: shared.attachment.id)
    XCTAssertEqual(reopenedShared, shared)
    try await reopened.close()
    cleanup(fixture.directory)
  }

  func testMetadataStoreFailureIsVisibleWithoutMisclassifyingAttachmentsAsUnavailable() async throws
  {
    let fixture = try await makeFixture(connect: false)
    let contents = try metadataContents(for: fixture.conversationID)
    try await fixture.repository.apply(
      .saveDraftWithAttachments(
        Draft(
          conversationID: fixture.conversationID, text: "metadata",
          attachmentIDs: contents.map(\.attachment.id)),
        attachments: contents))
    let repository = MetadataBehaviorRepository(base: fixture.repository, storeFailure: true)

    try await fixture.workspace.connect(repository, displayName: "Attachment tests")

    let readCount = await repository.metadataReadCount()
    XCTAssertEqual(readCount, 1)
    XCTAssertEqual(
      fixture.workspace.storageError, WorkspaceError.storeUnavailable.localizedDescription)
    XCTAssertTrue(fixture.workspace.unavailableAttachmentIDs.isEmpty)
    XCTAssertTrue(fixture.workspace.attachmentMetadata.isEmpty)
    try await close(fixture)
  }

  func testMissingMetadataFallsBackIndividuallyAndMarksOnlyMissingAttachment() async throws {
    let fixture = try await makeFixture(connect: false)
    let contents = try metadataContents(for: fixture.conversationID)
    try await fixture.repository.apply(
      .saveDraftWithAttachments(
        Draft(
          conversationID: fixture.conversationID, text: "metadata",
          attachmentIDs: contents.map(\.attachment.id)),
        attachments: contents))
    let missingID = contents[1].attachment.id
    let repository = MetadataBehaviorRepository(base: fixture.repository, missingID: missingID)

    try await fixture.workspace.connect(repository, displayName: "Attachment tests")

    let readCount = await repository.metadataReadCount()
    XCTAssertEqual(readCount, 3)
    XCTAssertEqual(fixture.workspace.unavailableAttachmentIDs, [missingID])
    XCTAssertEqual(
      fixture.workspace.attachmentMetadata[contents[0].attachment.id], contents[0].attachment)
    XCTAssertNil(fixture.workspace.attachmentMetadata[missingID])
    XCTAssertNil(fixture.workspace.storageError)
    try await close(fixture)
  }

  func testAttachmentConfirmationCancelHasNoCredentialOrProviderEffect() async throws {
    let credentials = AttachmentWorkflowCredentialSpy()
    let provider = AttachmentWorkflowProvider()
    let fixture = try await makeFixture(
      credentials: credentials, provider: provider, withProvider: true)
    let content = try await importOne(into: fixture, bytes: "private fixture")

    fixture.workspace.performSend()
    try await waitUntil { fixture.workspace.attachmentConfirmationTarget != nil }
    let readsBeforeCancel = await credentials.currentReadCount()
    XCTAssertEqual(readsBeforeCancel, 0)
    XCTAssertEqual(provider.callCount, 0)
    fixture.workspace.cancelAttachmentConfirmation()

    XCTAssertNil(fixture.workspace.attachmentConfirmationTarget)
    let readsAfterCancel = await credentials.currentReadCount()
    let snapshot = try await fixture.repository.snapshot()
    XCTAssertEqual(readsAfterCancel, 0)
    XCTAssertEqual(provider.callCount, 0)
    XCTAssertEqual(fixture.workspace.currentDraftAttachmentIDs, [content.attachment.id])
    XCTAssertTrue(snapshot.generations.isEmpty)
    try await close(fixture)
  }

  func testConfirmedAttachmentSendUsesExactManagedBytesAndClearsMatchingDraft() async throws {
    let credentials = AttachmentWorkflowCredentialSpy()
    let provider = AttachmentWorkflowProvider()
    let fixture = try await makeFixture(
      credentials: credentials, provider: provider, withProvider: true)
    fixture.workspace.draft = "question"
    let content = try await importOne(into: fixture, bytes: "exact managed bytes 🧪")

    fixture.workspace.performSend()
    try await waitUntil { fixture.workspace.attachmentConfirmationTarget != nil }
    let confirmation = try XCTUnwrap(fixture.workspace.attachmentConfirmationTarget)
    XCTAssertEqual(confirmation.plan.attachments, [content.attachment])
    let send = try XCTUnwrap(fixture.workspace.confirmAttachmentSend())
    try await waitUntil { provider.callCount == 1 }
    let request = try XCTUnwrap(provider.requests.first)
    XCTAssertTrue(request.turns.last?.content.contains("exact managed bytes 🧪") == true)
    XCTAssertTrue(request.turns.last?.content.contains(content.attachment.sha256) == true)
    provider.finish(0)
    await send.value
    await fixture.workspace.coordinator?.waitForIdle()

    let readCount = await credentials.currentReadCount()
    XCTAssertEqual(readCount, 1)
    XCTAssertEqual(fixture.workspace.draft, "")
    XCTAssertTrue(fixture.workspace.currentDraftAttachmentIDs.isEmpty)
    let page = try await fixture.repository.messages(conversationID: fixture.conversationID)
    let message = try XCTUnwrap(page.messages.first)
    XCTAssertEqual(message.attachmentIDs, [content.attachment.id])
    try await close(fixture)
  }

  func testDraftChangeAfterDisclosureInvalidatesConfirmationBeforeCredentialRead() async throws {
    let credentials = AttachmentWorkflowCredentialSpy()
    let provider = AttachmentWorkflowProvider()
    let fixture = try await makeFixture(
      credentials: credentials, provider: provider, withProvider: true)
    _ = try await importOne(into: fixture, bytes: "sensitive")

    fixture.workspace.performSend()
    try await waitUntil { fixture.workspace.attachmentConfirmationTarget != nil }
    fixture.workspace.draft = "changed after review"
    let task = try XCTUnwrap(fixture.workspace.confirmAttachmentSend())
    await task.value

    let readCount = await credentials.currentReadCount()
    let snapshot = try await fixture.repository.snapshot()
    XCTAssertEqual(readCount, 0)
    XCTAssertEqual(provider.callCount, 0)
    XCTAssertNotNil(fixture.workspace.attachmentConfirmationTarget)
    XCTAssertNotNil(fixture.workspace.attachmentConfirmationError)
    XCTAssertEqual(fixture.workspace.draft, "changed after review")
    XCTAssertTrue(snapshot.generations.isEmpty)
    try await close(fixture)
  }

  func testProviderDestinationDriftAfterDisclosureInvalidatesBeforeCredentialRead() async throws {
    let credentials = AttachmentWorkflowCredentialSpy()
    let provider = AttachmentWorkflowProvider()
    let fixture = try await makeFixture(
      credentials: credentials, provider: provider, withProvider: true)
    _ = try await importOne(into: fixture, bytes: "sensitive")

    fixture.workspace.performSend()
    try await waitUntil { fixture.workspace.attachmentConfirmationTarget != nil }
    let original = try XCTUnwrap(fixture.workspace.selectedProvider)
    fixture.workspace.providers = [
      ProviderConfig(
        id: original.id, name: original.name,
        apiRoot: URL(string: "https://changed.invalid/v1")!, modelID: "changed-model",
        credentialReference: original.credentialReference)
    ]
    let task = try XCTUnwrap(fixture.workspace.confirmAttachmentSend())
    await task.value

    let readCount = await credentials.currentReadCount()
    let snapshot = try await fixture.repository.snapshot()
    XCTAssertEqual(readCount, 0)
    XCTAssertEqual(provider.callCount, 0)
    XCTAssertEqual(snapshot.providers, [original])
    XCTAssertTrue(snapshot.generations.isEmpty)
    XCTAssertNotNil(fixture.workspace.attachmentConfirmationError)
    try await close(fixture)
  }

  func testRetryOfAttachmentGenerationRequiresConfirmationAndCancelHasNoNewEffect() async throws {
    let credentials = AttachmentWorkflowCredentialSpy()
    let provider = AttachmentWorkflowProvider()
    let fixture = try await makeFixture(
      credentials: credentials, provider: provider, withProvider: true)
    _ = try await importOne(into: fixture, bytes: "retry fixture")
    fixture.workspace.performSend()
    try await waitUntil { fixture.workspace.attachmentConfirmationTarget != nil }
    let initialSend = try XCTUnwrap(fixture.workspace.confirmAttachmentSend())
    try await waitUntil { provider.callCount == 1 }
    provider.fail(0)
    await initialSend.value
    await fixture.workspace.coordinator?.waitForIdle()
    let before = try await fixture.repository.snapshot()
    let generation = try XCTUnwrap(before.generations.first)
    let readsAfterInitialSend = await credentials.currentReadCount()

    fixture.workspace.performRetry(generation.id)
    try await waitUntil { fixture.workspace.attachmentConfirmationTarget != nil }
    let retryTarget = try XCTUnwrap(fixture.workspace.attachmentConfirmationTarget)
    let readsBeforeCancel = await credentials.currentReadCount()
    XCTAssertEqual(retryTarget.plan.retryGenerationID, generation.id)
    XCTAssertEqual(readsBeforeCancel, readsAfterInitialSend)
    XCTAssertEqual(provider.callCount, 1)
    fixture.workspace.cancelAttachmentConfirmation()

    let after = try await fixture.repository.snapshot()
    let readsAfterCancel = await credentials.currentReadCount()
    XCTAssertEqual(after.generations, before.generations)
    XCTAssertEqual(readsAfterCancel, readsAfterInitialSend)
    XCTAssertEqual(provider.callCount, 1)
    try await close(fixture)
  }

  func testPrepareForCloseJoinsAcceptedReadAndManagedCopy() async throws {
    let fixture = try await makeFixture()
    let content = try AttachmentContent(
      conversationID: fixture.conversationID, originalName: "accepted.txt",
      data: Data("accepted".utf8))
    let reader = AttachmentReaderProbe(result: [content], suspend: true)
    let importTask = try XCTUnwrap(
      fixture.workspace.performAttachmentImport(
        chooser: AttachmentTestChooser(result: [URL(fileURLWithPath: "/synthetic/accepted.txt")]),
        read: reader.read))
    await reader.waitUntilCalled()
    let completion = CompletionProbe()
    let closeTask = Task { @MainActor in
      try await fixture.workspace.prepareForClose()
      await completion.markCompleted()
    }
    try await Task.sleep(for: .milliseconds(30))
    let completedWhilePaused = await completion.isCompleted()
    XCTAssertFalse(completedWhilePaused)

    await reader.resume()
    try await closeTask.value
    await importTask.value
    let completedAfterRelease = await completion.isCompleted()
    let stored = try await fixture.repository.attachmentContent(id: content.attachment.id)
    XCTAssertTrue(completedAfterRelease)
    XCTAssertEqual(stored, content)
    try await fixture.repository.close()
    cleanup(fixture.directory)
  }

  func testAcceptedCopyFailureWhileCloseIsJoiningPreventsSilentClose() async throws {
    let fixture = try await makeFixture()
    let reader = AttachmentReaderProbe(suspend: true, failAfterResume: true)
    let importTask = try XCTUnwrap(
      fixture.workspace.performAttachmentImport(
        chooser: AttachmentTestChooser(result: [URL(fileURLWithPath: "/synthetic/fails.txt")]),
        read: reader.read))
    await reader.waitUntilCalled()
    let closeOutcome = CloseOutcomeProbe()
    let closeTask = Task { @MainActor in
      await closeOutcome.markStarted()
      do {
        try await fixture.workspace.prepareForClose()
        await closeOutcome.complete(with: nil)
      } catch {
        await closeOutcome.complete(with: error)
      }
    }
    await closeOutcome.waitUntilStarted()
    try await waitUntil { fixture.workspace.routineHost == nil }
    await Task.yield()
    let errorWhilePaused = await closeOutcome.currentErrorDescription()
    let completedWhilePaused = await closeOutcome.isCompleted()
    XCTAssertNil(errorWhilePaused)
    XCTAssertFalse(completedWhilePaused)

    await reader.resume()
    await closeTask.value
    await importTask.value
    let completedAfterFailure = await closeOutcome.isCompleted()
    let closeError = await closeOutcome.currentErrorDescription()
    let snapshot = try await fixture.repository.snapshot()
    XCTAssertTrue(completedAfterFailure)
    XCTAssertEqual(closeError, AttachmentWorkspaceError.failed.localizedDescription)
    XCTAssertTrue(fixture.workspace.currentDraftAttachmentIDs.isEmpty)
    XCTAssertTrue(snapshot.drafts.isEmpty)
    await fixture.workspace.shutdownRoutines()
    try await fixture.workspace.coordinator?.shutdown()
    try await fixture.repository.close()
    cleanup(fixture.directory)
  }

  private func makeFixture(
    connect: Bool = true, credentials: any CredentialStore = AttachmentWorkflowCredentialSpy(),
    provider: any ChatProvider = AttachmentWorkflowProvider(), withProvider: Bool = false
  ) async throws -> AttachmentWorkflowFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "AttachmentWorkspaceTests-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let storeURL = directory.appendingPathComponent("workspace.sqlite")
    let repository = try await CoreDataWorkspaceRepository.open(at: storeURL)
    let bot = Bot(name: "Helper")
    let conversationID = UUID()
    try await repository.apply(.createBot(bot, conversationID: conversationID))
    if withProvider {
      try await repository.apply(.saveProvider(AttachmentWorkflowFixture.provider))
    }
    let workspace = PreviewWorkspace(seed: false)
    if connect {
      try await workspace.connect(
        repository, credentials: credentials, provider: provider, displayName: "Attachment tests")
    }
    return AttachmentWorkflowFixture(
      workspace: workspace, repository: repository, directory: directory, storeURL: storeURL,
      botID: bot.id, conversationID: conversationID)
  }

  private func importOne(into fixture: AttachmentWorkflowFixture, bytes: String) async throws
    -> AttachmentContent
  {
    let content = try AttachmentContent(
      conversationID: fixture.conversationID, originalName: "fixture.txt", data: Data(bytes.utf8))
    let task = try XCTUnwrap(
      fixture.workspace.performAttachmentImport(
        chooser: AttachmentTestChooser(result: [URL(fileURLWithPath: "/synthetic/fixture.txt")])
      ) { _, _ in [content] })
    await task.value
    return content
  }

  private func metadataContents(for conversationID: UUID) throws -> [AttachmentContent] {
    [
      try AttachmentContent(
        conversationID: conversationID, originalName: "available.txt", data: Data("one".utf8)),
      try AttachmentContent(
        conversationID: conversationID, originalName: "missing.txt", data: Data("two".utf8)),
    ]
  }

  private func close(_ fixture: AttachmentWorkflowFixture) async throws {
    await fixture.workspace.shutdownRoutines()
    try await fixture.workspace.coordinator?.shutdown()
    try await fixture.repository.close()
    cleanup(fixture.directory)
  }

  private func cleanup(_ directory: URL) {
    try? FileManager.default.removeItem(at: directory)
  }

  private func waitUntil(
    _ condition: @escaping @MainActor () async -> Bool, file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    for _ in 0..<300 {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Timed out waiting for condition", file: file, line: line)
    throw AttachmentWorkflowTestError.timedOut
  }

  private func assertThrowsAttachment(
    _ expected: AttachmentError, operation: () async throws -> Void,
    file: StaticString = #filePath, line: UInt = #line
  ) async {
    do {
      try await operation()
      XCTFail("Expected \(expected)", file: file, line: line)
    } catch {
      XCTAssertEqual(error as? AttachmentError, expected, file: file, line: line)
    }
  }
}

private struct AttachmentWorkflowFixture {
  static let provider = ProviderConfig(
    name: "Fixture", apiRoot: URL(string: "https://fixture.invalid/v1")!,
    modelID: "fixture-model", credentialReference: "session:attachment-workflow")

  let workspace: PreviewWorkspace
  let repository: CoreDataWorkspaceRepository
  let directory: URL
  let storeURL: URL
  let botID: UUID
  let conversationID: UUID
}

@MainActor
private final class AttachmentTestChooser: AttachmentFileChoosing {
  private let result: [URL]?
  private let waits: Bool
  private var continuation: CheckedContinuation<[URL]?, Never>?
  private(set) var chooseCount = 0
  private(set) var cancelCount = 0

  init(result: [URL]?) {
    self.result = result
    waits = false
  }

  init(waitForCancellation: Bool) {
    result = nil
    waits = waitForCancellation
  }

  func choose() async -> [URL]? {
    chooseCount += 1
    guard waits else { return result }
    return await withCheckedContinuation { continuation = $0 }
  }

  func cancel() {
    cancelCount += 1
    continuation?.resume(returning: nil)
    continuation = nil
  }
}

private actor AttachmentReaderProbe {
  private let result: [AttachmentContent]
  private let suspend: Bool
  private let failAfterResume: Bool
  private var resumeContinuation: CheckedContinuation<Void, Never>?
  private var callWaiter: CheckedContinuation<Void, Never>?
  private(set) var callCount = 0

  init(
    result: [AttachmentContent] = [], suspend: Bool = false, failAfterResume: Bool = false
  ) {
    self.result = result
    self.suspend = suspend
    self.failAfterResume = failAfterResume
  }

  func read(_ urls: [URL], _ conversationID: UUID) async throws -> [AttachmentContent] {
    callCount += 1
    callWaiter?.resume()
    callWaiter = nil
    if suspend { await withCheckedContinuation { resumeContinuation = $0 } }
    if failAfterResume { throw AttachmentWorkflowTestError.syntheticRead }
    return result
  }

  func waitUntilCalled() async {
    if callCount > 0 { return }
    await withCheckedContinuation { callWaiter = $0 }
  }

  func currentCallCount() -> Int { callCount }

  func resume() {
    resumeContinuation?.resume()
    resumeContinuation = nil
  }
}

private actor CompletionProbe {
  private(set) var completed = false
  func markCompleted() { completed = true }
  func isCompleted() -> Bool { completed }
}

private actor CloseOutcomeProbe {
  private var started = false
  private var completed = false
  private var errorDescription: String?
  private var startWaiter: CheckedContinuation<Void, Never>?

  func markStarted() {
    started = true
    startWaiter?.resume()
    startWaiter = nil
  }

  func waitUntilStarted() async {
    if started { return }
    await withCheckedContinuation { startWaiter = $0 }
  }

  func complete(with error: Error?) {
    errorDescription = error?.localizedDescription
    completed = true
  }

  func isCompleted() -> Bool { completed }
  func currentErrorDescription() -> String? { errorDescription }
}

private actor AttachmentWorkflowCredentialSpy: CredentialStore {
  private(set) var readCount = 0

  func read(_ reference: String) async throws -> Data {
    readCount += 1
    return Data("synthetic-key".utf8)
  }

  func currentReadCount() -> Int { readCount }

  func write(_ secret: Data, for reference: String) async throws {}
  func remove(_ reference: String) async throws {}
}

private final class AttachmentWorkflowProvider: ChatProvider, @unchecked Sendable {
  private let lock = NSLock()
  private var continuations: [AsyncThrowingStream<ChatEvent, Error>.Continuation] = []
  private var recordedRequests: [ChatRequest] = []

  var callCount: Int { lock.withLock { recordedRequests.count } }
  var requests: [ChatRequest] { lock.withLock { recordedRequests } }

  func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
    AsyncThrowingStream { continuation in
      lock.withLock {
        recordedRequests.append(request)
        continuations.append(continuation)
      }
    }
  }

  func finish(_ index: Int) {
    let continuation = lock.withLock { continuations[index] }
    continuation.yield(.text("done"))
    continuation.yield(.finished)
    continuation.finish()
  }

  func fail(_ index: Int) {
    let continuation = lock.withLock { continuations[index] }
    continuation.finish(throwing: ProviderError.offline)
  }
}

private actor PauseAttachmentSaveRepository: WorkspaceRepository {
  let base: any WorkspaceRepository
  private var shouldPause = true
  private var paused = false
  private var pauseWaiter: CheckedContinuation<Void, Never>?
  private var releaseContinuation: CheckedContinuation<Void, Never>?

  init(base: any WorkspaceRepository) { self.base = base }

  func waitUntilPaused() async {
    if paused { return }
    await withCheckedContinuation { pauseWaiter = $0 }
  }

  func resume() {
    releaseContinuation?.resume()
    releaseContinuation = nil
  }

  func snapshot() async throws -> WorkspaceSnapshot { try await base.snapshot() }
  func attachments(ids: [UUID]) async throws -> [Attachment] {
    try await base.attachments(ids: ids)
  }
  func attachmentContent(id: UUID) async throws -> AttachmentContent {
    try await base.attachmentContent(id: id)
  }
  func apply(_ mutation: WorkspaceMutation, expectedRevision: Int64?) async throws -> Int64 {
    if case .saveDraftWithAttachments = mutation, shouldPause {
      shouldPause = false
      paused = true
      pauseWaiter?.resume()
      pauseWaiter = nil
      await withCheckedContinuation { releaseContinuation = $0 }
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

private actor PauseAttachmentThenFailDraftRepository: WorkspaceRepository {
  let base: any WorkspaceRepository
  let failingConversationID: UUID
  private var didPauseAttachment = false
  private var attachmentPaused = false
  private var pauseWaiter: CheckedContinuation<Void, Never>?
  private var attachmentRelease: CheckedContinuation<Void, Never>?
  private var shouldFailOtherDraft = true
  private var savedAttachmentCount = 0

  init(base: any WorkspaceRepository, failingConversationID: UUID) {
    self.base = base
    self.failingConversationID = failingConversationID
  }

  func waitUntilAttachmentSaveIsPaused() async {
    if attachmentPaused { return }
    await withCheckedContinuation { pauseWaiter = $0 }
  }

  func resumeAttachmentSave() {
    attachmentRelease?.resume()
    attachmentRelease = nil
  }

  func allowOtherDraftSave() { shouldFailOtherDraft = false }
  func attachmentSaveCount() -> Int { savedAttachmentCount }
  func snapshot() async throws -> WorkspaceSnapshot { try await base.snapshot() }
  func attachments(ids: [UUID]) async throws -> [Attachment] {
    try await base.attachments(ids: ids)
  }
  func attachmentContent(id: UUID) async throws -> AttachmentContent {
    try await base.attachmentContent(id: id)
  }
  func apply(_ mutation: WorkspaceMutation, expectedRevision: Int64?) async throws -> Int64 {
    switch mutation {
    case .saveDraftWithAttachments where !didPauseAttachment:
      didPauseAttachment = true
      attachmentPaused = true
      pauseWaiter?.resume()
      pauseWaiter = nil
      await withCheckedContinuation { attachmentRelease = $0 }
      let revision = try await base.apply(mutation, expectedRevision: expectedRevision)
      savedAttachmentCount += 1
      return revision
    case .saveDraft(let draft)
    where draft.conversationID == failingConversationID && shouldFailOtherDraft:
      throw WorkspaceError.storeUnavailable
    default:
      return try await base.apply(mutation, expectedRevision: expectedRevision)
    }
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

private actor FailAttachmentSaveRepository: WorkspaceRepository {
  let base: any WorkspaceRepository
  private var rejectNext = false

  init(base: any WorkspaceRepository) { self.base = base }
  func failNextAttachmentSave() { rejectNext = true }
  func snapshot() async throws -> WorkspaceSnapshot { try await base.snapshot() }
  func attachments(ids: [UUID]) async throws -> [Attachment] {
    try await base.attachments(ids: ids)
  }
  func attachmentContent(id: UUID) async throws -> AttachmentContent {
    try await base.attachmentContent(id: id)
  }
  func apply(_ mutation: WorkspaceMutation, expectedRevision: Int64?) async throws -> Int64 {
    if case .saveDraftWithAttachments = mutation, rejectNext {
      rejectNext = false
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
}

private actor MetadataBehaviorRepository: WorkspaceRepository {
  let base: any WorkspaceRepository
  let missingID: UUID?
  let storeFailure: Bool
  private var readCount = 0

  init(base: any WorkspaceRepository, missingID: UUID? = nil, storeFailure: Bool = false) {
    self.base = base
    self.missingID = missingID
    self.storeFailure = storeFailure
  }

  func metadataReadCount() -> Int { readCount }
  func snapshot() async throws -> WorkspaceSnapshot { try await base.snapshot() }
  func attachments(ids: [UUID]) async throws -> [Attachment] {
    readCount += 1
    if storeFailure { throw WorkspaceError.storeUnavailable }
    if let missingID, ids.contains(missingID) { throw AttachmentError.missingAttachment }
    return try await base.attachments(ids: ids)
  }
  func attachmentContent(id: UUID) async throws -> AttachmentContent {
    try await base.attachmentContent(id: id)
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
}

private enum AttachmentWorkflowTestError: Error { case syntheticRead, timedOut }
