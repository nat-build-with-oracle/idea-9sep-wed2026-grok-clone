import XCTest

@testable import NativeShell

@MainActor
final class PreviewWorkspaceTests: XCTestCase {
  func testSampleWorkspaceUsesSyntheticProfileAndPausedRoutine() throws {
    let workspace = PreviewWorkspace()
    XCTAssertEqual(workspace.name, "Demo User")
    XCTAssertEqual(workspace.routines.map(\.name), ["Project check-in"])
    XCTAssertTrue(workspace.routines.allSatisfy { !$0.enabled })
    let conversationID = try XCTUnwrap(workspace.selectedID)
    let introduction = try XCTUnwrap(workspace.messages[conversationID]?.first)
    XCTAssertTrue(introduction.text.contains("fictional sample conversation"))
  }

  func testGroupCannotImplicitlyOwnFirstMembersRoutine() throws {
    let workspace = PreviewWorkspace()
    let members = Array(workspace.bots.prefix(2).map(\.id))
    try workspace.createGroup(name: "Together", members: members)
    let count = workspace.routines.count
    XCTAssertNil(workspace.currentBot)
    XCTAssertThrowsError(try workspace.addRoutine(name: "Group check", interval: 30)) {
      XCTAssertEqual($0 as? PreviewError, .missingConversation)
    }
    XCTAssertEqual(workspace.routines.count, count)
  }

  func testCreateBotTrimsAValidName() throws {
    let workspace = PreviewWorkspace(seed: false)

    let id = try workspace.createBot(
      name: "  Helper  ", description: "Notes", color: "blue", shape: .square)

    XCTAssertEqual(workspace.bots.first(where: { $0.id == id })?.name, "Helper")
  }

  func testCreateBotRejectsAnEmptyNameWithoutMutatingWorkspace() {
    let workspace = PreviewWorkspace(seed: false)
    workspace.notice = "keep me"

    XCTAssertThrowsError(
      try workspace.createBot(name: " \n ", description: "", color: "green", shape: .circle)
    ) {
      XCTAssertEqual($0 as? PreviewError, .invalidName)
    }

    XCTAssertTrue(workspace.bots.isEmpty)
    XCTAssertTrue(workspace.conversations.isEmpty)
    XCTAssertTrue(workspace.messages.isEmpty)
    XCTAssertNil(workspace.selectedID)
    XCTAssertEqual(workspace.notice, "keep me")
  }

  func testCreateBotRejectsANameLongerThanEightyCharacters() {
    let workspace = PreviewWorkspace(seed: false)

    XCTAssertThrowsError(
      try workspace.createBot(
        name: String(repeating: "a", count: 81), description: "", color: "green", shape: .circle)
    ) {
      XCTAssertEqual($0 as? PreviewError, .invalidName)
    }
  }

  func testCreateBotAssignsUniqueBotAndConversationIdentities() throws {
    let workspace = PreviewWorkspace(seed: false)

    let firstBotID = try workspace.createBot(
      name: "Same", description: "", color: "green", shape: .circle)
    let firstConversationID = try XCTUnwrap(workspace.selectedID)
    let secondBotID = try workspace.createBot(
      name: "Same", description: "", color: "green", shape: .circle)
    let secondConversationID = try XCTUnwrap(workspace.selectedID)

    XCTAssertNotEqual(firstBotID, secondBotID)
    XCTAssertNotEqual(firstConversationID, secondConversationID)
    XCTAssertEqual(Set(workspace.bots.map(\.id)).count, 2)
    XCTAssertEqual(Set(workspace.conversations.map(\.id)).count, 2)
  }

  func testCreateGroupRejectsDuplicateMembersWithoutMutatingWorkspace() throws {
    let workspace = PreviewWorkspace(seed: false)
    let first = try workspace.createBot(
      name: "One", description: "", color: "green", shape: .circle)
    _ = try workspace.createBot(name: "Two", description: "", color: "blue", shape: .square)
    let conversationIDs = workspace.conversations.map(\.id)
    let messageKeys = Set(workspace.messages.keys)
    let selectedID = workspace.selectedID

    XCTAssertThrowsError(try workspace.createGroup(name: "Team", members: [first, first])) {
      XCTAssertEqual($0 as? PreviewError, .invalidMembers)
    }

    XCTAssertEqual(workspace.conversations.map(\.id), conversationIDs)
    XCTAssertEqual(Set(workspace.messages.keys), messageKeys)
    XCTAssertEqual(workspace.selectedID, selectedID)
  }

