import Foundation
import Security

/// Keeps the Anthropic API key in the iOS Keychain.
enum KeyStore {
  private static let account = "anthropic-api-key"

  private static var query: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Bundle.main.bundleIdentifier ?? "coinspotter",
      kSecAttrAccount as String: account,
    ]
  }

  static func load() -> String {
    var lookup = query
    lookup[kSecReturnData as String] = true
    lookup[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: AnyObject?
    guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data
    else { return "" }
    return String(decoding: data, as: UTF8.self)
  }

  static func save(_ key: String) {
    SecItemDelete(query as CFDictionary)
    guard !key.isEmpty else { return }
    var item = query
    item[kSecValueData as String] = Data(key.utf8)
    // Readable while locked, because detection runs with the phone in a pocket.
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    SecItemAdd(item as CFDictionary, nil)
  }
}
