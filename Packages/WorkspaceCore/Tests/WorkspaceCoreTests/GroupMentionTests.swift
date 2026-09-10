import XCTest

@testable import WorkspaceCore

final class GroupMentionTests: XCTestCase {
  private let alpha = GroupMentionMember(
    id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!, name: "Alpha")
  private let beta = GroupMentionMember(
    id: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!, name: "Beta Bot")

  func testCanonicalTokensRoundTripArbitraryValidNamesAndHideBoundIdentity() throws {
    let names = [
      "Simple", "Full Name", "Quote \" and slash \\", "Line\nBreak", "ผู้ช่วย 🤖",
      String(repeating: "é", count: 80),
    ]

    for (offset, name) in names.enumerated() {
      let member = GroupMentionMember(
        id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", offset + 1))!,
        name: name)
      let token = try GroupMentions.token(for: member)
      let result = GroupMentions.resolve("Ask \(token) now", members: [member])

      XCTAssertEqual(result.targetBotIDs, [member.id])
      XCTAssertTrue(result.issues.isEmpty)
      XCTAssertTrue(result.hasMentions)
      XCTAssertFalse(result.messageText.contains(member.id.uuidString.lowercased()))
      XCTAssertFalse(result.messageText.contains(member.id.uuidString.uppercased()))
      XCTAssertTrue(result.messageText.hasPrefix("Ask @\""))
      XCTAssertTrue(result.messageText.hasSuffix(" now"))
    }
  }

  func testTokenRejectsEmptyAndOverlongNames() {
    XCTAssertThrowsError(try GroupMentions.token(for: .init(id: UUID(), name: ""))) {
      XCTAssertEqual($0 as? GroupMentionIssue, .invalidMemberName)
    }
    XCTAssertThrowsError(
      try GroupMentions.token(for: .init(id: UUID(), name: String(repeating: "a", count: 81)))
    ) {
      XCTAssertEqual($0 as? GroupMentionIssue, .invalidMemberName)
    }
  }

  func testBoundMentionSelectsOneOfDuplicateNames() throws {
    let other = GroupMentionMember(id: UUID(), name: beta.name)
    let token = try GroupMentions.token(for: beta)
    let result = GroupMentions.resolve(token, members: [other, beta])

    XCTAssertEqual(result.targetBotIDs, [beta.id])
    XCTAssertTrue(result.issues.isEmpty)
  }

  func testUnboundDuplicateNameIsAmbiguous() {
    let other = GroupMentionMember(id: UUID(), name: beta.name)
    let result = GroupMentions.resolve("@\"Beta Bot\"", members: [beta, other])

    XCTAssertEqual(result.targetBotIDs, [])
    XCTAssertEqual(result.issues, [.ambiguousMember])
    XCTAssertTrue(result.hasMentions)
  }

  func testDeletedForeignAndRenamedBindingsFailClosed() throws {
    let token = try GroupMentions.token(for: beta)
    let deleted = GroupMentions.resolve(token, members: [alpha])
    let renamed = GroupMentions.resolve(
      token, members: [GroupMentionMember(id: beta.id, name: "Renamed")])

    XCTAssertEqual(deleted.issues, [.staleMemberBinding])
    XCTAssertEqual(renamed.issues, [.staleMemberBinding])
    XCTAssertEqual(deleted.targetBotIDs, [])
    XCTAssertFalse(deleted.messageText.contains(beta.id.uuidString.lowercased()))
  }

  func testFirstOccurrenceOrderDeduplicatesByIdentity() throws {
    let alphaToken = try GroupMentions.token(for: alpha)
    let betaToken = try GroupMentions.token(for: beta)
    let result = GroupMentions.resolve(
      "@\"Beta Bot\" then @Alpha then \(betaToken) and \(alphaToken)",
      members: [alpha, beta])

    XCTAssertEqual(result.targetBotIDs, [beta.id, alpha.id])
    XCTAssertTrue(result.issues.isEmpty)
  }