  func testCreateGroupRejectsHiddenMembers() throws {
    let workspace = PreviewWorkspace(seed: false)
    let first = try workspace.createBot(
      name: "One", description: "", color: "green", shape: .circle)
    let second = try workspace.createBot(
      name: "Two", description: "", color: "blue", shape: .square)
    let firstConversation = try XCTUnwrap(
      workspace.conversations.first(where: { $0.memberIDs == [first] }))
    workspace.toggleHidden(firstConversation)

    XCTAssertThrowsError(try workspace.createGroup(name: "Team", members: [first, second])) {
      XCTAssertEqual($0 as? PreviewError, .invalidMembers)
    }
  }

  func testCreateGroupRejectsFewerThanTwoMembers() throws {
    let workspace = PreviewWorkspace(seed: false)
    let only = try workspace.createBot(name: "One", description: "", color: "green", shape: .circle)

    XCTAssertThrowsError(try workspace.createGroup(name: "Team", members: [only])) {
      XCTAssertEqual($0 as? PreviewError, .invalidMembers)
    }
  }

  func testCreateGroupRejectsMoreThanSixMembers() throws {
    let workspace = PreviewWorkspace(seed: false)
    let members = try (1...7).map {
      try workspace.createBot(name: "Bot \($0)", description: "", color: "green", shape: .circle)
    }

    XCTAssertThrowsError(try workspace.createGroup(name: "Team", members: members)) {
      XCTAssertEqual($0 as? PreviewError, .invalidMembers)
    }
  }

  func testCreateGroupRejectsAnInvalidNameWithoutMutatingWorkspace() throws {
    let workspace = PreviewWorkspace(seed: false)
    let first = try workspace.createBot(
      name: "One", description: "", color: "green", shape: .circle)
    let second = try workspace.createBot(
      name: "Two", description: "", color: "blue", shape: .square)
    let conversationIDs = workspace.conversations.map(\.id)
    let selectedID = workspace.selectedID

    XCTAssertThrowsError(try workspace.createGroup(name: "   ", members: [first, second])) {
      XCTAssertEqual($0 as? PreviewError, .invalidName)
    }

    XCTAssertEqual(workspace.conversations.map(\.id), conversationIDs)
    XCTAssertEqual(workspace.selectedID, selectedID)
  }

  func testCreateGroupAssignsUniqueConversationIdentities() throws {
    let workspace = PreviewWorkspace(seed: false)
    let first = try workspace.createBot(
      name: "One", description: "", color: "green", shape: .circle)
    let second = try workspace.createBot(
      name: "Two", description: "", color: "blue", shape: .square)

    let firstGroupID = try workspace.createGroup(name: "Team", members: [first, second])
    let secondGroupID = try workspace.createGroup(name: "Team", members: [first, second])

    XCTAssertNotEqual(firstGroupID, secondGroupID)
    XCTAssertEqual(workspace.conversations.filter { $0.kind == .group }.count, 2)
  }

  func testDraftsRemainScopedToTheirConversation() throws {
    let workspace = PreviewWorkspace(seed: false)
    _ = try workspace.createBot(name: "One", description: "", color: "green", shape: .circle)
    let firstConversationID = try XCTUnwrap(workspace.selectedID)
    workspace.draft = "first draft"
    _ = try workspace.createBot(name: "Two", description: "", color: "blue", shape: .square)
    let secondConversationID = try XCTUnwrap(workspace.selectedID)
    workspace.draft = "second draft"

    workspace.select(firstConversationID)
    XCTAssertEqual(workspace.draft, "first draft")
    workspace.select(secondConversationID)
    XCTAssertEqual(workspace.draft, "second draft")
  }

  func testSaveLocalMessageAppendsOnlyOneUserMessage() throws {
    let workspace = PreviewWorkspace(seed: false)
    _ = try workspace.createBot(name: "Helper", description: "", color: "green", shape: .circle)
    let conversationID = try XCTUnwrap(workspace.selectedID)
    workspace.messages[conversationID] = [PreviewMessage(.assistant, "Existing response")]
    workspace.draft = "  hello locally  "

    try workspace.saveLocalMessage()

    let messages = try XCTUnwrap(workspace.messages[conversationID])
    XCTAssertEqual(messages.count, 2)
    XCTAssertEqual(messages.last?.text, "hello locally")
    if case .user? = messages.last?.role {
    } else {
      XCTFail("Expected the new message to have the user role")
    }
    XCTAssertEqual(
      messages.filter { if case .assistant = $0.role { true } else { false } }.count, 1)
  }

  func testSaveLocalMessageClearsOnlyTheSelectedDraft() throws {
    let workspace = PreviewWorkspace(seed: false)
    _ = try workspace.createBot(name: "One", description: "", color: "green", shape: .circle)
    let firstID = try XCTUnwrap(workspace.selectedID)
    workspace.draft = "send me"
    _ = try workspace.createBot(name: "Two", description: "", color: "blue", shape: .square)
    let secondID = try XCTUnwrap(workspace.selectedID)
    workspace.draft = "keep me"
    workspace.select(firstID)

    try workspace.saveLocalMessage()

    XCTAssertEqual(workspace.drafts[firstID], "")
    XCTAssertEqual(workspace.drafts[secondID], "keep me")
  }

