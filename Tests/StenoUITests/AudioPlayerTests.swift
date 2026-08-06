import Foundation
import Testing
@testable import StenoUI

private let segments = [
    Segment(start: 0, end: 10, text: "first", speaker: nil),
    Segment(start: 10, end: 20, text: "second", speaker: nil),
    Segment(start: 25, end: 30, text: "third after a gap", speaker: nil),
]

@Test func theSegmentContainingTheCurrentTimeIsTheCurrentOne() {
    #expect(AudioPlayer.currentSegmentIndex(at: 5, in: segments) == 0)
    #expect(AudioPlayer.currentSegmentIndex(at: 15, in: segments) == 1)
    #expect(AudioPlayer.currentSegmentIndex(at: 27, in: segments) == 2)
}

/// A segment owns its start instant. Without this, seeking to a line's own
/// start would highlight the line before it.
@Test func aSegmentsOwnStartBelongsToIt() {
    #expect(AudioPlayer.currentSegmentIndex(at: 10, in: segments) == 1)
    #expect(AudioPlayer.currentSegmentIndex(at: 25, in: segments) == 2)
}

/// Silence between segments must not highlight anything, or the highlight
/// lingers on a line nobody is speaking.
@Test func timeInAGapHighlightsNothing() {
    #expect(AudioPlayer.currentSegmentIndex(at: 22, in: segments) == nil)
}

@Test func timeBeforeOrAfterEverythingHighlightsNothing() {
    #expect(AudioPlayer.currentSegmentIndex(at: -1, in: segments) == nil)
    #expect(AudioPlayer.currentSegmentIndex(at: 999, in: segments) == nil)
}

@Test func anEmptyTranscriptHasNoCurrentSegment() {
    #expect(AudioPlayer.currentSegmentIndex(at: 5, in: []) == nil)
}

/// The bug this guards: a moment's "play" action seeks and plays, then sets
/// `store.selection`, which the window's own `.onChange(of: store.selection)`
/// reacts to with a *second* `load` for the same file. Without the guard,
/// that second load tears the player down and resets `currentTime` to 0,
/// silently undoing the seek. Needs no real audio file and no waiting for
/// `.readyToPlay`: `seek(to:)` sets `currentTime` synchronously, and a load
/// that actually proceeds resets it to 0 synchronously too — so whether the
/// guard held is observable without any asynchronous state at all.
@MainActor
@Test func aSecondLoadForTheSameURLDoesNotResetPlayback() {
    let player = AudioPlayer()
    let url = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).m4a")
    player.load(url)
    player.seek(to: 5)
    player.load(url)
    #expect(player.currentTime == 5)
}

/// The guard above must not be permanent: a load that never becomes
/// playable (missing file, unsupported format, ...) has to be retryable,
/// not wedged as "loaded" forever. Detecting the failure is inherently
/// asynchronous — AVFoundation has to actually attempt, and fail, to open
/// the file — so this polls with a generous bound instead of assuming a
/// fixed delay is enough. Still no real audio file, no hardware, and no
/// wait for `.readyToPlay`: only for the item to reach `.failed`.
@MainActor
@Test func aFailedLoadCanBeRetried() async throws {
    let player = AudioPlayer()
    let url = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).m4a")
    player.load(url)
    player.seek(to: 5)

    var recovered = false
    for _ in 0..<100 {
        try await Task.sleep(for: .milliseconds(20))
        player.load(url)
        // A load that actually proceeds (rather than being guarded away)
        // always zeroes currentTime — seeing that happen again is proof
        // the earlier failure freed `loadedURL` for a real retry.
        if player.currentTime == 0 {
            recovered = true
            break
        }
    }
    #expect(recovered)
}
