import Foundation
import Testing
@testable import StenoUI

/// **Deviation from the task brief.** The brief's version of this file called
/// `Keychain.set`/`.remove` directly against `DeepgramTranscriber.keychainAccount`
/// -- which is the SAME account Angelo's real Deepgram key lives under on this
/// machine (`com.jiggsfoo.steno` / `deepgram-api-key`). Run literally, its first
/// test would have overwritten that real key with `"secret-key"` and then
/// deleted it in the `defer`; its second test deletes it outright to prove
/// `isAvailable()` goes false. The project's own constraints are explicit: a
/// test must never read, write, or delete the real `deepgram-api-key` item, and
/// must use a UUID-suffixed account instead, exactly as `KeychainTests` already
/// does. This file follows that pattern.
///
/// The brief's second test (`removingTheKeyMakesTheCloudBackendUnavailable`) is
/// dropped outright rather than adapted: `DeepgramTranscriber.isAvailable()`
/// always reads `Self.keychainAccount` internally -- that account is not
/// injectable -- so there is no way to exercise it without touching the real
/// item. `DeepgramTranscriberTests.swift` (Task 12) already avoids this same
/// trap for the same reason; this file stays consistent with it.

/// The key must never land in UserDefaults, where anything running as the user
/// can read it and where it ends up in backups as plain text. A UUID-suffixed
/// stand-in account proves the invariant Settings' Keychain field relies on,
/// without ever touching `DeepgramTranscriber.keychainAccount` -- see the file
/// comment above.
@Test func theApiKeyIsNotStoredInUserDefaults() throws {
    let account = "steno-test-settings-\(UUID().uuidString)"
    defer { Keychain.remove(account) }

    try Keychain.set("secret-key", for: account)

    #expect(Keychain.string(for: account) == "secret-key")
    #expect(UserDefaults.standard.string(forKey: account) == nil)
    #expect(UserDefaults.standard.string(forKey: "deepgram") == nil)
}

/// The account NAME is a public constant, not a credential -- reading it does
/// not touch the Keychain at all. Pins that Settings' `SecureField` and
/// `DeepgramTranscriber` still agree on exactly which item the field edits.
@Test func deepgramKeychainAccountIsTheOneSettingsEdits() {
    #expect(DeepgramTranscriber.keychainAccount == "deepgram-api-key")
}

/// The recent-row context menu only ever offers what `TranscriberRegistry.all()`
/// returns -- pinned here so a future backend added to `all()` without a
/// display name doesn't silently render as a blank menu item instead of
/// failing loudly. (There is no Settings picker; re-transcription picks its
/// backend at the point of action.)
@Test func everyRegisteredBackendHasADisplayName() {
    for backend in TranscriberRegistry.all() {
        #expect(!backend.displayName.isEmpty)
        #expect(!backend.id.isEmpty)
    }
}

/// IMPORTANT: the Deepgram key field used to commit on `.onSubmit` (Return)
/// only. Pasting the key and clicking away, tabbing out, or closing Settings
/// silently discarded it while the field kept showing what was typed --
/// since the key gates the entire cloud path, "I pasted it and nothing
/// works" was the likely first experience. `shouldCommitOnFocusChange` is
/// the decision behind the fix: commit when focus is LOST, not gained.
@Test func losingFocusAfterHavingItCommits() {
    #expect(SettingsView.shouldCommitOnFocusChange(wasFocused: true, isFocused: false))
}

/// Gaining focus (clicking INTO the field) must not commit -- there is
/// nothing new to save yet, and it would fire spuriously on every open.
@Test func gainingFocusDoesNotCommit() {
    #expect(!SettingsView.shouldCommitOnFocusChange(wasFocused: false, isFocused: true))
}

/// Neither steady state is a transition, so neither commits.
@Test func steadyFocusStatesDoNotCommit() {
    #expect(!SettingsView.shouldCommitOnFocusChange(wasFocused: true, isFocused: true))
    #expect(!SettingsView.shouldCommitOnFocusChange(wasFocused: false, isFocused: false))
}

/// Closing the window must NOT delete a stored key.
///
/// `Keychain.set("")` short-circuits to `remove`, so an unconditional commit
/// on `.onDisappear` makes closing Settings destructive: if
/// `Keychain.string(for:)` returned nil when the view initialised -- a
/// transient read error, with a key really on disk -- then merely opening and
/// closing Settings would delete a working credential, silently, the only
/// symptom being Deepgram quietly vanishing from the context menu.
///
/// Deliberate clearing is unaffected: it goes through the focus-loss path,
/// where an empty field is something the user typed rather than something the
/// view failed to load.
@Test func closingSettingsWithAnEmptyFieldDoesNotDeleteTheStoredKey() {
    #expect(!SettingsView.shouldCommitOnDisappear(key: ""))
}

@Test func closingSettingsWithAKeyPresentStillSavesIt() {
    #expect(SettingsView.shouldCommitOnDisappear(key: "a-real-key"))
}
