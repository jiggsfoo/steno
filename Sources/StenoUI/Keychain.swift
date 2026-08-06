import Foundation
import Security

/// The Deepgram API key. `UserDefaults` is readable by anything running as the
/// user and ends up in backups in plain text; a credential does not belong there.
public enum Keychain {
    private static let service = "com.jiggsfoo.steno"

    public static func string(for account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    /// Update-then-add-on-not-found, never delete-then-add: if the write to
    /// replace an existing key fails partway, delete-then-add would have
    /// already destroyed the working key, silently making the cloud backend
    /// unavailable. `remove(_:)` stays the only way a key is deliberately
    /// destroyed.
    public static func set(_ value: String, for account: String) throws {
        guard !value.isEmpty else {
            remove(account)
            return
        }

        let searchQuery = baseQuery(account: account)
        let updateStatus = SecItemUpdate(
            searchQuery as CFDictionary,
            [kSecValueData as String: Data(value.utf8)] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.writeFailed(updateStatus)
        }

        var addQuery = baseQuery(account: account)
        addQuery[kSecValueData as String] = Data(value.utf8)
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.writeFailed(addStatus) }
    }

    public static func remove(_ account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}

public enum KeychainError: Error, Equatable {
    case writeFailed(OSStatus)
}
