import Foundation
import Security
import Testing
@testable import StenoUI

/// `UserDefaults` is readable by anything running as the user and ends up in
/// backups in plain text; a credential must never land there.
@Test func keychainRoundTripsAValueAndNeverTouchesUserDefaults() throws {
    let account = "steno-test-\(UUID().uuidString)"
    defer { Keychain.remove(account) }

    #expect(Keychain.string(for: account) == nil)

    try Keychain.set("a-test-value", for: account)

    #expect(Keychain.string(for: account) == "a-test-value")
    #expect(UserDefaults.standard.string(forKey: account) == nil)
    #expect(UserDefaults.standard.object(forKey: account) == nil)
}

@Test func removingAnAbsentAccountIsANoOp() {
    Keychain.remove("steno-test-absent-\(UUID().uuidString)")
}

@Test func settingAnEmptyValueRemovesAnyExistingSecret() throws {
    let account = "steno-test-\(UUID().uuidString)"
    defer { Keychain.remove(account) }
    try Keychain.set("something", for: account)

    try Keychain.set("", for: account)

    #expect(Keychain.string(for: account) == nil)
}

/// `set` must update the existing item rather than delete-then-add, so a
/// failed second write can never destroy a working key. Provoking a real
/// `SecItemAdd` failure isn't reliably reproducible in a test, so this
/// proves the update path directly: the second value wins, and exactly one
/// item exists afterward — never two.
@Test func settingAValueTwiceUpdatesInPlaceRatherThanDuplicating() throws {
    let account = "steno-test-\(UUID().uuidString)"
    defer { Keychain.remove(account) }

    try Keychain.set("first-value", for: account)
    try Keychain.set("second-value", for: account)

    #expect(Keychain.string(for: account) == "second-value")

    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.jiggsfoo.steno",
        kSecAttrAccount as String: account,
        kSecMatchLimit as String: kSecMatchLimitAll,
        kSecReturnAttributes as String: true,
    ]
    var items: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &items)

    #expect(status == errSecSuccess)
    #expect((items as? [[String: Any]])?.count == 1)
}