  func testMoreThanSixUniqueTargetsReportsBoundedIssueAndTargets() {
    let members = (0..<7).map { index in
      GroupMentionMember(id: UUID(), name: "Bot\(index)")
    }
    let result = GroupMentions.resolve(
      members.map { "@\($0.name)" }.joined(separator: " "), members: members)

    XCTAssertEqual(result.targetBotIDs.count, 6)
    XCTAssertEqual(result.issues, [.tooManyTargets(maximum: 6)])
  }

  func testMatchingIsCaseSensitiveButNFCNormalized() {
    let member = GroupMentionMember(id: UUID(), name: "Café")
    let canonicallyEquivalent = GroupMentions.resolve("@Cafe\u{301}", members: [member])
    let wrongCase = GroupMentions.resolve("@CAFÉ", members: [member])

    XCTAssertEqual(canonicallyEquivalent.targetBotIDs, [member.id])
    XCTAssertTrue(canonicallyEquivalent.issues.isEmpty)
    XCTAssertEqual(wrongCase.issues, [.unknownMember])
  }

  func testMalformedAndUnterminatedQuotedMentionsDoNotFallBack() {
    let malformedEscape = GroupMentions.resolve(#"@"Beta\q Bot""#, members: [beta])
    let unterminated = GroupMentions.resolve(#"@"Beta Bot"#, members: [beta])
    let invalidBinding = GroupMentions.resolve(#"@"Beta Bot"{not-a-uuid}"#, members: [beta])
    let invalidTail = GroupMentions.resolve(#"@"Beta Bot"tail"#, members: [beta])

    XCTAssertEqual(malformedEscape.issues, [.invalidQuotedName])
    XCTAssertEqual(unterminated.issues, [.invalidQuotedName])
    XCTAssertEqual(invalidBinding.issues, [.invalidBinding])
    XCTAssertEqual(invalidTail.issues, [.invalidQuotedName])
    XCTAssertTrue(
      [malformedEscape, unterminated, invalidBinding, invalidTail].allSatisfy {
        $0.hasMentions && $0.targetBotIDs.isEmpty
      })
  }

  func testLoneAtAndUnknownSocialHandleAreActionable() {
    let lone = GroupMentions.resolve("hello @", members: [alpha])
    let social = GroupMentions.resolve("hello @Twitter", members: [alpha])

    XCTAssertEqual(lone.issues, [.incompleteMention])
    XCTAssertEqual(social.issues, [.unknownMember])
    XCTAssertTrue(social.issues[0].errorDescription?.contains("\\@") == true)
  }

  func testEmailAndURLSpansAreNotMentions() {
    let text =
      "a@Alpha.test https://host.test/?q=@Alpha http://x/@Alpha mailto:x@Alpha www.x/@Alpha"
    let result = GroupMentions.resolve(text, members: [alpha])

    XCTAssertFalse(result.hasMentions)
    XCTAssertEqual(result.targetBotIDs, [])
    XCTAssertEqual(result.messageText, text)
  }

  func testOddEscapeIsLiteralEvenEscapeRoutesAndOnlyRoutingEscapeIsRemoved() {
    let text = #"literal \@Alpha routed \\@Alpha triple \\\@Alpha"#
    let result = GroupMentions.resolve(text, members: [alpha])

    XCTAssertEqual(result.targetBotIDs, [alpha.id])
    XCTAssertTrue(result.issues.isEmpty)
    XCTAssertEqual(result.messageText, #"literal @Alpha routed \\@Alpha triple \\@Alpha"#)
  }

  func testInlineAndFencedCodeArePreservedAndIgnored() {
    let text = "`@Alpha \\@Alpha` outside @Alpha\n~~~swift\n@Alpha \\@Alpha\n~~~"
    let result = GroupMentions.resolve(text, members: [alpha])

    XCTAssertEqual(result.targetBotIDs, [alpha.id])
    XCTAssertTrue(result.issues.isEmpty)
    XCTAssertEqual(result.messageText, text)
  }

  func testOpeningPunctuationIsBoundaryButEmbeddedHandleIsNot() {
    let result = GroupMentions.resolve("(@Alpha) x@Alpha :@Alpha", members: [alpha])

    XCTAssertEqual(result.targetBotIDs, [alpha.id])
    XCTAssertTrue(result.issues.isEmpty)
  }

  func testCommaSeparatedMentionsPreserveOrderWithoutRequiringSpaces() {
    let result = GroupMentions.resolve(#"@"Beta Bot",@Alpha"#, members: [alpha, beta])
    XCTAssertEqual(result.targetBotIDs, [beta.id, alpha.id])
    XCTAssertTrue(result.issues.isEmpty)
  }

  func testMixedValidAndInvalidMentionsRetainValidTargetsAndIssues() {
    let result = GroupMentions.resolve(
      "@Alpha @Missing @\"Beta Bot\"", members: [alpha, beta])

    XCTAssertEqual(result.targetBotIDs, [alpha.id, beta.id])
    XCTAssertEqual(result.issues, [.unknownMember])
    XCTAssertTrue(result.hasMentions)
  }

  func testLongOrdinaryInputIsPreservedAndLongMentionIsBounded() {
    let ordinary = String(repeating: "ordinary text ", count: 20_000)
    let ordinaryResult = GroupMentions.resolve(ordinary, members: [alpha])
    let longMention = "@" + String(repeating: "a", count: 10_000)
    let mentionResult = GroupMentions.resolve(longMention, members: [alpha])

    XCTAssertFalse(ordinaryResult.hasMentions)
    XCTAssertEqual(ordinaryResult.messageText, ordinary)
    XCTAssertEqual(mentionResult.issues, [.invalidMemberName])
    XCTAssertTrue(mentionResult.targetBotIDs.isEmpty)
  }

  func testLongNonFenceTildeRunRemainsLinearAndDoesNotHideLaterMention() {
    let text = "prefix" + String(repeating: "~", count: 40_000) + " @Alpha"
    let result = GroupMentions.resolve(text, members: [alpha])

    XCTAssertEqual(result.targetBotIDs, [alpha.id])
    XCTAssertEqual(result.messageText, text)
  }

  func testQuotedJSONNameMayExceedSourceLimitWhenDecodedNameIsValid() {
    let family = "👨‍👩‍👧‍👦"
    let name = String(repeating: family, count: 16)
    let escapedFamily = #"\uD83D\uDC68\u200D\uD83D\uDC69\u200D\uD83D\uDC67\u200D\uD83D\uDC66"#
    let member = GroupMentionMember(id: UUID(), name: name)
    let text = "@\"\(String(repeating: escapedFamily, count: 16))\""
    XCTAssertGreaterThan(text.count, 1_024)

    let result = GroupMentions.resolve(text, members: [member])
    XCTAssertEqual(result.targetBotIDs, [member.id])
    XCTAssertTrue(result.issues.isEmpty)
  }

  func testInlineBackticksRequireExactRunLengthAndUnmatchedRunStaysLiteral() {
    let exact = GroupMentions.resolve(
      "`` @Alpha ``` @Beta `` @Alpha", members: [alpha, beta])
    let unmatched = GroupMentions.resolve(
      "` @Alpha then @\"Beta Bot\"", members: [alpha, beta])

    XCTAssertEqual(exact.targetBotIDs, [alpha.id])
    XCTAssertTrue(exact.issues.isEmpty)
    XCTAssertEqual(unmatched.targetBotIDs, [alpha.id, beta.id])
    XCTAssertTrue(unmatched.issues.isEmpty)
  }

  func testUnclosedLineFenceExtendsToEndOfText() {
    let text = "```swift\n@Alpha\n"
    let result = GroupMentions.resolve(text, members: [alpha])

    XCTAssertFalse(result.hasMentions)
    XCTAssertEqual(result.messageText, text)
  }

  func testLexicalEmailFormsDoNotRouteDespitePunctuationBeforeAt() {
    let emails = "o'@Alpha.test !@Alpha.test \"local\"@Alpha.test"
    let text = emails + " (@Alpha)"
    let result = GroupMentions.resolve(text, members: [alpha])

    XCTAssertEqual(result.targetBotIDs, [alpha.id])
    XCTAssertTrue(result.issues.isEmpty)
    XCTAssertEqual(result.messageText, text)
  }

  func testQuotedEmailLocalsWithSpacesOrEscapedQuotesAreNotMentions() {
    for email in [
      #""Full Name"@Alpha.test"#, #""Full \" Name"@Alpha.test"#,
      #""local"@Alpha.test"#, "o'@Alpha.test", "!@Alpha.test",
    ] {
      let result = GroupMentions.resolve(email, members: [alpha])
      XCTAssertFalse(result.hasMentions, email)
      XCTAssertTrue(result.targetBotIDs.isEmpty, email)
      XCTAssertEqual(result.messageText, email)
    }
  }

  func testFenceClosingRequiresWhitespaceTailAndAllowsLongerMatchingMarker() {
    for marker in ["`", "~"] {
      let fence = String(repeating: marker, count: 3)
      let longer = String(repeating: marker, count: 4)
      let text = "\(fence)swift\n@Missing\n\(fence)not-a-close\n@Missing\n\(longer)  \n@Alpha"
      let result = GroupMentions.resolve(text, members: [alpha])
      XCTAssertEqual(result.targetBotIDs, [alpha.id])
      XCTAssertTrue(result.issues.isEmpty)
      XCTAssertEqual(result.messageText, text)
    }
  }

  func testInlineCodeCanCloseAtLineStartWithoutBecomingAnotherFence() {
    let text = "prose ``` @Missing\n```\n@Alpha"
    let result = GroupMentions.resolve(text, members: [alpha])
    XCTAssertEqual(result.targetBotIDs, [alpha.id])
    XCTAssertTrue(result.issues.isEmpty)
  }

  func testUnmatchedInlineOpenerCannotPairWithCodeInsideAFence() {
    for fence in ["```", "~~~"] {
      let text = "`literal\n\(fence)swift\n` code\n@Alpha\n\(fence)"
      let result = GroupMentions.resolve(text, members: [alpha])
      XCTAssertFalse(result.hasMentions)
      XCTAssertTrue(result.targetBotIDs.isEmpty)
      XCTAssertEqual(result.messageText, text)
    }
  }

  func testMalformedBareIdentityBindingNeverFallsBackToUnboundName() {
    for text in ["@Alpha{not-a-uuid}", #"@Alpha"tail""#] {
      let result = GroupMentions.resolve(text, members: [alpha])
      XCTAssertTrue(result.hasMentions)
      XCTAssertFalse(result.issues.isEmpty)
      XCTAssertTrue(result.targetBotIDs.isEmpty)
    }
  }

  func testOddEscapeIsOnlyRemovedAtAMentionBoundary() {
    let embedded = "abc\\@Alpha"
    let boundary = "(\\@Alpha)"

    let embeddedResult = GroupMentions.resolve(embedded, members: [alpha])
    let boundaryResult = GroupMentions.resolve(boundary, members: [alpha])
    XCTAssertFalse(embeddedResult.hasMentions)
    XCTAssertEqual(embeddedResult.messageText, embedded)
    XCTAssertFalse(boundaryResult.hasMentions)
    XCTAssertEqual(boundaryResult.messageText, "(@Alpha)")
  }

  func testCanonicalQuotedTokenSupportsLeadingCombiningMarkAndBareMarkIsInvalid() throws {
    let member = GroupMentionMember(id: UUID(), name: "\u{301}Accent")
    let token = try GroupMentions.token(for: member)
    let quoted = GroupMentions.resolve(token, members: [member])
    let bare = GroupMentions.resolve("@\u{301}", members: [member])

    XCTAssertEqual(quoted.targetBotIDs, [member.id])
    XCTAssertTrue(quoted.issues.isEmpty)
    XCTAssertTrue(bare.hasMentions)
    XCTAssertEqual(bare.targetBotIDs, [])
    XCTAssertEqual(bare.issues, [.invalidMemberName])
  }
}
