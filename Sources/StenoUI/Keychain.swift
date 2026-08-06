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

    public static func set(_ value: String, for account: String) throws {
        remove(account)
        guard !value.isEmpty else { return }
        var query = baseQuery(account: account)
        query[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.writeFailed(status) }
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
