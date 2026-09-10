import Foundation
import XCTest

@testable import NativeShell
@testable import WorkspaceCore

@MainActor
final class MentionWorkspaceTests: XCTestCase {
  private struct Fixture {
    let repository: CoreDataWorkspaceRepository
    let workspace: PreviewWorkspace
    let credentials: MentionCredentialStore
    let provider: MentionChatProvider
    let providerID: UUID
    let bots: [UUID]
    let groupID: UUID
  }

  func testTypedSingleMentionUsesRoundAndRequiresApprovalBeforeCredentialOrTransport()
    async throws
  {
    let fixture = try await makeFixture(names: ["Alpha", "Beta Bot"])
    let workspace = fixture.workspace
    workspace.selectedTargetBotIDs[fixture.groupID] = [fixture.bots[1]]
    workspace.draft = "@Alpha investigate"
    workspace.draftSaveTask?.cancel()

    let captured = try workspace.captureDraftSubmission()
    guard case .round(let command) = captured.command else {
      return XCTFail("A typed mention must use mandatory round disclosure")
    }
    XCTAssertEqual(command.targets.map(\.targetBotID), [fixture.bots[0]])
    XCTAssertEqual(captured.mentionRouting?.targetBotIDs, [fixture.bots[0]])

    try await workspace.prepareSendOrConfirmAttachments()
    let disclosure = try XCTUnwrap(workspace.attachmentConfirmationTarget)
    XCTAssertTrue(disclosure.isRound)
    XCTAssertEqual(disclosure.targetBotIDs, [fixture.bots[0]])
    XCTAssertEqual(disclosure.requestCount, 1)
    let readsBeforeApproval = await fixture.credentials.numberOfReads()
    XCTAssertEqual(readsBeforeApproval, 0)
    XCTAssertEqual(fixture.provider.callCount, 0)

    let approval = try XCTUnwrap(workspace.confirmAttachmentSend())
    await approval.value
    try await waitUntil { fixture.provider.callCount == 1 }
    let readsAfterApproval = await fixture.credentials.numberOfReads()
    XCTAssertEqual(readsAfterApproval, 1)
    fixture.provider.finish(0)
    await workspace.coordinator?.waitForIdle()
  }

  func testMentionOrderOverridesManualTargetsAndManualChangesAfterReviewDoNotInvalidate()
    async throws
  {
    let fixture = try await makeFixture(names: ["Alpha", "Beta Bot", "Gamma"])
    let workspace = fixture.workspace
    workspace.selectedTargetBotIDs[fixture.groupID] = [fixture.bots[2]]
    workspace.draft = "@\"Beta Bot\" then @Alpha"
    workspace.draftSaveTask?.cancel()

    let captured = try workspace.captureDraftSubmission()
    guard case .round(let command) = captured.command else {
      return XCTFail("Mentions must capture an ordered round")
    }
    XCTAssertEqual(command.targets.map(\.targetBotID), [fixture.bots[1], fixture.bots[0]])
    XCTAssertEqual(workspace.effectiveTargetBotIDs, [fixture.bots[1], fixture.bots[0]])

    try await workspace.prepareSendOrConfirmAttachments()
    XCTAssertEqual(
      workspace.attachmentConfirmationTarget?.targetBotIDs, [fixture.bots[1], fixture.bots[0]])
    workspace.selectedTargetBotIDs[fixture.groupID] = [fixture.bots[0], fixture.bots[2]]

    let approval = try XCTUnwrap(workspace.confirmAttachmentSend())
    await approval.value
    XCTAssertNil(workspace.attachmentConfirmationError)
    try await waitUntil { fixture.provider.callCount == 1 }
    fixture.provider.finish(0)
    try await waitUntil { fixture.provider.callCount == 2 }
    fixture.provider.finish(1)
    await workspace.coordinator?.waitForIdle()
  }

