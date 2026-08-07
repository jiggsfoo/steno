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
