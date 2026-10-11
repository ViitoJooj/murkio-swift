#if canImport(Security)
import Foundation
import Security

/// The Keychain: one generic password per record. An item is readable after
/// the first unlock of the device (so a refresh in the background works) and
/// never leaves it: no iCloud sync, no restore on another phone.
public final class KeychainStorage: MurkioStorage, @unchecked Sendable {
    private let service: String

    public init(service: String = "com.murkio.identity") {
        self.service = service
    }

    private func item(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    public func read(_ key: String) -> String? {
        var query = item(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public func write(_ key: String, _ value: String) {
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(item(key) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var added = item(key)
            added.merge(attributes) { _, new in new }
            SecItemAdd(added as CFDictionary, nil)
        }
    }

    public func delete(_ key: String) {
        SecItemDelete(item(key) as CFDictionary)
    }
}
#endif
