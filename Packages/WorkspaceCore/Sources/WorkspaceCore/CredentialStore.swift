import Foundation
import Security

public protocol CredentialStore: Sendable {
  func read(_ reference: String) async throws -> Data
  func write(_ secret: Data, for reference: String) async throws
  func remove(_ reference: String) async throws
}

/// Actor keeps blocking SecItem calls off the MainActor. Every query is scoped to this app's service/account.
public actor KeychainCredentialStore: CredentialStore {
  private let service: String
  public init(service: String = "local.independent.BotWorkspace.providers") {
    self.service = service
  }
  private func query(_ reference: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: reference, kSecAttrSynchronizable as String: false,
      kSecUseDataProtectionKeychain as String: true,
    ]
  }
  public func read(_ reference: String) throws -> Data {
    var attributes = query(reference)
    attributes[kSecReturnData as String] = true
    attributes[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(attributes as CFDictionary, &item)
    if status == errSecItemNotFound { throw ProviderError.missingCredential }
    guard status == errSecSuccess, let data = item as? Data else {
      throw ProviderError.keychain(status)
    }
    return data
  }
  public func write(_ secret: Data, for reference: String) throws {
    guard !secret.isEmpty else { throw ProviderError.invalidCredential }
    let attributes = query(reference)
    let status = SecItemUpdate(
      attributes as CFDictionary, [kSecValueData as String: secret] as CFDictionary)
    if status == errSecItemNotFound {
      var added = attributes
      added[kSecValueData as String] = secret
      added[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
      let result = SecItemAdd(added as CFDictionary, nil)
      guard result == errSecSuccess else { throw ProviderError.keychain(result) }
    } else if status != errSecSuccess {
      throw ProviderError.keychain(status)
    }
  }
  public func remove(_ reference: String) throws {
    let status = SecItemDelete(query(reference) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw ProviderError.keychain(status)
    }
  }
}
