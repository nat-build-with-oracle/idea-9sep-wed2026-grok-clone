import Foundation
import XCTest

@testable import WorkspaceCore

final class CodexProviderTests: XCTestCase {
  private func auth(_ fields: [String: Any]? = nil) throws -> Data {
    try JSONSerialization.data(
      withJSONObject: fields ?? [
        "auth_mode": "chatgpt",
        "tokens": [
          "access_token": "synthetic-access", "account_id": "fixture-account",
          "refresh_token": "never-retain-refresh", "id_token": "never-retain-id",
        ],
      ])
  }
  private func config() -> ProviderConfig {
    ProviderConfig(
      name: "Codex fixture", apiRoot: CodexResponsesProvider.apiRoot,
      modelID: "fixture-model", credentialReference: CodexSessionCredential.makeReference(),
      kind: .codexResponses)
  }
  private func request(_ provider: ProviderConfig? = nil) throws -> ChatRequest {
    ChatRequest(
      provider: provider ?? config(),
      turns: [
        ChatTurn(role: "system", content: "Be concise"), ChatTurn(role: "user", content: "Hello"),
        ChatTurn(role: "assistant", content: "Hi"), ChatTurn(role: "user", content: "Continue"),
      ],
      credential: try CodexSessionCredential(authFileData: auth()).sessionData())
  }

  func testImportRetainsOnlyAccessAndAccountWithRedactedDescriptions() throws {
    let credential = try CodexSessionCredential(authFileData: auth())
    let data = try credential.sessionData()
    let text = try XCTUnwrap(String(data: data, encoding: .utf8))
    XCTAssertFalse(text.contains("never-retain"))
    XCTAssertFalse(text.contains("auth_mode"))
    XCTAssertFalse(String(describing: credential).contains("synthetic-access"))
    XCTAssertFalse(String(reflecting: credential).contains("fixture-account"))
    let decoded = try CodexSessionCredential(sessionData: data)
    XCTAssertEqual(decoded.accessToken, "synthetic-access")
    XCTAssertEqual(decoded.accountID, "fixture-account")
  }

  func testImportAcceptsMissingOptionalAccountOnlyInChatGPTMode() throws {
    let credential = try CodexSessionCredential(
      authFileData: auth([
        "auth_mode": "chatgpt", "tokens": ["access_token": "synthetic-access"],
      ]))
    XCTAssertNil(credential.accountID)
    for fields: [String: Any] in [
      [:], ["auth_mode": "apikey", "tokens": ["access_token": "fixture"]],
      ["auth_mode": "chatgpt", "OPENAI_API_KEY": "fixture"],
      ["auth_mode": "chatgpt", "tokens": ["access_token": "fixture", "account_id": 42]],
    ] {
      XCTAssertThrowsError(try CodexSessionCredential(authFileData: auth(fields))) {
        XCTAssertEqual($0 as? ProviderError, .invalidCodexLogin)
      }
    }
  }

  func testImportRejectsOversizeMalformedAndHeaderInjection() throws {
    for data in [Data(), Data("not-json".utf8), Data(repeating: 32, count: 1_048_577)] {
      XCTAssertThrowsError(try CodexSessionCredential(authFileData: data))
    }
    for field in ["access_token", "account_id"] {
      for value in [
        "", "line\nnext", "line\rnext", "space value", "\0", "é", "\u{7f}",
        String(repeating: "x", count: 16_385),
      ] {
        var tokens = ["access_token": "fixture", "account_id": "fixture"]
        tokens[field] = value
        XCTAssertThrowsError(
          try CodexSessionCredential(
            authFileData: auth(["auth_mode": "chatgpt", "tokens": tokens])))
      }
    }
  }

  func testRawAuthAndUnknownFieldsAreNotSessionEnvelopes() throws {
    XCTAssertThrowsError(try CodexSessionCredential(sessionData: auth()))
    var fields = try XCTUnwrap(
      JSONSerialization.jsonObject(with: request().credential) as? [String: String])
    fields["refreshToken"] = "fixture"
    XCTAssertThrowsError(
      try CodexSessionCredential(sessionData: JSONSerialization.data(withJSONObject: fields)))
  }

  func testLegacyMetadataDefaultsKindAndRejectsUnknownKind() throws {
    let original = ProviderConfig(
      name: "Legacy", apiRoot: URL(string: "https://example.test/v1")!,
      modelID: "model", credentialReference: "provider-legacy")
    var fields = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
    fields.removeValue(forKey: "kind")
    let oldData = try JSONSerialization.data(withJSONObject: fields)
    XCTAssertEqual(try JSONDecoder().decode(ProviderConfig.self, from: oldData), original)
    fields["kind"] = "unknown-adapter"
    XCTAssertThrowsError(
      try JSONDecoder().decode(
        ProviderConfig.self, from: JSONSerialization.data(withJSONObject: fields)))
    XCTAssertEqual(
      try JSONDecoder().decode(ProviderConfig.self, from: JSONEncoder().encode(config())).kind,
      .codexResponses)
  }

