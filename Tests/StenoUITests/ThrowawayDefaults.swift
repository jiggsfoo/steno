import Foundation

/// A `UserDefaults` that never reaches disk.
///
/// Tests MUST NOT touch `UserDefaults.standard` -- it is the user's real
/// preference domain, and `AudioPlayer` persists the playback rate there.
///
/// The obvious substitute is not one, and this is the whole reason this type
/// exists rather than a one-line `UserDefaults(suiteName:)` helper. A suite is
/// backed by a real `~/Library/Preferences/<name>.plist`, and cfprefsd owns
/// that file rather than the test process. Measured here, in order:
///
/// - no cleanup at all: 3 new `steno.tests.<UUID>.plist` files per
///   `swift test`, unbounded (the whole-branch review counted 108);
/// - `removePersistentDomain(forName:)` in `deinit` -- the pattern
///   `LegacyMigrationTests.Fixture` uses: 3 files per run still, now 42 bytes
///   of empty dictionary each. It empties the domain; it does not delete the
///   file;
/// - `removePersistentDomain` + `CFPreferencesAppSynchronize` + deleting the
///   file: 0 files the instant the run ends, and 3 again three seconds later.
///   The daemon writes the domain back out after the process exits, so no
///   in-process cleanup can win that race.
///
/// (That third measurement is why `LegacyMigrationTests` has quietly leaked
/// **4,022** `LegacyMigrationTests.*.plist` files into the same folder while
/// appearing to clean up after itself. Same defect, different prefix, not
/// touched here.)
///
/// So there is no suite, and nothing to clean up: the storage is a dictionary
/// that goes away with the object. Every accessor `AudioPlayer` reaches for is
/// overridden, including the typed `set(_ value: Double, forKey:)` -- that one
/// is `setDouble:forKey:`, a different selector from `set(_:forKey:)`, and
/// leaving it alone would send `AudioPlayer`'s own write straight past this
/// storage into the real domain this type exists to protect.
///
/// A plain `var` needs no lock around it: Swift Testing runs test functions in
/// parallel but builds a fresh suite-type instance for each one, so no two
/// tests ever share a `ThrowawayDefaults`, and within a test every access is
/// on the main actor. That is also why this is a per-test object rather than a
/// shared one -- a single instance would be exactly the shared mutable state
/// this note says does not exist.
final class ThrowawayDefaults: UserDefaults {
    private var storage: [String: Any] = [:]

    override func set(_ value: Any?, forKey defaultName: String) {
        storage[defaultName] = value
    }

    override func set(_ value: Double, forKey defaultName: String) {
        set(value as Any?, forKey: defaultName)
    }

    override func set(_ value: Int, forKey defaultName: String) {
        set(value as Any?, forKey: defaultName)
    }

    override func set(_ value: Bool, forKey defaultName: String) {
        set(value as Any?, forKey: defaultName)
    }

    override func set(_ value: Float, forKey defaultName: String) {
        set(value as Any?, forKey: defaultName)
    }

    override func removeObject(forKey defaultName: String) {
        storage[defaultName] = nil
    }

    override func object(forKey defaultName: String) -> Any? {
        storage[defaultName]
    }

    /// Zero for a missing key, matching `UserDefaults`' own contract -- which
    /// `AudioPlayer.init` relies on to treat a fresh install and a corrupt
    /// value as the same safe case.
    override func double(forKey defaultName: String) -> Double {
        object(forKey: defaultName) as? Double ?? 0
    }
}