  func testAmbiguousMentionFailsClosedEvenWhenAnotherMentionIsValid() async throws {
    let fixture = try await makeFixture(names: ["Alpha", "Twin", "Twin"])
    let workspace = fixture.workspace
    workspace.selectedTargetBotIDs[fixture.groupID] = fixture.bots
    workspace.draft = "@Alpha and @Twin"
    workspace.draftSaveTask?.cancel()

    let resolution = try XCTUnwrap(workspace.currentMentionResolution)
    XCTAssertEqual(resolution.targetBotIDs, [fixture.bots[0]])
    XCTAssertEqual(resolution.issues, [.ambiguousMember])
    XCTAssertTrue(workspace.effectiveTargetBotIDs.isEmpty)
    XCTAssertThrowsError(try workspace.captureDraftSubmission()) {
      XCTAssertEqual($0 as? GroupMentionIssue, .ambiguousMember)
    }
    let reads = await fixture.credentials.numberOfReads()
    XCTAssertEqual(reads, 0)
    XCTAssertEqual(fixture.provider.callCount, 0)
  }

  func testBoundDuplicateNameSelectsExactIdentityAndDisclosureCarriesIDs() async throws {
    let fixture = try await makeFixture(names: ["Twin", "Twin"])
    let workspace = fixture.workspace
    let member = GroupMentionMember(id: fixture.bots[1], name: "Twin")
    workspace.draft = try GroupMentions.token(for: member) + " answer"
    workspace.draftSaveTask?.cancel()

    XCTAssertEqual(try workspace.captureMentionRouting()?.targetBotIDs, [fixture.bots[1]])
    try await workspace.prepareSendOrConfirmAttachments()
    let disclosure = try XCTUnwrap(workspace.attachmentConfirmationTarget)
    XCTAssertEqual(disclosure.targetBotIDs, [fixture.bots[1]])
    XCTAssertEqual(disclosure.mentionRouting?.targetBotIDs, [fixture.bots[1]])
    XCTAssertTrue(disclosure.targetBot.contains(fixture.bots[1].uuidString.prefix(8).lowercased()))
    let reads = await fixture.credentials.numberOfReads()
    XCTAssertEqual(reads, 0)
  }

  func testReconnectPreservesRawBindingThenApprovalKeepsItOutOfCommandProviderAndTranscript()
    async throws
  {
    let fixture = try await makeFixture(names: ["Alpha", "Beta Bot"])
    let rawToken = try GroupMentions.token(
      for: GroupMentionMember(id: fixture.bots[1], name: "Beta Bot"))
    let rawDraft = "Ask \(rawToken) to review"
    fixture.workspace.draft = rawDraft
    fixture.workspace.draftSaveTask?.cancel()
    try await fixture.workspace.flushDrafts()

    let reconnected = PreviewWorkspace(seed: false)
    try await reconnected.connect(
      fixture.repository, credentials: fixture.credentials, provider: fixture.provider)
    XCTAssertEqual(reconnected.selectedID, fixture.groupID)
    XCTAssertEqual(reconnected.draft, rawDraft)
    XCTAssertEqual(reconnected.effectiveTargetBotIDs, [fixture.bots[1]])

    let captured = try reconnected.captureDraftSubmission()
    guard case .round(let command) = captured.command else {
      return XCTFail("Bound mentions must use a reviewed round")
    }
    XCTAssertEqual(command.expectedDraftText, rawDraft)
    XCTAssertFalse(command.text.localizedCaseInsensitiveContains(fixture.bots[1].uuidString))

    try await reconnected.prepareSendOrConfirmAttachments()
    let approval = try XCTUnwrap(reconnected.confirmAttachmentSend())
    await approval.value
    try await waitUntil { fixture.provider.callCount == 1 }
    let request = try XCTUnwrap(fixture.provider.requests.first)
    XCTAssertFalse(
      request.turns.contains {
        $0.content.localizedCaseInsensitiveContains(fixture.bots[1].uuidString)
      })

    let page = try await fixture.repository.messages(conversationID: fixture.groupID)
    let user = try XCTUnwrap(page.messages.first(where: { $0.role == .user }))
    XCTAssertFalse(user.text.localizedCaseInsensitiveContains(fixture.bots[1].uuidString))
    XCTAssertEqual(user.text, "Ask @\"Beta Bot\" to review")
    XCTAssertEqual(reconnected.draft, "")
    let snapshot = try await fixture.repository.snapshot()
    XCTAssertNil(snapshot.drafts.first(where: { $0.conversationID == fixture.groupID }))
    fixture.provider.finish(0)
    await reconnected.coordinator?.waitForIdle()
  }

