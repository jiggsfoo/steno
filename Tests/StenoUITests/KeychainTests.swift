import Foundation
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
