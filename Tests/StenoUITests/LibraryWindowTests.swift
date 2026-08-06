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
/// `@inlinable` and its body is literally `return IDView(self, id: id)`
/// (SwiftUICore's public `.swiftinterface`, confirmed on this SDK at
/// `SwiftUICore.framework/.../arm64e-apple-macos.swiftinterface` near its
/// `IDView` declaration) — so this reads the real composition
/// `LibraryWindow.detailContent` builds, not a stand-in for it. Capped at a
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
        knownTopics: [], model: model, onPlay: { _ in })
    #expect(idViewID(in: content) == "abc123")
}
