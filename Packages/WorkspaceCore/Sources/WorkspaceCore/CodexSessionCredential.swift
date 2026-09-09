import Foundation

/// A deliberately non-Codable value. Only these fields survive explicit auth-file parsing.
/// Never log this value, persist its session envelope, or retain the source auth JSON.
public struct CodexSessionCredential: Sendable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public static let maximumFileBytes = 1_048_576
  private static let prefix = "session-codex-"
  private static let envelopeKind = "BotWorkspace.codex-session.v1"
  let accessToken: String
  let accountID: String?
  public var description: String { "CodexSessionCredential(redacted)" }
  public var debugDescription: String { description }

  public init(authFileData: Data) throws {
    guard !authFileData.isEmpty, authFileData.count <= Self.maximumFileBytes,
      let root = try? JSONSerialization.jsonObject(with: authFileData) as? [String: Any],
      root["auth_mode"] as? String == "chatgpt",
      let tokens = root["tokens"] as? [String: Any],
      let token = tokens["access_token"] as? String
    else { throw ProviderError.invalidCodexLogin }
    let account: String?
    if let value = tokens["account_id"], !(value is NSNull) {
      guard let string = value as? String else { throw ProviderError.invalidCodexLogin }
      account = string
    } else {
      account = nil
    }
    try self.init(accessToken: token, accountID: account)
  }

  private init(accessToken: String, accountID: String?) throws {
    guard Self.headerSafe(accessToken, limit: 16_384),
      accountID.map({ Self.headerSafe($0, limit: 512) }) ?? true
    else { throw ProviderError.invalidCodexLogin }
    self.accessToken = accessToken
    self.accountID = accountID
  }

  public static func isReference(_ reference: String) -> Bool { reference.hasPrefix(prefix) }
  public static func makeReference() -> String { prefix + UUID().uuidString }

  /// For SessionAwareCredentialStore only; this is not an auth.json copy or disk format.
  public func sessionData() throws -> Data {
    var fields = ["kind": Self.envelopeKind, "accessToken": accessToken]
    if let accountID { fields["accountID"] = accountID }
    return try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
  }

  init(sessionData: Data) throws {
    guard sessionData.count <= 32_768,
      let fields = try? JSONSerialization.jsonObject(with: sessionData) as? [String: String],
      fields["kind"] == Self.envelopeKind,
      Set(fields.keys).isSubset(of: ["kind", "accessToken", "accountID"]),
      let token = fields["accessToken"]
    else { throw ProviderError.invalidCodexLogin }
    try self.init(accessToken: token, accountID: fields["accountID"])
  }

  private static func headerSafe(_ value: String, limit: Int) -> Bool {
    !value.isEmpty && value.utf8.count <= limit && value.utf8.allSatisfy { (33...126).contains($0) }
  }
}