  func testDraftNameProviderAndMembershipChangesInvalidateReviewWithoutAuthorization()
    async throws
  {
    let fixture = try await makeFixture(names: ["Alpha", "Beta", "Gamma"])
    let workspace = fixture.workspace
    let raw =
      try GroupMentions.token(
        for: GroupMentionMember(id: fixture.bots[0], name: "Alpha")) + " review"

    workspace.draft = raw
    workspace.draftSaveTask?.cancel()
    try await workspace.prepareSendOrConfirmAttachments()
    workspace.draft = raw + " newer"
    workspace.draftSaveTask?.cancel()
    let changedDraftApproval = try XCTUnwrap(workspace.confirmAttachmentSend())
    await changedDraftApproval.value
    assertReviewRejected(workspace, expectedDraft: raw + " newer")
    workspace.cancelAttachmentConfirmation()

    workspace.draft = raw
    workspace.draftSaveTask?.cancel()
    try await workspace.prepareSendOrConfirmAttachments()
    let botSnapshot = try await fixture.repository.snapshot()
    let bot = try XCTUnwrap(botSnapshot.bots.first(where: { $0.id == fixture.bots[0] }))
    var renamed = bot
    renamed.name = "Renamed"
    try await fixture.repository.apply(.updateBot(renamed))
    try await workspace.refreshPersistent()
    let renamedApproval = try XCTUnwrap(workspace.confirmAttachmentSend())
    await renamedApproval.value
    assertReviewRejected(workspace, expectedDraft: raw)
    workspace.cancelAttachmentConfirmation()

    try await fixture.repository.apply(.updateBot(bot))
    try await workspace.refreshPersistent()
    try await workspace.prepareSendOrConfirmAttachments()
    workspace.selectedProviderID = nil
    let providerApproval = try XCTUnwrap(workspace.confirmAttachmentSend())
    await providerApproval.value
    assertReviewRejected(workspace, expectedDraft: raw)
    workspace.cancelAttachmentConfirmation()

    workspace.selectedProviderID = fixture.providerID
    try await workspace.prepareSendOrConfirmAttachments()
    try await fixture.repository.apply(
      .updateGroup(
        id: fixture.groupID, title: "Team", members: [fixture.bots[1], fixture.bots[2]]))
    try await workspace.refreshPersistent()
    let membershipApproval = try XCTUnwrap(workspace.confirmAttachmentSend())
    await membershipApproval.value
    assertReviewRejected(workspace, expectedDraft: raw)

    let reads = await fixture.credentials.numberOfReads()
    XCTAssertEqual(reads, 0)
    XCTAssertEqual(fixture.provider.callCount, 0)
  }

  func testDirectConversationLeavesAtTextUntouched() async throws {
    let fixture = try await makeFixture(names: ["Alpha", "Beta"])
    let direct = try XCTUnwrap(
      fixture.workspace.conversations.first {
        $0.kind == .direct && $0.memberIDs == [fixture.bots[0]]
      })
    fixture.workspace.selectedID = direct.id
    fixture.workspace.draft = "Email a@b.test and literal @Twitter"
    fixture.workspace.draftSaveTask?.cancel()

    let captured = try fixture.workspace.captureDraftSubmission()
    guard case .single(let command) = captured.command else {
      return XCTFail("Direct chat must remain a single-target send")
    }
    XCTAssertEqual(command.text, "Email a@b.test and literal @Twitter")
    XCTAssertNil(captured.mentionRouting)
    XCTAssertEqual(fixture.workspace.effectiveTargetBotIDs, [fixture.bots[0]])
  }