  func testDestinationAndCredentialNamespaceCannotBeRepurposed() throws {
    for root in [
      "https://example.test", "http://chatgpt.com/backend-api/codex",
      "https://chatgpt.com/backend-api/codex/", "https://chatgpt.com:443/backend-api/codex",
      "https://user@chatgpt.com/backend-api/codex", "https://chatgpt.com/backend-api/codex?x=1",
      "https://chatgpt.com/backend-api/codex#fragment",
      "https://chatgpt.com/backend-api/codex/responses",
    ] {
      var value = config()
      value.apiRoot = URL(string: root)!
      XCTAssertThrowsError(try ProviderRouter.makeRequest(request(value)))
    }
    var value = config()
    value.allowsLoopbackHTTP = true
    XCTAssertThrowsError(try ProviderRouter.makeRequest(request(value)))
    value = config()
    value.credentialReference = CredentialLifetime.session.makeReference()
    XCTAssertThrowsError(try ProviderRouter.makeRequest(request(value)))
    value = config()
    value.kind = .chatCompletions
    XCTAssertThrowsError(try ProviderRouter.makeRequest(request(value)))
    value.apiRoot = URL(string: "https://example.test/v1")!
    XCTAssertThrowsError(try ProviderRouter.makeRequest(request(value)))
    XCTAssertThrowsError(try ChatCompletionsProvider.makeRequest(request()))
  }

  func testWireRequestDisablesToolsAndKeepsCredentialOutOfBody() throws {
    let result = try CodexResponsesProvider.makeRequest(request())
    let data = try XCTUnwrap(result.httpBody)
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(result.url, CodexResponsesProvider.endpoint)
    XCTAssertEqual(result.httpMethod, "POST")
    XCTAssertEqual(result.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-access")
    XCTAssertEqual(result.value(forHTTPHeaderField: "ChatGPT-Account-ID"), "fixture-account")
    XCTAssertEqual(result.value(forHTTPHeaderField: "originator"), "botworkspace")
    XCTAssertEqual(result.value(forHTTPHeaderField: "User-Agent"), "BotWorkspace/0.1")
    XCTAssertEqual(body["tools"] as? [String], [])
    XCTAssertEqual(body["tool_choice"] as? String, "none")
    XCTAssertEqual(body["parallel_tool_calls"] as? Bool, false)
    XCTAssertEqual(body["store"] as? Bool, false)
    XCTAssertEqual(body["stream"] as? Bool, true)
    XCTAssertEqual(body["model"] as? String, "fixture-model")
    XCTAssertEqual(body["instructions"] as? String, "Be concise")
    let messages = try XCTUnwrap(body["input"] as? [[String: Any]])
    XCTAssertEqual(messages.compactMap { $0["role"] as? String }, ["user", "assistant", "user"])
    let assistant = try XCTUnwrap(messages[1]["content"] as? [[String: String]])
    XCTAssertEqual(assistant, [["type": "output_text", "text": "Hi"]])
    XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("synthetic-access"))
    XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("fixture-account"))
  }

  func testCodexSessionNeverTouchesPersistentStoreAndExpires() async throws {
    let persistent = CodexRejectingCredentials()
    let store = SessionAwareCredentialStore(persistent: persistent)
    let reference = CodexSessionCredential.makeReference()
    let data = try request().credential
    XCTAssertEqual(CredentialLifetime.forReference(reference), .session)
    try await store.write(data, for: reference)
    let found = try await store.read(reference)
    XCTAssertEqual(found, data)
    let reopened = SessionAwareCredentialStore(persistent: persistent)
    do {
      _ = try await reopened.read(reference)
      XCTFail("Must expire")
    } catch { XCTAssertEqual(error as? ProviderError, .codexLoginRequired) }
    try await store.remove(reference)
    do {
      _ = try await store.read(reference)
      XCTFail("Must be removed")
    } catch { XCTAssertEqual(error as? ProviderError, .codexLoginRequired) }
    let calls = await persistent.calls
    XCTAssertEqual(calls, 0)
  }

  func testProtectedStoreRejectsCodexReferenceBeforeKeychainAccess() async throws {
    let store = KeychainCredentialStore(service: "local.independent.fixture-never-accessed")
    let reference = CodexSessionCredential.makeReference()
    do {
      try await store.write(Data("fixture".utf8), for: reference)
      XCTFail("Must reject")
    } catch { XCTAssertEqual(error as? ProviderError, .invalidCodexLogin) }
    do {
      _ = try await store.read(reference)
      XCTFail("Must reject")
    } catch { XCTAssertEqual(error as? ProviderError, .codexLoginRequired) }
    try await store.remove(reference)
  }
}

private actor CodexRejectingCredentials: CredentialStore {
  private(set) var calls = 0
  func read(_ reference: String) throws -> Data {
    calls += 1
    throw ProviderError.keychain(-34018)
  }
  func write(_ secret: Data, for reference: String) throws {
    calls += 1
    throw ProviderError.keychain(-34018)
  }
  func remove(_ reference: String) throws {
    calls += 1
    throw ProviderError.keychain(-34018)
  }
}
