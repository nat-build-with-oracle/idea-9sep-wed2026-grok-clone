import Foundation
import XCTest

@testable import WorkspaceCore

@MainActor final class GroupRoundCoordinatorTests: XCTestCase {
  private struct Fixture {
    let repository: CoreDataWorkspaceRepository
    let reader: RoundReadingRepository
    let bots: [Bot]
    let group: Conversation
    let config: ProviderConfig
    let credentials: RoundCredentials
    let provider: RoundProvider
    let coordinator: GenerationCoordinator

    func command(text: String = "One question", attachmentIDs: [UUID] = []) -> SendRoundCommand {
      SendRoundCommand(
        conversationID: group.id,
        targets: bots.map { SendRoundCommand.Target(targetBotID: $0.id) },
        text: text, attachmentIDs: attachmentIDs)
    }
  }

  private func fixture(count: Int = 3) async throws -> Fixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "GroupRoundCoordinatorTests-\(UUID())")
    let repository = try await CoreDataWorkspaceRepository.open(
      at: directory.appendingPathComponent("workspace.sqlite"))
    var bots: [Bot] = []
    for index in 0..<count {
      let bot = Bot(name: "Member \(index)", description: "Role \(index)")
      try await repository.apply(.createBot(bot, conversationID: UUID()))
      bots.append(bot)
    }
    let group = Conversation(kind: .group, title: "Round fixture", memberBotIDs: bots.map(\.id))
    try await repository.apply(.createGroup(group))
    let config = ProviderConfig(
      name: "Offline fixture", apiRoot: URL(string: "https://fixture.invalid/v1")!,
      modelID: "fixture-model", credentialReference: "round-fixture")
    try await repository.apply(.saveProvider(config))
    let credentials = RoundCredentials()
    let provider = RoundProvider()
    let reader = RoundReadingRepository(base: repository)
    let coordinator = GenerationCoordinator(
      repository: reader, credentials: credentials, provider: provider)
    addTeardownBlock {
      await credentials.release()
      await reader.releaseRoundCommit()
      try? await coordinator.shutdown()
      try await repository.close()
      try? FileManager.default.removeItem(at: directory)
    }
    return Fixture(
      repository: repository, reader: reader, bots: bots, group: group, config: config,
      credentials: credentials, provider: provider, coordinator: coordinator)
  }

  private func waitForCalls(_ count: Int, _ provider: RoundProvider) async throws {
    for _ in 0..<2000 {
      if provider.requests.count >= count { return }
      try await Task.sleep(for: .milliseconds(2))
    }
    XCTFail("Timed out waiting for offline provider call \(count)")
    throw ProviderError.timedOut
  }

  private func waitForCredentialRead(_ credentials: RoundCredentials) async throws {
    for _ in 0..<2000 {
      if await credentials.readCount > 0 { return }
      try await Task.sleep(for: .milliseconds(2))
    }
    XCTFail("Timed out waiting for gated credential read")
    throw ProviderError.timedOut
  }

  func testFrozenContextAndFilesReadOncePerPreparationWithOrderedAttribution() async throws {
    let f = try await fixture()
    let file = try AttachmentContent(
      conversationID: f.group.id, originalName: "round.txt", data: Data("shared fixture text".utf8))
    let command = f.command(attachmentIDs: [file.attachment.id])
    try await f.repository.apply(
      .saveDraftWithAttachments(
        Draft(conversationID: f.group.id, text: command.text, attachmentIDs: command.attachmentIDs),
        attachments: [file]))
    let plan = try await f.coordinator.roundTransmissionPlan(for: command, configuration: f.config)
    XCTAssertEqual(plan.targetBotIDs, f.bots.map(\.id))
    XCTAssertEqual(
      plan.transmissions.map(\.attachments), Array(repeating: [file.attachment], count: 3))
    let readsBefore = await f.credentials.readCount
    XCTAssertEqual(readsBefore, 0)
    XCTAssertTrue(f.provider.requests.isEmpty)
    let ids = try await f.coordinator.submitRound(command, configuration: f.config, consent: plan)
    XCTAssertEqual(ids, command.targets.map(\.generationID))
    // Exactly one history/file read for disclosure and one for accepted preparation, not per bot.
    let reads = await f.reader.counts()
    XCTAssertEqual(reads.messages, 2)
    XCTAssertEqual(reads.attachments, 2)
    for index in 0..<3 {
      try await waitForCalls(index + 1, f.provider)
      XCTAssertEqual(f.provider.requests.count, index + 1)
      let request = f.provider.requests[index]
      XCTAssertTrue(request.turns[0].content.hasPrefix("You are Member \(index)."))
      XCTAssertEqual(
        Array(request.turns.dropFirst()), Array(f.provider.requests[0].turns.dropFirst()))
      XCTAssertFalse(request.turns.contains { $0.content.contains("SIBLING OUTPUT") })
      XCTAssertEqual(
        request.turns.last?.content.components(separatedBy: "shared fixture text").count, 2)
      f.provider.complete(index, text: "SIBLING OUTPUT \(index)")
    }
    await f.coordinator.waitForIdle()
    let snapshot = try await f.repository.snapshot()
    let messages = try await f.repository.messages(conversationID: f.group.id).messages
    XCTAssertTrue(snapshot.generations.allSatisfy { $0.state == .completed })
    XCTAssertEqual(messages.filter { $0.role == .user }.map(\.id), [command.userMessageID])
    XCTAssertEqual(
      messages.filter { $0.role == .assistant }.map(\.speakerNameSnapshot), f.bots.map(\.name))
  }

  func testTextOnlyConsentRejectsChangedOrderTextIdentityAndModelBeforeCredentials() async throws {
    for variant in 0..<4 {
      let f = try await fixture()
      let command = f.command()
      let plan = try await f.coordinator.roundTransmissionPlan(
        for: command, configuration: f.config)
      XCTAssertTrue(plan.transmissions.allSatisfy { $0.attachments.isEmpty })
      var config = f.config
      if variant == 3 {
        config.modelID = "changed-model"
        try await f.repository.apply(.saveProvider(config))
      }
      let changed = SendRoundCommand(
        conversationID: command.conversationID,
        userMessageID: variant == 2 ? UUID() : command.userMessageID,
        targets: variant == 0 ? Array(command.targets.reversed()) : command.targets,
        text: variant == 1 ? "Changed question" : command.text)
      do {
        _ = try await f.coordinator.submitRound(changed, configuration: config, consent: plan)
        XCTFail("Changed round was accepted")
      } catch { XCTAssertEqual(error as? ProviderError, .roundConsentChanged) }
      let reads = await f.credentials.readCount
      let snapshot = try await f.repository.snapshot()
      XCTAssertEqual(reads, 0)
      XCTAssertTrue(snapshot.generations.isEmpty)
      XCTAssertTrue(f.provider.requests.isEmpty)
    }
  }

  func testChangedHistoryAndAttachmentRejectEntireRoundBeforeCredentials() async throws {
    let f = try await fixture()
    let command = f.command()
    let plan = try await f.coordinator.roundTransmissionPlan(for: command, configuration: f.config)
    let file = try AttachmentContent(
      conversationID: f.group.id, originalName: "later.txt", data: Data("later file".utf8))
    try await f.repository.apply(
      .saveDraftWithAttachments(
        Draft(conversationID: f.group.id, text: "Later", attachmentIDs: [file.attachment.id]),
        attachments: [file]))
    let earlier = SendCommand(
      conversationID: f.group.id, targetBotID: f.bots[0].id, text: "Later",
      attachmentIDs: [file.attachment.id])
    try await f.repository.apply(.beginGeneration(earlier))
    do {
      _ = try await f.coordinator.submitRound(command, configuration: f.config, consent: plan)
      XCTFail("Changed context was accepted")
    } catch { XCTAssertEqual(error as? ProviderError, .roundConsentChanged) }
    let reads = await f.credentials.readCount
    XCTAssertEqual(reads, 0)
    XCTAssertTrue(f.provider.requests.isEmpty)
  }

  func testSaveFailureKeepsDraftAndMakesNoProviderCalls() async throws {
    let f = try await fixture()
    let command = f.command()
    try await f.repository.apply(.saveDraft(Draft(conversationID: f.group.id, text: command.text)))
    let plan = try await f.coordinator.roundTransmissionPlan(for: command, configuration: f.config)
    await f.repository.injectNextSaveFailure()
    do {
      _ = try await f.coordinator.submitRound(command, configuration: f.config, consent: plan)
      XCTFail("Expected save failure")
    } catch { XCTAssertEqual(error as? WorkspaceError, .storeUnavailable) }
    let snapshot = try await f.repository.snapshot()
    XCTAssertEqual(snapshot.drafts.first?.text, command.text)
    XCTAssertTrue(snapshot.generations.isEmpty)
    XCTAssertTrue(f.provider.requests.isEmpty)
  }

  func testSecondCredentialFailureLeavesNoPartialRound() async throws {
    let f = try await fixture()
    let command = f.command()
    let plan = try await f.coordinator.roundTransmissionPlan(for: command, configuration: f.config)
    await f.credentials.fail(at: 2)
    do {
      _ = try await f.coordinator.submitRound(command, configuration: f.config, consent: plan)
      XCTFail("Expected credential failure")
    } catch { XCTAssertEqual(error as? ProviderError, .missingCredential) }
    let snapshot = try await f.repository.snapshot()
    XCTAssertTrue(snapshot.generations.isEmpty)
    XCTAssertTrue(f.provider.requests.isEmpty)
  }

  func testStopDuringCredentialReadPreventsCommitAndAllProviderCalls() async throws {
    let f = try await fixture()
    let command = f.command()
    let plan = try await f.coordinator.roundTransmissionPlan(for: command, configuration: f.config)
    await f.credentials.hold()
    let submit = Task {
      try await f.coordinator.submitRound(command, configuration: f.config, consent: plan)
    }
    try await waitForCredentialRead(f.credentials)
    try await f.coordinator.cancelRound(userMessageID: command.userMessageID)
    await f.credentials.release()
    do {
      _ = try await submit.value
      XCTFail("Stopped preparation committed")
    } catch { XCTAssertEqual(error as? ProviderError, .cancelled) }
    let snapshot = try await f.repository.snapshot()
    XCTAssertTrue(snapshot.generations.isEmpty)
    XCTAssertTrue(f.provider.requests.isEmpty)
  }

  func testRenameWhileAuthorizingCannotCommitMismatchedAttribution() async throws {
    let f = try await fixture()
    let command = f.command()
    let plan = try await f.coordinator.roundTransmissionPlan(for: command, configuration: f.config)
    await f.credentials.hold()
    let submit = Task {
      try await f.coordinator.submitRound(command, configuration: f.config, consent: plan)
    }
    try await waitForCredentialRead(f.credentials)
    var bot = f.bots[1]
    bot.name = "Changed while authorizing"
    try await f.repository.apply(.updateBot(bot))
    await f.credentials.release()
    do {
      _ = try await submit.value
      XCTFail("Stale context committed")
    } catch { XCTAssertEqual(error as? WorkspaceError, .staleRevision) }
    let snapshot = try await f.repository.snapshot()
    XCTAssertTrue(snapshot.generations.isEmpty)
    XCTAssertTrue(f.provider.requests.isEmpty)
  }

  func testStopAfterAtomicCommitBeforeEnqueueNeverStartsAnyMember() async throws {
    let f = try await fixture()
    let command = f.command()
    let plan = try await f.coordinator.roundTransmissionPlan(for: command, configuration: f.config)
    await f.reader.holdRoundCommitReturn()
    let submit = Task {
      try await f.coordinator.submitRound(command, configuration: f.config, consent: plan)
    }
    for _ in 0..<2000 {
      if await f.reader.roundCommitted { break }
      try await Task.sleep(for: .milliseconds(2))
    }
    let committed = await f.reader.roundCommitted
    XCTAssertTrue(committed)
    try await f.coordinator.cancelRound(userMessageID: command.userMessageID)
    await f.reader.releaseRoundCommit()
    do {
      _ = try await submit.value
      XCTFail("Stopped committed round enqueued")
    } catch { XCTAssertEqual(error as? ProviderError, .cancelled) }
    await f.coordinator.waitForIdle()
    let snapshot = try await f.repository.snapshot()
    XCTAssertEqual(snapshot.generations.count, 3)
    XCTAssertTrue(snapshot.generations.allSatisfy { $0.state == .cancelled })
    XCTAssertTrue(f.provider.requests.isEmpty)
  }

  func testExplicitRetryAfterStopUsesNewRoundEpochAndOnlyOneMember() async throws {
    let f = try await fixture()
    let command = f.command()
    let plan = try await f.coordinator.roundTransmissionPlan(for: command, configuration: f.config)
    _ = try await f.coordinator.submitRound(command, configuration: f.config, consent: plan)
    try await waitForCalls(1, f.provider)
    try await f.coordinator.cancelRound(userMessageID: command.userMessageID)
    try await f.coordinator.retry(command.targets[1].generationID, configuration: f.config)
    try await waitForCalls(2, f.provider)
    XCTAssertTrue(f.provider.requests[1].turns[0].content.hasPrefix("You are Member 1."))
    f.provider.complete(1, text: "Only selected retry")
    await f.coordinator.waitForIdle()
    let snapshot = try await f.repository.snapshot()
    XCTAssertEqual(
      snapshot.generations.filter { $0.state == .completed }.map(\.id),
      [command.targets[1].generationID])
    XCTAssertEqual(snapshot.generations.filter { $0.state == .cancelled }.count, 2)
    XCTAssertEqual(f.provider.requests.count, 2)
  }

  func testGlobalCapThreeWithFourIndependentRounds() async throws {
    let f = try await fixture(count: 2)
    var rounds = [f.command()]
    for index in 1..<4 {
      let group = Conversation(
        kind: .group, title: "Group \(index)", memberBotIDs: f.bots.map(\.id))
      try await f.repository.apply(.createGroup(group))
      rounds.append(
        SendRoundCommand(
          conversationID: group.id, targets: f.bots.map { .init(targetBotID: $0.id) },
          text: "Round \(index)"))
    }
    for (index, command) in rounds.enumerated() {
      let plan = try await f.coordinator.roundTransmissionPlan(
        for: command, configuration: f.config)
      _ = try await f.coordinator.submitRound(command, configuration: f.config, consent: plan)
      if index < 3 { try await waitForCalls(index + 1, f.provider) }
    }
    XCTAssertEqual(f.provider.requests.count, 3)
    // Complete requests one at a time; each completion admits at most one replacement.
    for index in 0..<8 {
      try await waitForCalls(index + 1, f.provider)
      XCTAssertLessThanOrEqual(f.provider.requests.count - index, 3)
      f.provider.complete(index, text: "Done")
    }
    await f.coordinator.waitForIdle()
    let snapshot = try await f.repository.snapshot()
    XCTAssertEqual(snapshot.generations.filter { $0.state == .completed }.count, 8)
  }

  func testStopPreservesCompletedMemberCancelsActiveAndNeverStartsRemaining() async throws {
    let f = try await fixture()
    let command = f.command()
    let plan = try await f.coordinator.roundTransmissionPlan(for: command, configuration: f.config)
    _ = try await f.coordinator.submitRound(command, configuration: f.config, consent: plan)
    try await waitForCalls(1, f.provider)
    f.provider.complete(0, text: "Completed first")
    try await waitForCalls(2, f.provider)
    try await f.coordinator.cancelRound(userMessageID: command.userMessageID)
    f.provider.complete(1, text: "Late ignored")
    await f.coordinator.waitForIdle()
    let snapshot = try await f.repository.snapshot()
    let states = command.targets.map { target in
      snapshot.generations.first { $0.id == target.generationID }?.state
    }
    XCTAssertEqual(states, [.completed, .cancelled, .cancelled])
    XCTAssertEqual(f.provider.requests.count, 2)
    XCTAssertEqual(f.provider.cancellations, 1)
    let messages = try await f.repository.messages(conversationID: f.group.id).messages
    XCTAssertEqual(messages.filter { $0.role == .assistant }.map(\.text), ["Completed first"])
  }

  func testFailedStopStillStopsTransportAndRecoveryNeverReplaysSiblings() async throws {
    let f = try await fixture()
    let command = f.command()
    let plan = try await f.coordinator.roundTransmissionPlan(for: command, configuration: f.config)
    _ = try await f.coordinator.submitRound(command, configuration: f.config, consent: plan)
    try await waitForCalls(1, f.provider)
    await f.repository.injectNextSaveFailure()
    do {
      try await f.coordinator.cancelRound(userMessageID: command.userMessageID)
      XCTFail("Expected cancellation save failure")
    } catch { XCTAssertEqual(error as? WorkspaceError, .storeUnavailable) }
    await f.coordinator.waitForIdle()
    XCTAssertEqual(f.provider.cancellations, 1)
    XCTAssertEqual(f.provider.requests.count, 1)
    // The failed cancellation is retained for shutdown recovery, not forgotten with removed jobs.
    try await f.coordinator.shutdown()
    let snapshot = try await f.repository.snapshot()
    XCTAssertTrue(snapshot.generations.allSatisfy { $0.state == .cancelled })
    XCTAssertEqual(f.provider.requests.count, 1)
  }

  func testQueuedRoundStopDoesNotStopEarlierOrLaterUserMessages() async throws {
    let f = try await fixture()
    let earlier = SendCommand(
      conversationID: f.group.id, targetBotID: f.bots[0].id, text: "Earlier")
    _ = try await f.coordinator.submit(earlier, configuration: f.config)
    try await waitForCalls(1, f.provider)
    let command = f.command()
    let plan = try await f.coordinator.roundTransmissionPlan(for: command, configuration: f.config)
    _ = try await f.coordinator.submitRound(command, configuration: f.config, consent: plan)
    _ = try await f.coordinator.submit(
      SendCommand(conversationID: f.group.id, targetBotID: f.bots[2].id, text: "Later"),
      configuration: f.config)
    try await f.coordinator.cancelRound(userMessageID: command.userMessageID)
    XCTAssertEqual(f.provider.cancellations, 0)
    f.provider.complete(0, text: "Earlier answer")
    try await waitForCalls(2, f.provider)
    XCTAssertEqual(f.provider.requests[1].turns.last?.content, "Later")
    f.provider.complete(1, text: "Later answer")
    await f.coordinator.waitForIdle()
    XCTAssertEqual(f.provider.requests.count, 2)
  }

  func testProviderFailureContinuesRoundAndExplicitRetryOnlyRunsFailedMember() async throws {
    let f = try await fixture()
    let command = f.command()
    let plan = try await f.coordinator.roundTransmissionPlan(for: command, configuration: f.config)
    _ = try await f.coordinator.submitRound(command, configuration: f.config, consent: plan)
    try await waitForCalls(1, f.provider)
    f.provider.fail(0)
    for index in 1..<3 {
      try await waitForCalls(index + 1, f.provider)
      f.provider.complete(index, text: "Member \(index) done")
    }
    await f.coordinator.waitForIdle()
    try await f.coordinator.retry(command.targets[0].generationID, configuration: f.config)
    try await waitForCalls(4, f.provider)
    XCTAssertTrue(f.provider.requests[3].turns[0].content.hasPrefix("You are Member 0."))
    XCTAssertFalse(f.provider.requests[3].turns.contains { $0.content.contains("done") })
    f.provider.complete(3, text: "Explicit retry only")
    await f.coordinator.waitForIdle()
    let snapshot = try await f.repository.snapshot()
    let messages = try await f.repository.messages(conversationID: f.group.id).messages
    XCTAssertTrue(snapshot.generations.allSatisfy { $0.state == .completed })
    XCTAssertEqual(messages.filter { $0.role == .user }.count, 1)
    XCTAssertEqual(f.provider.requests.count, 4)
  }

  func testEarlyFailedMemberCannotRetryWhileSiblingRunsAndStopRemainsAvailable() async throws {
    let f = try await fixture()
    let command = f.command()
    let plan = try await f.coordinator.roundTransmissionPlan(for: command, configuration: f.config)
    _ = try await f.coordinator.submitRound(command, configuration: f.config, consent: plan)
    try await waitForCalls(1, f.provider)
    f.provider.fail(0)
    try await waitForCalls(2, f.provider)
    let before = await f.credentials.readCount
    do {
      try await f.coordinator.retry(command.targets[0].generationID, configuration: f.config)
      XCTFail("Retry must not compete with the unfinished round")
    } catch { XCTAssertEqual(error as? ProviderError, .roundInProgress) }
    let after = await f.credentials.readCount
    XCTAssertEqual(after, before)
    try await f.coordinator.cancelRound(userMessageID: command.userMessageID)
    await f.coordinator.waitForIdle()
    XCTAssertEqual(f.provider.cancellations, 1)
    XCTAssertEqual(f.provider.requests.count, 2)
    let snapshot = try await f.repository.snapshot()
    XCTAssertEqual(snapshot.generations.filter { $0.state == .failed }.count, 1)
    XCTAssertEqual(snapshot.generations.filter { $0.state == .cancelled }.count, 2)
  }

  func testRoundIsContiguousAheadOfLaterSameConversationSend() async throws {
    let f = try await fixture()
    let command = f.command()
    let plan = try await f.coordinator.roundTransmissionPlan(for: command, configuration: f.config)
    _ = try await f.coordinator.submitRound(command, configuration: f.config, consent: plan)
    try await waitForCalls(1, f.provider)
    _ = try await f.coordinator.submit(
      SendCommand(conversationID: f.group.id, targetBotID: f.bots[0].id, text: "After round"),
      configuration: f.config)
    for index in 0..<3 {
      try await waitForCalls(index + 1, f.provider)
      XCTAssertEqual(f.provider.requests[index].turns.last?.content, command.text)
      f.provider.complete(index, text: "Done")
    }
    try await waitForCalls(4, f.provider)
    XCTAssertEqual(f.provider.requests[3].turns.last?.content, "After round")
    f.provider.complete(3, text: "Later")
    await f.coordinator.waitForIdle()
  }
}