  func testPendingInsertionBlocksSendAndIsClearedByNavigationContextAndCompletion() async throws {
    let fixture = try await makeFixture(names: ["Alpha", "Beta"])
    let workspace = fixture.workspace
    workspace.draft = "Before"
    workspace.draftSaveTask?.cancel()
    workspace.requestMentionInsertion(fixture.bots[0])
    let first = try XCTUnwrap(workspace.mentionInsertion)
    XCTAssertEqual(first.conversationID, fixture.groupID)
    XCTAssertEqual(first.expectedText, "Before")
    XCTAssertThrowsError(try workspace.captureDraftSubmission()) {
      XCTAssertEqual($0 as? ProviderSetupError, .busy)
    }
    workspace.finishMentionInsertion(UUID(), inserted: true)
    XCTAssertEqual(workspace.mentionInsertion?.id, first.id)

    let directID = try XCTUnwrap(
      workspace.conversations.first { $0.kind == .direct }?.id)
    workspace.selectedID = directID
    XCTAssertNil(workspace.mentionInsertion)
    workspace.selectedID = fixture.groupID
    workspace.requestMentionInsertion(fixture.bots[0])
    XCTAssertNotNil(workspace.mentionInsertion)
    workspace.replyContextGeneration += 1
    XCTAssertNil(workspace.mentionInsertion)

    workspace.requestMentionInsertion(fixture.bots[1])
    let final = try XCTUnwrap(workspace.mentionInsertion)
    let focusBefore = workspace.composerFocusRequest
    workspace.finishMentionInsertion(final.id, inserted: true)
    XCTAssertNil(workspace.mentionInsertion)
    XCTAssertEqual(workspace.composerFocusRequest, focusBefore + 1)
  }

  func testDuplicateRecipientLabelsExpandBeyondCollidingEightCharacterPrefixes() {
    let first = UUID(uuidString: "12345678-0000-4000-8000-000000000001")!
    let second = UUID(uuidString: "12345678-1000-4000-8000-000000000002")!
    let group = UUID()
    let workspace = PreviewWorkspace(seed: false)
    workspace.bots = [PreviewBot(id: first, name: "Twin"), PreviewBot(id: second, name: "Twin")]
    workspace.conversations = [
      PreviewConversation(id: group, title: "Team", kind: .group, memberIDs: [first, second])
    ]
    workspace.selectedID = group

    let firstLabel = workspace.recipientLabel(first)
    let secondLabel = workspace.recipientLabel(second)
    XCTAssertNotEqual(firstLabel, secondLabel)
    XCTAssertTrue(firstLabel.contains("12345678-0"))
    XCTAssertTrue(secondLabel.contains("12345678-1"))
  }

