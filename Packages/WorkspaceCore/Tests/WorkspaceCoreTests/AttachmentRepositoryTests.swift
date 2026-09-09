import XCTest

@testable import WorkspaceCore

@MainActor final class AttachmentRepositoryTests: XCTestCase {
  private func fixture() async throws -> (CoreDataWorkspaceRepository, URL, Bot, UUID) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "AttachmentRepositoryTests-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("workspace.sqlite")
    let repository = try await CoreDataWorkspaceRepository.open(at: url)
    addTeardownBlock { try await repository.close() }
    let bot = Bot(name: "Files")
    let conversationID = UUID()
    try await repository.apply(.createBot(bot, conversationID: conversationID))
    return (repository, url, bot, conversationID)
  }

  private func content(
    _ text: String, conversationID: UUID, name: String = "notes.txt", id: UUID = UUID()
  ) throws -> AttachmentContent {
    try AttachmentContent(
      id: id, conversationID: conversationID, originalName: name, data: Data(text.utf8),
      createdAt: Date(timeIntervalSince1970: 1_789_000_000))
  }

  private func assertAttachmentError(
    _ expected: AttachmentError, _ operation: () async throws -> Void,
    file: StaticString = #filePath, line: UInt = #line
  ) async {
    do {
      try await operation()
      XCTFail("Expected \(expected)", file: file, line: line)
    } catch { XCTAssertEqual(error as? AttachmentError, expected, file: file, line: line) }
  }

  func testContentValidationHashesAndPreservesUnicodeFormatsButRejectsUnsafeInput() throws {
    let conversationID = UUID()
    let unicode = "สวัสดี 👩‍💻\u{FEFF}\n"
    let valid = try content(unicode, conversationID: conversationID)
    XCTAssertEqual(valid.data, Data(unicode.utf8))
    XCTAssertEqual(valid.attachment.byteCount, valid.data.count)
    XCTAssertEqual(valid.attachment.sha256.count, 64)
    XCTAssertThrowsError(
      try AttachmentContent(
        conversationID: conversationID, originalName: "../secret.txt", data: Data("x".utf8))
    ) {
      XCTAssertEqual($0 as? AttachmentError, .invalidName)
    }
    XCTAssertThrowsError(
      try AttachmentContent(
        conversationID: conversationID, originalName: "bad.txt", data: Data([0xFF]))
    ) {
      XCTAssertEqual($0 as? AttachmentError, .invalidText)
    }
    XCTAssertThrowsError(
      try AttachmentContent(
        conversationID: conversationID, originalName: "bad.txt", data: Data([0x61, 0, 0x62]))
    ) {
      XCTAssertEqual($0 as? AttachmentError, .invalidText)
    }
    XCTAssertThrowsError(
      try AttachmentContent(
        conversationID: conversationID, originalName: "large.txt",
        data: Data(repeating: 0x61, count: AttachmentLimits.maxFileBytes + 1))
    ) {
      XCTAssertEqual($0 as? AttachmentError, .fileTooLarge)
    }
  }

  func testExactBytesMetadataAndOrderSurviveReopen() async throws {
    let (repository, url, _, conversationID) = try await fixture()
    let first = try content("first\r\n👩‍💻", conversationID: conversationID, name: "first.txt")
    let second = try content("second", conversationID: conversationID, name: "second.txt")
    let draft = Draft(
      conversationID: conversationID, text: "",
      attachmentIDs: [second.attachment.id, first.attachment.id])
    try await repository.apply(.saveDraftWithAttachments(draft, attachments: [first, second]))
    try await repository.apply(.saveDraftWithAttachments(draft, attachments: [first, second]))
    let metadata = try await repository.attachments(ids: draft.attachmentIDs)
    let exported = try await repository.exportSnapshot()
    XCTAssertEqual(metadata, [second.attachment, first.attachment])
    XCTAssertEqual(exported.attachments.count, 2)
    try await repository.close()

    let reopened = try await CoreDataWorkspaceRepository.open(at: url)
    addTeardownBlock { try await reopened.close() }
    let reopenedFirst = try await reopened.attachmentContent(id: first.attachment.id)
    let reopenedSecond = try await reopened.attachmentContent(id: second.attachment.id)
    let reopenedSnapshot = try await reopened.snapshot()
    XCTAssertEqual(reopenedFirst, first)
    XCTAssertEqual(reopenedSecond, second)
    XCTAssertEqual(reopenedSnapshot.drafts, [draft])
  }

  func testMaximumSizePayloadSurvivesReopenExactly() async throws {
    let (repository, url, _, conversationID) = try await fixture()
    let bytes = Data(repeating: 0x78, count: AttachmentLimits.maxFileBytes)
    let file = try AttachmentContent(
      conversationID: conversationID, originalName: "maximum.txt", data: bytes)
    try await repository.apply(
      .saveDraftWithAttachments(
        Draft(conversationID: conversationID, text: "", attachmentIDs: [file.attachment.id]),
        attachments: [file]))
    try await repository.close()
    let reopened = try await CoreDataWorkspaceRepository.open(at: url)
    addTeardownBlock { try await reopened.close() }
    let persisted = try await reopened.attachmentContent(id: file.attachment.id)
    XCTAssertEqual(persisted.attachment, file.attachment)
    XCTAssertEqual(persisted.data, bytes)
  }

  func testInvalidCountDuplicateMissingForeignAndIdentityConflictRollBack() async throws {
    let (repository, _, _, conversationID) = try await fixture()
    let stored = try content("original", conversationID: conversationID)
    try await repository.apply(
      .saveDraftWithAttachments(
        Draft(conversationID: conversationID, text: "", attachmentIDs: [stored.attachment.id]),
        attachments: [stored]))
    let before = try await repository.snapshot()

    await assertAttachmentError(.duplicateReference) {
      try await repository.apply(
        .saveDraft(
          Draft(
            conversationID: conversationID, text: "",
            attachmentIDs: [stored.attachment.id, stored.attachment.id])))
    }
    await assertAttachmentError(.missingAttachment) {
      try await repository.apply(
        .saveDraft(Draft(conversationID: conversationID, text: "", attachmentIDs: [UUID()])))
    }
    let foreign = try content("foreign", conversationID: UUID())
    await assertAttachmentError(.foreignAttachment) {
      try await repository.apply(
        .saveDraftWithAttachments(
          Draft(conversationID: conversationID, text: "", attachmentIDs: [foreign.attachment.id]),
          attachments: [foreign]))
    }
    let conflict = try content("changed", conversationID: conversationID, id: stored.attachment.id)
    await assertAttachmentError(.identityConflict) {
      try await repository.apply(
        .saveDraftWithAttachments(
          Draft(conversationID: conversationID, text: "", attachmentIDs: [conflict.attachment.id]),
          attachments: [conflict]))
    }
    let tooMany = (0..<AttachmentLimits.maxCount + 1).map { _ in UUID() }
    await assertAttachmentError(.tooManyAttachments) {
      try await repository.apply(
        .saveDraft(Draft(conversationID: conversationID, text: "", attachmentIDs: tooMany)))
    }
    let after = try await repository.snapshot()
    let afterContent = try await repository.attachmentContent(id: stored.attachment.id)
    XCTAssertEqual(after, before)
    XCTAssertEqual(afterContent, stored)
  }

  func testAggregateDraftLimitRollsBackEveryNewPayload() async throws {
    let (repository, _, _, conversationID) = try await fixture()
    let inputs = try (0..<3).map { index in
      try AttachmentContent(
        conversationID: conversationID, originalName: "\(index).txt",
        data: Data(repeating: 0x61, count: 9 * 1_024 * 1_024))
    }
    let before = try await repository.snapshot()
    await assertAttachmentError(.draftTooLarge) {
      try await repository.apply(
        .saveDraftWithAttachments(
          Draft(
            conversationID: conversationID, text: "", attachmentIDs: inputs.map(\.attachment.id)),
          attachments: inputs))
    }
    let after = try await repository.snapshot()
    XCTAssertEqual(after, before)
    for input in inputs {
      await assertAttachmentError(.missingAttachment) {
        _ = try await repository.attachmentContent(id: input.attachment.id)
      }
    }
  }

  func testSaveFailureRollsBackNewBinaryAndLastReferencePruneAcrossReopen() async throws {
    let (repository, url, _, conversationID) = try await fixture()
    let old = try content("old exact bytes", conversationID: conversationID, name: "old.txt")
    let replacement = try content(
      "new exact bytes", conversationID: conversationID, name: "new.txt")
    try await repository.apply(
      .saveDraftWithAttachments(
        Draft(conversationID: conversationID, text: "old", attachmentIDs: [old.attachment.id]),
        attachments: [old]))
    let before = try await repository.snapshot()
    await repository.injectNextSaveFailure()
    do {
      try await repository.apply(
        .saveDraftWithAttachments(
          Draft(
            conversationID: conversationID, text: "new",
            attachmentIDs: [replacement.attachment.id]),
          attachments: [replacement]))
      XCTFail("Expected atomic save failure")
    } catch { XCTAssertEqual(error as? WorkspaceError, .storeUnavailable) }
    let after = try await repository.snapshot()
    let oldAfter = try await repository.attachmentContent(id: old.attachment.id)
    XCTAssertEqual(after, before)
    XCTAssertEqual(oldAfter, old)
    await assertAttachmentError(.missingAttachment) {
      _ = try await repository.attachmentContent(id: replacement.attachment.id)
    }
    try await repository.close()

    let reopened = try await CoreDataWorkspaceRepository.open(at: url)
    addTeardownBlock { try await reopened.close() }
    let reopenedSnapshot = try await reopened.snapshot()
    let reopenedOld = try await reopened.attachmentContent(id: old.attachment.id)
    XCTAssertEqual(reopenedSnapshot, before)
    XCTAssertEqual(reopenedOld, old)
    do {
      _ = try await reopened.attachmentContent(id: replacement.attachment.id)
      XCTFail("Rolled-back payload must remain absent")
    } catch { XCTAssertEqual(error as? AttachmentError, .missingAttachment) }
  }

  func testAttachmentOnlySendPersistsReferencesAndDraftRaceDoesNotClearNewPayload() async throws {
    let (repository, _, bot, conversationID) = try await fixture()
    let first = try content("first", conversationID: conversationID, name: "first.txt")
    let second = try content("second", conversationID: conversationID, name: "second.txt")
    try await repository.apply(
      .saveDraftWithAttachments(
        Draft(conversationID: conversationID, text: "", attachmentIDs: [first.attachment.id]),
        attachments: [first]))
    let command = SendCommand(
      conversationID: conversationID, targetBotID: bot.id, text: "",
      attachmentIDs: [first.attachment.id])
    try await repository.apply(
      .saveDraftWithAttachments(
        Draft(
          conversationID: conversationID, text: "new",
          attachmentIDs: [first.attachment.id, second.attachment.id]),
        attachments: [second]))
    try await repository.apply(.beginGeneration(command))
    let page = try await repository.messages(conversationID: conversationID)
    XCTAssertEqual(page.messages.first?.text, "")
    XCTAssertEqual(page.messages.first?.attachmentIDs, [first.attachment.id])
    let snapshot = try await repository.snapshot()
    let storedFirst = try await repository.attachmentContent(id: first.attachment.id)
    let storedSecond = try await repository.attachmentContent(id: second.attachment.id)
    XCTAssertEqual(
      snapshot.drafts.first?.attachmentIDs, [first.attachment.id, second.attachment.id])
    XCTAssertEqual(storedFirst, first)
    XCTAssertEqual(storedSecond, second)
  }

  func testSaveDraftPrunesOnlyAfterLastReferenceIsRemoved() async throws {
    let (repository, _, bot, conversationID) = try await fixture()
    let file = try content("shared", conversationID: conversationID)
    let draft = Draft(
      conversationID: conversationID, text: "send", attachmentIDs: [file.attachment.id])
    try await repository.apply(.saveDraftWithAttachments(draft, attachments: [file]))
    try await repository.apply(
      .beginGeneration(
        SendCommand(
          conversationID: conversationID, targetBotID: bot.id, text: "send",
          attachmentIDs: [file.attachment.id])))
    try await repository.apply(
      .saveDraft(Draft(conversationID: conversationID, text: "replacement")))
    let stored = try await repository.attachmentContent(id: file.attachment.id)
    XCTAssertEqual(stored, file)
  }

  func testRemovingLastDraftReferencePrunesPayloadAndCapturedSendFailsWithoutResurrection()
    async throws
  {
    let (repository, _, bot, conversationID) = try await fixture()
    let file = try content("ephemeral", conversationID: conversationID)
    try await repository.apply(
      .saveDraftWithAttachments(
        Draft(conversationID: conversationID, text: "", attachmentIDs: [file.attachment.id]),
        attachments: [file]))
    let captured = SendCommand(
      conversationID: conversationID, targetBotID: bot.id, text: "",
      attachmentIDs: [file.attachment.id])
    try await repository.apply(.saveDraft(Draft(conversationID: conversationID, text: "new")))
    let before = try await repository.snapshot()
    await assertAttachmentError(.missingAttachment) {
      try await repository.apply(.beginGeneration(captured))
    }
    let after = try await repository.snapshot()
    XCTAssertEqual(after, before)
    await assertAttachmentError(.missingAttachment) {
      _ = try await repository.attachmentContent(id: file.attachment.id)
    }
  }

  func testCorruptPayloadFailsClosedForReadExportAndDeletionWithoutEffects() async throws {
    let (repository, _, bot, conversationID) = try await fixture()
    let file = try content("original", conversationID: conversationID)
    try await repository.apply(
      .saveDraftWithAttachments(
        Draft(conversationID: conversationID, text: "", attachmentIDs: [file.attachment.id]),
        attachments: [file]))
    try await repository.injectAttachmentCorruptionForTesting(
      id: file.attachment.id, data: Data("tampered".utf8))
    let before = try await repository.snapshot()
    for operation in [
      { _ = try await repository.attachmentContent(id: file.attachment.id) },
      { _ = try await repository.exportSnapshot() },
      { _ = try await repository.botDeletionPlan(botID: bot.id) },
    ] {
      await assertAttachmentError(.corruptAttachment, operation)
    }
    let after = try await repository.snapshot()
    XCTAssertEqual(after, before)
  }

  func testBotDeletionCountsOnlyUnreferencedDirectPayloadAndKeepsGroupPayload() async throws {
    let (repository, _, deleted, directID) = try await fixture()
    let remaining = Bot(name: "Remaining")
    let remainingDirectID = UUID()
    try await repository.apply(.createBot(remaining, conversationID: remainingDirectID))
    let group = Conversation(
      kind: .group, title: "Keep", memberBotIDs: [deleted.id, remaining.id])
    try await repository.apply(.createGroup(group))
    let directFile = try content("delete bytes", conversationID: directID, name: "delete.txt")
    let groupFile = try content("keep bytes", conversationID: group.id, name: "keep.txt")
    try await repository.apply(
      .saveDraftWithAttachments(
        Draft(conversationID: directID, text: "direct", attachmentIDs: [directFile.attachment.id]),
        attachments: [directFile]))
    let directCommand = SendCommand(
      conversationID: directID, targetBotID: deleted.id, text: "direct",
      attachmentIDs: [directFile.attachment.id])
    try await repository.apply(.beginGeneration(directCommand))
    try await repository.apply(
      .cancelGeneration(id: directCommand.generationID, attemptID: directCommand.attemptID))
    try await repository.apply(
      .saveDraftWithAttachments(
        Draft(conversationID: group.id, text: "group", attachmentIDs: [groupFile.attachment.id]),
        attachments: [groupFile]))
    let groupCommand = SendCommand(
      conversationID: group.id, targetBotID: deleted.id, text: "group",
      attachmentIDs: [groupFile.attachment.id])
    try await repository.apply(.beginGeneration(groupCommand))
    try await repository.apply(
      .cancelGeneration(id: groupCommand.generationID, attemptID: groupCommand.attemptID))

    let plan = try await repository.botDeletionPlan(botID: deleted.id)
    XCTAssertEqual(plan.attachmentIDs, [directFile.attachment.id])
    XCTAssertEqual(plan.attachmentCount, 1)
    XCTAssertEqual(plan.attachmentBytes, directFile.data.count)
    try await repository.apply(.deleteBot(expected: plan))
    await assertAttachmentError(.missingAttachment) {
      _ = try await repository.attachmentContent(id: directFile.attachment.id)
    }
    let retained = try await repository.attachmentContent(id: groupFile.attachment.id)
    XCTAssertEqual(retained, groupFile)
    let groupPage = try await repository.messages(conversationID: group.id)
    XCTAssertEqual(groupPage.messages.first?.attachmentIDs, [groupFile.attachment.id])
  }

  func testExportIncludesExactReferencedPayloadOnceAndSummary() async throws {
    let (repository, _, _, conversationID) = try await fixture()
    let file = try content("private exact bytes", conversationID: conversationID)
    try await repository.apply(
      .saveDraftWithAttachments(
        Draft(conversationID: conversationID, text: "", attachmentIDs: [file.attachment.id]),
        attachments: [file]))
    let export = try await repository.exportSnapshot()
    XCTAssertEqual(export.attachments, [file])
    XCTAssertEqual(export.summary.attachmentCount, 1)
    XCTAssertEqual(export.summary.attachmentBytes, file.data.count)
    XCTAssertEqual(export.formatVersion, 3)
    XCTAssertEqual(export.sourceSchemaVersion, 3)
    XCTAssertEqual(
      try JSONDecoder().decode(WorkspaceExportDocument.self, from: export.encoded()), export)
  }

  func testExportRejectsBase64LowerBoundBeforeReadingLargePayloads() async throws {
    let (repository, _, firstBot, firstConversationID) = try await fixture()
    let bytes = Data(repeating: 0x61, count: AttachmentLimits.maxFileBytes)
    var firstAttachmentID: UUID?
    for index in 0..<8 {
      let bot: Bot
      let conversationID: UUID
      if index == 0 {
        bot = firstBot
        conversationID = firstConversationID
      } else {
        bot = Bot(name: "Large \(index)")
        conversationID = UUID()
        try await repository.apply(.createBot(bot, conversationID: conversationID))
      }
      let file = try AttachmentContent(
        conversationID: conversationID, originalName: "large-\(index).txt", data: bytes)
      firstAttachmentID = firstAttachmentID ?? file.attachment.id
      try await repository.apply(
        .saveDraftWithAttachments(
          Draft(conversationID: conversationID, text: "", attachmentIDs: [file.attachment.id]),
          attachments: [file]))
    }
    // If export fetched/verifed content before its metadata preflight, this corruption would win.
    try await repository.injectAttachmentCorruptionForTesting(
      id: try XCTUnwrap(firstAttachmentID), data: Data("corrupt".utf8))
    do {
      _ = try await repository.exportSnapshot()
      XCTFail("Expected encoded-size lower-bound rejection")
    } catch {
      guard case .exceedsByteLimit(let limit, let actual) = error as? WorkspaceExportError else {
        return XCTFail("Expected exceedsByteLimit, got \(error)")
      }
      XCTAssertEqual(limit, WorkspaceExportDocument.defaultMaxEncodedBytes)
      XCTAssertGreaterThanOrEqual(actual, limit)
    }
  }
}