private actor RoundCredentials: CredentialStore {
  private(set) var readCount = 0
  private var failureIndex: Int?
  private var holding = false
  private var waiter: CheckedContinuation<Void, Never>?
  func read(_ reference: String) async throws -> Data {
    readCount += 1
    if holding { await withCheckedContinuation { waiter = $0 } }
    if readCount == failureIndex { throw ProviderError.missingCredential }
    return Data("synthetic-round-key".utf8)
  }
  func hold() { holding = true }
  func release() {
    holding = false
    waiter?.resume()
    waiter = nil
  }
  func fail(at index: Int) { failureIndex = index }
  func write(_ secret: Data, for reference: String) {}
  func remove(_ reference: String) {}
}

private final class RoundProvider: ChatProvider, @unchecked Sendable {
  private let lock = NSLock()
  private var captured: [ChatRequest] = []
  private var streams: [AsyncThrowingStream<ChatEvent, Error>.Continuation] = []
  private var stopped = 0
  var requests: [ChatRequest] { lock.withLock { captured } }
  var cancellations: Int { lock.withLock { stopped } }
  func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
    AsyncThrowingStream { continuation in
      continuation.onTermination = { [weak self] termination in
        if case .cancelled = termination { self?.recordCancellation() }
      }
      lock.withLock {
        captured.append(request)
        streams.append(continuation)
      }
    }
  }
  private func recordCancellation() { lock.withLock { stopped += 1 } }
  func complete(_ index: Int, text: String) {
    let stream = lock.withLock { streams[index] }
    stream.yield(.text(text))
    stream.yield(.finished)
    stream.finish()
  }
  func fail(_ index: Int) {
    lock.withLock { streams[index] }.finish(throwing: ProviderError.offline)
  }
}

