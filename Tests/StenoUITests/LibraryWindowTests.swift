import Foundation
import SwiftUI
import Testing
@testable import StenoUI

private func recording(_ signature: String) -> LoadedRecording {
    LoadedRecording(
        sidecar: Sidecar(signature: signature, deviceFilename: "\(signature).hda",
                         relativePath: "2026-08-05/\(signature).mp3", lengthBytes: 10,
                         durationSeconds: 60,
                         recordedAt: nil,
                         syncedAt: Date(timeIntervalSince1970: 1),
                         deviceSerial: "S", deviceModel: "hidock-p1",
                         timeZoneIdentifier: "Asia/Manila", title: "T", topic: nil),
        transcript: nil)
}

/// The `id` stored inside the first `IDView` found by walking `Mirror`
/// children depth-first, or nil if none is found.
///
/// `Mirror`/`type(of:)` read runtime metadata, which plain Swift access
/// control (`package`, `@usableFromInline`) does not hide. `View.id(_:)` is
/// `@inlinable` and its body is literally `return IDView(self, id: id)` — so
/// this reads the real composition `LibraryWindow.detailContent` builds, not a
/// stand-in for it.
///
/// Verified against **macOS SDK 26.5** (`MacOSX26.5.sdk`, Xcode 26.6 build
/// 17F113, Swift 6.3.3), in SwiftUICore's public
/// `.../SwiftUICore.swiftmodule/arm64e-apple-macos.swiftinterface`: `IDView`
/// is declared at line 18335 and the `.id(_:)` body quoted above is at line
/// 18362. The SDK version is recorded because this is an unsupported
/// implementation detail — when this test starts returning nil, the first
/// thing to check is whether that body still reads the same on whatever SDK
/// is current, which is a one-step diagnosis with the baseline named and a
/// re-derivation without it. Capped at a
/// generous depth rather than recursing unbounded, since `AudioPlayer` is a
/// reference type reachable from `TranscriptPane` and its
/// `ObservationRegistrar` internals are not a shape this test owns.
private func idViewID(in value: Any, depth: Int = 0) -> String? {
    guard depth < 20 else { return nil }
    let mirror = Mirror(reflecting: value)
    if String(describing: type(of: value)).hasPrefix("IDView<") {
        for child in mirror.children where child.label == "id" {
            return child.value as? String
        }
    }
    for child in mirror.children {
        if let found = idViewID(in: child.value, depth: depth + 1) { return found }
    }
    return nil
}

/// The bug this guards: without `.id(recording.id)`, a selection change is
/// an UPDATE to the same `TranscriptPane` identity rather than a new
/// instance, so SwiftUI carries `isFollowing` (and the transcript's scroll
/// position) across recordings — one hand-scroll silently disables
/// auto-scroll for every recording opened afterward. `TranscriptPane`'s own
/// `remainsFollowing` tests cannot see this defect: it lives in how the
/// detail pane composes `TranscriptPane` into the view tree, not in that
/// pure function's truth table.
@MainActor
@Test func selectingARecordingGivesTheDetailPaneAFreshIdentity() {
    let player = AudioPlayer()
    let model = AppModel()
    let content = LibraryWindow.detailContent(
        for: recording("abc123"), player: player,
        query: "", moments: [], capped: false,
        knownTopics: [], model: model, onSaved: {}, onPlay: { _ in })
    #expect(idViewID(in: content) == "abc123")
}

/// `Info.plist` sets `LSUIElement`, so Steno has no Dock icon and no
/// app-switcher entry. That was right while it was menu-bar-only; now that it
/// owns a window, a library window sent behind another app cannot be
/// Command-Tabbed back to at all — the only way back is the menu bar icon and
/// "Library…" again. The ruling is a Dock icon only WHILE that window is open,
/// so a menu-bar utility does not quietly become the wrong kind of app once
/// its one window closes.
///
/// WHAT THIS PROVES AND WHAT IT DOES NOT. It pins the mapping, and only that.
/// It cannot see that `LibraryWindow.body` calls it from `.onAppear` and
/// `.onDisappear` — deleting either call leaves this green (mutation V below)
/// — and it cannot see whether AppKit honours the change, because activation
/// policy is process-global state with no display behind it here. Whether the
/// icon actually appears and goes away is human check 15. This is the whole of
/// the honest headless coverage, written rather than skipped because the
/// mapping is the part that can be got backwards in a way nobody would notice
/// until someone had a permanent Dock icon.
@MainActor
@Test func theLibraryWindowEarnsADockIconOnlyWhileItIsOpen() {
    #expect(LibraryWindow.activationPolicy(isLibraryOpen: true) == .regular)
    #expect(LibraryWindow.activationPolicy(isLibraryOpen: false) == .accessory)
}