  func testSaveLocalMessageMakesOfflineOnlyBehaviorExplicit() throws {
    let workspace = PreviewWorkspace(seed: false)
    _ = try workspace.createBot(name: "Helper", description: "", color: "green", shape: .circle)
    workspace.draft = "hello"

    try workspace.saveLocalMessage()

    XCTAssertEqual(
      workspace.notice,
      "Preview message only. No AI provider is connected; this session is not saved to disk.")
  }

  func testSearchMatchesConversationMessageTextCaseInsensitively() throws {
    let workspace = PreviewWorkspace(seed: false)
    _ = try workspace.createBot(name: "Helper", description: "", color: "green", shape: .circle)
    let matchingID = try XCTUnwrap(workspace.selectedID)
    workspace.messages[matchingID] = [PreviewMessage(.assistant, "Needle in a message")]
    _ = try workspace.createBot(name: "Other", description: "", color: "blue", shape: .square)

    workspace.search = "  needle  "

    XCTAssertEqual(workspace.visibleConversations.map(\.id), [matchingID])
  }

  func testHiddenDirectConversationIsExcludedByDefault() throws {
    let workspace = PreviewWorkspace(seed: false)
    let botID = try workspace.createBot(
      name: "Helper", description: "", color: "green", shape: .circle)
    let conversation = try XCTUnwrap(
      workspace.conversations.first(where: { $0.memberIDs == [botID] }))

    workspace.toggleHidden(conversation)

    XCTAssertFalse(workspace.visibleConversations.contains(where: { $0.id == conversation.id }))
  }

  func testShowHiddenIncludesHiddenDirectConversation() throws {
    let workspace = PreviewWorkspace(seed: false)
    let botID = try workspace.createBot(
      name: "Helper", description: "", color: "green", shape: .circle)
    let conversation = try XCTUnwrap(
      workspace.conversations.first(where: { $0.memberIDs == [botID] }))
    workspace.toggleHidden(conversation)

    workspace.showHidden = true

    XCTAssertTrue(workspace.visibleConversations.contains(where: { $0.id == conversation.id }))
  }

  func testAddRoutinePreservesIntervalAndStartsPaused() throws {
    let workspace = PreviewWorkspace(seed: false)
    let botID = try workspace.createBot(
      name: "Helper", description: "", color: "green", shape: .circle)

    try workspace.addRoutine(name: "  Check status  ", interval: 45)

    let routine = try XCTUnwrap(workspace.routines.first)
    XCTAssertEqual(routine.botID, botID)
    XCTAssertEqual(routine.name, "Check status")
    XCTAssertEqual(routine.intervalMinutes, 45)
    XCTAssertFalse(routine.enabled)
  }

  func testAddRoutineRejectsIntervalsUnderFiveMinutesWithoutMutation() throws {
    let workspace = PreviewWorkspace(seed: false)
    _ = try workspace.createBot(name: "Helper", description: "", color: "green", shape: .circle)
    workspace.panel = .routine

    XCTAssertThrowsError(try workspace.addRoutine(name: "Check status", interval: 4)) {
      XCTAssertEqual($0 as? PreviewError, .invalidInterval)
    }

    XCTAssertTrue(workspace.routines.isEmpty)
    XCTAssertEqual(workspace.panel, .routine)
  }

  func testComposerPolicySubmitsPlainReturn() {
    XCTAssertTrue(
      ComposerInputPolicy.shouldSubmit(isReturn: true, shift: false, hasMarkedText: false))
  }

  func testComposerPolicyDoesNotSubmitShiftReturn() {
    XCTAssertFalse(
      ComposerInputPolicy.shouldSubmit(isReturn: true, shift: true, hasMarkedText: false))
  }

  func testComposerPolicyDoesNotSubmitReturnDuringMarkedTextComposition() {
    XCTAssertFalse(
      ComposerInputPolicy.shouldSubmit(isReturn: true, shift: false, hasMarkedText: true))
  }

  func testComposerPolicyDoesNotSubmitReturnWithOtherModifiers() {
    XCTAssertFalse(
      ComposerInputPolicy.shouldSubmit(
        isReturn: true, shift: false, hasMarkedText: false, otherModifiers: true))
  }

  func testComposerPolicyDoesNotSubmitNonReturnCommands() {
    XCTAssertFalse(
      ComposerInputPolicy.shouldSubmit(isReturn: false, shift: false, hasMarkedText: false))
  }
}