private actor RoundReadingRepository: WorkspaceRepository {
  let base: CoreDataWorkspaceRepository
  private var messageReads = 0
  private var attachmentReads = 0
  private var holdingRoundCommit = false
  private var commitWaiter: CheckedContinuation<Void, Never>?
  private(set) var roundCommitted = false
  init(base: CoreDataWorkspaceRepository) { self.base = base }
  func holdRoundCommitReturn() { holdingRoundCommit = true }
  func releaseRoundCommit() {
    holdingRoundCommit = false
    commitWaiter?.resume()
    commitWaiter = nil
  }
  func counts() -> (messages: Int, attachments: Int) { (messageReads, attachmentReads) }
  func snapshot() async throws -> WorkspaceSnapshot { try await base.snapshot() }
  func apply(_ mutation: WorkspaceMutation, expectedRevision: Int64?) async throws -> Int64 {
    let revision = try await base.apply(mutation, expectedRevision: expectedRevision)
    if case .beginGenerationRound = mutation, holdingRoundCommit {
      roundCommitted = true
      await withCheckedContinuation { commitWaiter = $0 }
    }
    return revision
  }
  func messages(conversationID: UUID, beforeSequence: Int64?, limit: Int) async throws
    -> MessagePage
  {
    messageReads += 1
    return try await base.messages(
      conversationID: conversationID, beforeSequence: beforeSequence, limit: limit)
  }
  func message(id: UUID) async throws -> Message { try await base.message(id: id) }
  func attachments(ids: [UUID]) async throws -> [Attachment] {
    try await base.attachments(ids: ids)
  }
  func attachmentContent(id: UUID) async throws -> AttachmentContent {
    attachmentReads += 1
    return try await base.attachmentContent(id: id)
  }
  func search(_ query: String, includeHidden: Bool) async throws -> [Conversation] {
    try await base.search(query, includeHidden: includeHidden)
  }
}
