import Foundation
import XCTest

@testable import WorkspaceCore

final class ProviderSetupTests: XCTestCase {
  func testPresetEndpointsResolveWithoutDuplicatingPath() throws {
    for preset in ProviderPreset.allCases {
      let config = ProviderConfig(
        name: preset.name, apiRoot: try XCTUnwrap(URL(string: preset.apiRoot)),
        modelID: "fixture-model", credentialReference: "fixture-reference",
        allowsLoopbackHTTP: preset == .nineRouter)
      XCTAssertEqual(
        try ProviderEndpoint.chatCompletions(config).absoluteString,
        preset.apiRoot + "/chat/completions")
    }
  }

  func testLocalRouterRequiresExplicitHTTPOptIn() throws {
    let config = ProviderConfig(
      name: "9router", apiRoot: try XCTUnwrap(URL(string: ProviderPreset.nineRouter.apiRoot)),
      modelID: "cx/fixture-model", credentialReference: "fixture-reference")
    XCTAssertThrowsError(try ProviderEndpoint.chatCompletions(config)) {
      XCTAssertEqual($0 as? WorkspaceError, .invalidProvider)
    }
    XCTAssertTrue(ProviderPreset.nineRouter.suggestedModel.isEmpty)
  }

  func testPresetsDistinguishGeneralAPIFromSubscriptionCredentials() {
    XCTAssertEqual(ProviderPreset.zai.apiRoot, "https://api.z.ai/api/paas/v4")
    XCTAssertFalse(ProviderPreset.zai.apiRoot.contains("coding"))
    XCTAssertEqual(ProviderPreset.zai.suggestedModel, "glm-5.3")
    XCTAssertTrue(ProviderPreset.zai.guidance.contains("does not use Coding Plan"))
    XCTAssertTrue(ProviderPreset.openAI.guidance.contains("not a ChatGPT subscription"))
    XCTAssertTrue(ProviderPreset.nineRouter.guidance.contains("router API key"))
  }

  func testCredentialReferencesAreUniqueAndPreserveLegacyKeychainRouting() {
    let first = CredentialLifetime.session.makeReference()
    XCTAssertNotEqual(first, CredentialLifetime.session.makeReference())
    XCTAssertEqual(CredentialLifetime.forReference(first), .session)
    XCTAssertEqual(
      CredentialLifetime.forReference(CredentialLifetime.keychain.makeReference()), .keychain)
    XCTAssertEqual(CredentialLifetime.forReference("provider-existing-v1"), .keychain)
  }

  func testSessionOperationsNeverTouchPersistentStore() async throws {
    let persistent = RejectingPersistentCredentials()
    let store = SessionAwareCredentialStore(persistent: persistent)
    let reference = CredentialLifetime.session.makeReference()
    let secret = Data("synthetic-session-value".utf8)
    try await store.write(secret, for: reference)
    let found = try await store.read(reference)
    XCTAssertEqual(found, secret)
    try await store.remove(reference)
    try await store.remove(reference)
    do {
      _ = try await store.read(reference)
      XCTFail("Removed session key should not exist")
    } catch { XCTAssertEqual(error as? ProviderError, .missingCredential) }
    let calls = await persistent.calls
    XCTAssertEqual(calls, 0)
  }

  func testNewStoreCannotRecoverPriorSessionKey() async throws {
    let persistent = RejectingPersistentCredentials()
    let reference = CredentialLifetime.session.makeReference()
    let first = SessionAwareCredentialStore(persistent: persistent)
    try await first.write(Data("fixture-secret".utf8), for: reference)
    let reopened = SessionAwareCredentialStore(persistent: persistent)
    do {
      _ = try await reopened.read(reference)
      XCTFail("Session keys must not survive a new store")
    } catch { XCTAssertEqual(error as? ProviderError, .missingCredential) }
    let calls = await persistent.calls
    XCTAssertEqual(calls, 0)
  }

  func testKeychainFailureNeverFallsBackToMemory() async throws {
    let persistent = RejectingPersistentCredentials()
    let store = SessionAwareCredentialStore(persistent: persistent)
    let reference = CredentialLifetime.keychain.makeReference()
    do {
      try await store.write(Data("fixture-secret".utf8), for: reference)
      XCTFail("Keychain failure should remain visible")
    } catch { XCTAssertEqual(error as? ProviderError, .keychain(-34018)) }
    do {
      _ = try await store.read(reference)
      XCTFail("Failed write must not create an in-memory key")
    } catch { XCTAssertEqual(error as? ProviderError, .keychain(-34018)) }
    let calls = await persistent.calls
    XCTAssertEqual(calls, 2)
  }

  func testEmptySessionCredentialIsRejected() async throws {
    let store = SessionAwareCredentialStore(persistent: RejectingPersistentCredentials())
    do {
      try await store.write(Data(), for: CredentialLifetime.session.makeReference())
      XCTFail("Empty credential should fail")
    } catch { XCTAssertEqual(error as? ProviderError, .invalidCredential) }
  }
}

private actor RejectingPersistentCredentials: CredentialStore {
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
