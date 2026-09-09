import Foundation
import XCTest

@testable import WorkspaceCore

final class AttachmentTransmissionTests: XCTestCase {
  func testAttachmentPlanCarriesMetadataNotBytesAndFingerprintBindsRequest() throws {
    let conversationID = UUID()
    let botID = UUID()
    let provider = ProviderConfig(
      name: "Fixture", apiRoot: URL(string: "https://fixture.invalid/v1")!, modelID: "model",
      credentialReference: "reference")
    let content = try AttachmentContent(
      conversationID: conversationID, originalName: "notes.txt", data: Data("hello".utf8))
    var transmitted: Set<UUID> = []
    let user = try AttachmentTransmission.decoratedContent(
      text: "Read", attachmentIDs: [content.attachment.id],
      contents: [content.attachment.id: content], transmitted: &transmitted)
    let turns = [
      ChatTurn(role: "system", content: AttachmentTransmission.systemDisclosure),
      ChatTurn(role: "user", content: user),
    ]
    let fingerprint = AttachmentTransmission.fingerprint(
      provider: provider, conversationID: conversationID, targetBotID: botID, replyToID: nil,
      retryGenerationID: nil, messages: [], turns: turns, attachments: [content.attachment])
    let plan = AttachmentTransmissionPlan(
      conversationID: conversationID, targetBotID: botID, provider: provider,
      attachments: [content.attachment], contextMessageCount: 0,
      requestFingerprint: fingerprint)
    XCTAssertEqual(plan.attachmentBytes, 5)
    XCTAssertEqual(plan.requestFingerprint.count, 64)
    XCTAssertFalse(String(describing: plan).contains("hello"))

    var changed = provider
    changed.modelID = "other"
    XCTAssertNotEqual(
      fingerprint,
      AttachmentTransmission.fingerprint(
        provider: changed, conversationID: conversationID, targetBotID: botID, replyToID: nil,
        retryGenerationID: nil, messages: [], turns: turns, attachments: [content.attachment]))
  }

  func testChatCompletionsWireContainsLabeledPlaintextExactlyOnce() throws {
    let provider = ProviderConfig(
      name: "Fixture", apiRoot: URL(string: "https://fixture.invalid/v1")!, modelID: "model",
      credentialReference: "reference")
    let content = try AttachmentContent(
      conversationID: UUID(), originalName: "wire.txt", data: Data("wire body".utf8))
    var transmitted: Set<UUID> = []
    let first = try AttachmentTransmission.decoratedContent(
      text: "", attachmentIDs: [content.attachment.id],
      contents: [content.attachment.id: content], transmitted: &transmitted)
    let second = try AttachmentTransmission.decoratedContent(
      text: "again", attachmentIDs: [content.attachment.id],
      contents: [content.attachment.id: content], transmitted: &transmitted)
    let request = try ChatCompletionsProvider.makeRequest(
      ChatRequest(
        provider: provider,
        turns: [ChatTurn(role: "user", content: first), ChatTurn(role: "user", content: second)],
        credential: Data("synthetic-key".utf8)))
    let body = try XCTUnwrap(request.httpBody)
    let text = String(decoding: body, as: UTF8.self)
    XCTAssertEqual(text.components(separatedBy: "wire body").count - 1, 1)
    XCTAssertTrue(text.contains("[UNTRUSTED ATTACHMENT REFERENCE]"))
    XCTAssertTrue(text.contains(content.attachment.sha256))
  }

  func testCodexWireUsesInputTextAndNeverToolsForAttachmentBody() throws {
    let auth = try JSONSerialization.data(
      withJSONObject: [
        "auth_mode": "chatgpt",
        "tokens": ["access_token": "synthetic-access", "account_id": "fixture-account"],
      ])
    let credential = try CodexSessionCredential(authFileData: auth).sessionData()
    let provider = ProviderConfig(
      name: "Codex", apiRoot: CodexResponsesProvider.apiRoot, modelID: "fixture-model",
      credentialReference: CodexSessionCredential.makeReference(), kind: .codexResponses)
    let content = try AttachmentContent(
      conversationID: UUID(), originalName: "codex.txt", data: Data("codex wire body".utf8))
    var transmitted: Set<UUID> = []
    let bodyText = try AttachmentTransmission.decoratedContent(
      text: "inspect", attachmentIDs: [content.attachment.id],
      contents: [content.attachment.id: content], transmitted: &transmitted)
    let request = try CodexResponsesProvider.makeRequest(
      ChatRequest(
        provider: provider,
        turns: [
          ChatTurn(role: "system", content: AttachmentTransmission.systemDisclosure),
          ChatTurn(role: "user", content: bodyText),
        ], credential: credential))
    let data = try XCTUnwrap(request.httpBody)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(object["tools"] as? [String], [])
    XCTAssertEqual(object["tool_choice"] as? String, "none")
    let input = try XCTUnwrap(object["input"] as? [[String: Any]])
    let contentArray = try XCTUnwrap(input.first?["content"] as? [[String: String]])
    XCTAssertEqual(contentArray.first?["type"], "input_text")
    XCTAssertTrue(contentArray.first?["text"]?.contains("codex wire body") == true)
    XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("synthetic-access"))
  }
}
