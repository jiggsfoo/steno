import Foundation
import Testing
@testable import StenoUI

/// A `UserDefaults` suite nobody else owns.
///
/// Tests MUST NOT touch `UserDefaults.standard` — it is the user's real
/// preference domain, and `AudioPlayer` persists the playback rate there.
private func throwawayDefaults() -> UserDefaults {
    UserDefaults(suiteName: "steno.tests.\(UUID().uuidString)")!
}

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

/// `isPlaying` is a claim the transport button renders directly. With nothing
/// loaded, setting it anyway flipped the icon to Pause over silence — which is
/// exactly what made the reopened-window failure invisible instead of obvious.
/// `stop()` is the reachable way back into that state: `.onDisappear` calls it,
/// and SwiftUI may keep a closed window's `@State` alive.
@MainActor
@Test func playingWithNothingLoadedDoesNotClaimToBePlaying() {
    let player = AudioPlayer()
    #expect(player.isPlaying == false)

    player.play()
    #expect(player.isPlaying == false)

    player.load(URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).m4a"))
    player.play()
    #expect(player.isPlaying)

    player.stop()
    player.play()
    #expect(player.isPlaying == false)
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

/// `AVPlayer.rate` is the speed while playing and 0 while paused — one
/// property with two meanings. `AudioPlayer.rate` is the CHOSEN speed and
/// must survive a pause, or resuming would silently drop back to 1x.
@MainActor
@Test func pausingDoesNotForgetTheChosenSpeed() {
    let player = AudioPlayer(defaults: throwawayDefaults())
    player.setRate(1.5)
    player.pause()

    #expect(player.rate == 1.5)
}

@MainActor
@Test func theChosenSpeedIsWhatGetsAppliedOnPlay() {
    #expect(AudioPlayer.appliedRate(chosen: 1.5, isPlaying: true) == 1.5)
    #expect(AudioPlayer.appliedRate(chosen: 1.5, isPlaying: false) == 0)
}

/// A zero or negative rate is a stopped player, not a speed. Accepting one
/// would make `setRate(0)` indistinguishable from pausing, and the transport
/// would have no way back.
@Test func aRateThatIsNotASpeedIsRefused() {
    #expect(AudioPlayer.clampedRate(0) == 1)
    #expect(AudioPlayer.clampedRate(-2) == 1)
    #expect(AudioPlayer.clampedRate(.nan) == 1)
    #expect(AudioPlayer.clampedRate(.infinity) == 1)
}

@Test func aRealSpeedSurvivesClamping() {
    #expect(AudioPlayer.clampedRate(0.75) == 0.75)
    #expect(AudioPlayer.clampedRate(2) == 2)
}

/// The preference is about how Angelo listens, not about one file, so it
/// outlives the process.
@MainActor
@Test func theChosenSpeedIsRestoredFromDefaults() {
    let defaults = throwawayDefaults()
    AudioPlayer(defaults: defaults).setRate(1.75)

    #expect(AudioPlayer(defaults: defaults).rate == 1.75)
}

@MainActor
@Test func aFreshInstallStartsAtNormalSpeed() {
    #expect(AudioPlayer(defaults: throwawayDefaults()).rate == 1)
}
