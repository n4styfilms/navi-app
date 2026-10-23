import Foundation
import Security

/// A local, device-only Keychain item; never synchronized or placed in app resources.
enum NaviMapKeyStore {
  private static var query: [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.navi.private.basemap",
     kSecAttrAccount as String: "esri", kSecAttrSynchronizable as String: false]
  }
  static func read() throws -> String {
    var search = query
    search[kSecReturnData as String] = true
    search[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(search as CFDictionary, &result)
    if status == errSecItemNotFound { return "" }
    guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8)
      else { throw failure() }
    return key
  }
  static func save(_ key: String) throws {
    if key.isEmpty {
      let status = SecItemDelete(query as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else { throw failure() }
      return
    }
    let attributes = [kSecValueData as String: Data(key.utf8)]
    let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      var item = query
      item[kSecValueData as String] = Data(key.utf8)
      item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw failure() }
    } else if status != errSecSuccess { throw failure() }
  }
  private static func failure() -> NSError {
    NSError(domain: "NaviMapKey", code: 1, userInfo: [NSLocalizedDescriptionKey: "Map access could not be saved or read."])
  }
}