  func testEscapedGroupLiteralUsesManualSingleTargetAndClearsRawDraft() async throws {
    let fixture = try await makeFixture(names: ["Alpha", "Beta"])
    let workspace = fixture.workspace
    workspace.selectedTargetBotIDs[fixture.groupID] = [fixture.bots[0]]
    workspace.draft = #"\@Missing is literal"#
    workspace.draftSaveTask?.cancel()
    let captured = try workspace.captureDraftSubmission()
    guard case .single(let command) = captured.command else {
      return XCTFail("Escaped literal must retain manual targeting")
    }
    XCTAssertEqual(command.text, "@Missing is literal")
    XCTAssertEqual(command.expectedDraftText, #"\@Missing is literal"#)
    XCTAssertNil(captured.mentionRouting)
    _ = try await workspace.submitDraft()
    try await waitUntil { fixture.provider.callCount == 1 }
    fixture.provider.finish(0)
    await workspace.coordinator?.waitForIdle()
    let snapshot = try await fixture.repository.snapshot()
    XCTAssertTrue(snapshot.drafts.isEmpty)
    XCTAssertEqual(snapshot.generations.first?.targetBotID, fixture.bots[0])
    let page = try await fixture.repository.messages(conversationID: fixture.groupID)
    XCTAssertEqual(page.messages.first?.text, "@Missing is literal")
  }

  func testHistoryReplyAndAttachmentMentionsNeverRetargetTheDraft() async throws {
    let fixture = try await makeFixture(names: ["Alpha", "Beta"])
    let workspace = fixture.workspace
    let history = SendCommand(
      conversationID: fixture.groupID, targetBotID: fixture.bots[1], text: "History @Beta")
    try await fixture.repository.apply(.beginGeneration(history))
    for (sequence, kind) in [
      (Int64(1), GenerationEvent.Kind.started), (2, .delta("Assistant says @Beta")),
      (3, .completed),
    ] {
      try await fixture.repository.apply(
        .applyGenerationEvent(
          GenerationEvent(
            generationID: history.generationID, attemptID: history.attemptID,
            sequence: sequence, kind: kind)))
    }
    let historyPage = try await fixture.repository.messages(conversationID: fixture.groupID)
    let parent = try XCTUnwrap(historyPage.messages.last?.id)
    let attachment = try AttachmentContent(
      conversationID: fixture.groupID, originalName: "@Beta.txt", data: Data("@Beta".utf8))
    try await fixture.repository.apply(
      .saveDraftWithAttachments(
        Draft(
          conversationID: fixture.groupID, text: "Review the source",
          attachmentIDs: [attachment.attachment.id], replyToID: parent), attachments: [attachment]))
    try await workspace.refreshPersistent()
    try await workspace.loadMessages(fixture.groupID)
    workspace.selectedTargetBotIDs[fixture.groupID] = [fixture.bots[0]]
    XCTAssertTrue(workspace.currentReply?.excerpt.contains("@Beta") == true)
    let captured = try workspace.captureDraftSubmission()
    guard case .single(let command) = captured.command else {
      return XCTFail("Only group draft text may control mention routing")
    }
    XCTAssertEqual(command.targetBotID, fixture.bots[0])
    XCTAssertNil(captured.mentionRouting)
    try await workspace.prepareSendOrConfirmAttachments()
    let disclosure = try XCTUnwrap(workspace.attachmentConfirmationTarget)
    XCTAssertFalse(disclosure.isRound)
    XCTAssertEqual(disclosure.targetBotIDs, [fixture.bots[0]])
    XCTAssertEqual(disclosure.plan.attachments.map(\.id), [attachment.attachment.id])
    let reads = await fixture.credentials.numberOfReads()
    XCTAssertEqual(reads, 0)
    XCTAssertEqual(fixture.provider.callCount, 0)
  }

  private func makeFixture(names: [String]) async throws -> Fixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "MentionWorkspaceTests-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let repository = try await CoreDataWorkspaceRepository.open(
      at: directory.appendingPathComponent("workspace.sqlite"))
    addTeardownBlock {
      try await repository.close()
      try? FileManager.default.removeItem(at: directory)
    }
    let credentials = MentionCredentialStore()
    let provider = MentionChatProvider()
    let workspace = PreviewWorkspace(seed: false)
    try await workspace.connect(repository, credentials: credentials, provider: provider)
    let providerID = try await workspace.saveProvider(
      id: nil, name: "Fixture", apiRoot: "https://fixture.invalid/v1",
      modelID: "fixture-model", secret: "mention-test-sentinel", allowsLoopbackHTTP: false)
    var bots: [UUID] = []
    for name in names {
      bots.append(
        try await workspace.performCreateBot(
          name: name, description: "", color: "green", shape: .circle))
    }
    let groupID = try await workspace.performCreateGroup(name: "Team", members: bots)
    return Fixture(
      repository: repository, workspace: workspace, credentials: credentials, provider: provider,
      providerID: providerID, bots: bots, groupID: groupID)
  }

  private func assertReviewRejected(_ workspace: PreviewWorkspace, expectedDraft: String) {
    XCTAssertNotNil(workspace.attachmentConfirmationTarget)
    XCTAssertTrue(workspace.attachmentConfirmationError?.contains("changed") == true)
    XCTAssertEqual(workspace.draft, expectedDraft)
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
    throw MentionWorkspaceTestError.timedOut
  }
}

private enum MentionWorkspaceTestError: Error { case timedOut }

private actor MentionCredentialStore: CredentialStore {
  private var secrets: [String: Data] = [:]
  private(set) var readCount = 0

  func read(_ reference: String) throws -> Data {
    readCount += 1
    guard let secret = secrets[reference] else { throw ProviderError.missingCredential }
    return secret
  }

  func write(_ secret: Data, for reference: String) { secrets[reference] = secret }
  func remove(_ reference: String) { secrets[reference] = nil }
  func numberOfReads() -> Int { readCount }
}

private final class MentionChatProvider: ChatProvider, @unchecked Sendable {
  private let lock = NSLock()
  private var continuations: [AsyncThrowingStream<ChatEvent, Error>.Continuation] = []
  private var recordedRequests: [ChatRequest] = []

  var callCount: Int { lock.withLock { continuations.count } }
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
    continuation.yield(.finished)
    continuation.finish()
  }
}
