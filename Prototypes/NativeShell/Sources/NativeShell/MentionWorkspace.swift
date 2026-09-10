import Foundation
import WorkspaceCore

/// Transient consent identity. Raw binding syntax belongs only to the local draft;
/// the command, transcript and provider receive the readable message instead.
struct MentionRoutingSnapshot: Equatable {
  let conversationID: UUID
  let sourceText: String
  let messageText: String
  let members: [GroupMentionMember]

  var targetBotIDs: [UUID] { members.map(\.id) }
}

extension PreviewWorkspace {
  var currentMentionMembers: [GroupMentionMember] {
    guard let current, current.kind == .group else { return [] }
    return current.memberIDs.compactMap { id in
      bots.first(where: { $0.id == id }).map { GroupMentionMember(id: id, name: $0.name) }
    }
  }

  var currentMentionResolution: GroupMentionResolution? {
    guard current?.kind == .group else { return nil }
    return GroupMentions.resolve(draft, members: currentMentionMembers)
  }

  var effectiveTargetBotIDs: [UUID] {
    guard let resolution = currentMentionResolution, resolution.hasMentions else {
      return selectedTargetBotIDsForCurrent
    }
    return resolution.issues.isEmpty ? resolution.targetBotIDs : []
  }

  func captureMentionRouting() throws -> MentionRoutingSnapshot? {
    guard let current, let resolution = currentMentionResolution else { return nil }
    if let issue = resolution.issues.first { throw issue }
    guard resolution.hasMentions else { return nil }
    let members = currentMentionMembers
    let ordered = resolution.targetBotIDs.compactMap { id in members.first { $0.id == id } }
    guard ordered.count == resolution.targetBotIDs.count, !ordered.isEmpty else {
      throw GroupMentionIssue.staleMemberBinding
    }
    return MentionRoutingSnapshot(
      conversationID: current.id, sourceText: draft, messageText: resolution.messageText,
      members: ordered)
  }

  func recipientRoutingMatches(_ mention: MentionRoutingSnapshot?, targetIDs: [UUID]) -> Bool {
    do {
      let currentRouting = try captureMentionRouting()
      if let mention { return currentRouting == mention && mention.targetBotIDs == targetIDs }
      return currentRouting == nil && selectedTargetBotIDsForCurrent == targetIDs
    } catch { return false }
  }

  var canInsertMention: Bool {
    current?.kind == .group && !currentNeedsMembershipRepair && !isLoading && !isClosing
      && !isSubmitting && !isDeletingBot && !isAttachingFiles && !isExporting
      && mentionInsertion == nil && sendTask == nil && attachmentConfirmationTarget == nil
      && pickerMode == .closed && panel == nil && editTarget == nil && botDeletionTarget == nil
      && routineEditTarget == nil && routineDetailTarget == nil
  }

  func requestMentionInsertion(_ botID: UUID) {
    guard canInsertMention, let conversationID = selectedID,
      let member = currentMentionMembers.first(where: { $0.id == botID })
    else { return }
    do {
      mentionInsertion = ComposerInsertion(
        conversationID: conversationID, contextGeneration: replyContextGeneration,
        expectedText: draft, text: try GroupMentions.token(for: member))
    } catch { notice = Self.providerErrorMessage(error) }
  }

  func finishMentionInsertion(_ id: UUID, inserted: Bool) {
    guard mentionInsertion?.id == id else { return }
    mentionInsertion = nil
    if inserted {
      composerFocusRequest += 1
    } else {
      notice = "Mention was not inserted. Finish typing or composing, then choose Mention again."
    }
  }

  func recipientLabel(_ botID: UUID) -> String {
    let name = bots.first(where: { $0.id == botID })?.name ?? "Deleted bot"
    let normalized = name.precomposedStringWithCanonicalMapping
    let otherIdentities = currentMentionMembers.filter {
      $0.id != botID && $0.name.precomposedStringWithCanonicalMapping == normalized
    }.map { $0.id.uuidString.lowercased() }
    guard !otherIdentities.isEmpty else { return name }
    let identity = botID.uuidString.lowercased()
    var length = 8
    while length < identity.count,
      otherIdentities.contains(where: { $0.hasPrefix(identity.prefix(length)) })
    {
      length += 4
    }
    return "\(name) · \(identity.prefix(length))"
  }
}
