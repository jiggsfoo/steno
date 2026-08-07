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

/// Everything that needs a real `AudioPlayer`, and therefore a real
/// `UserDefaults` suite to persist the playback rate into.
///
/// A class rather than free functions so one `ThrowawayDefaults` is shared by
/// the tests that need a value to survive a second player, and so its lifetime
/// is the test's rather than ARC's guess about a local. `ThrowawayDefaults`
/// explains why it is not a `UserDefaults(suiteName:)`: that leaks a file into
/// the user's Preferences folder that no in-process cleanup can remove.
@MainActor
@Suite final class PlayerWithItsOwnDefaults {
    private let defaults = ThrowawayDefaults()

    /// A player on this test's own storage. Called twice where the point is
    /// that the preference outlives one player -- see
    /// `theChosenSpeedIsRestoredFromDefaults`.
    private func player() -> AudioPlayer { AudioPlayer(defaults: defaults) }

    /// The bug this guards: a moment's "play" action seeks and plays, then sets
    /// `store.selection`, which the window's own `.onChange(of: store.selection)`
    /// reacts to with a *second* `load` for the same file. Without the guard,
    /// that second load tears the player down and resets `currentTime` to 0,
    /// silently undoing the seek. Needs no real audio file and no waiting for
    /// `.readyToPlay`: `seek(to:)` sets `currentTime` synchronously, and a load
    /// that actually proceeds resets it to 0 synchronously too -- so whether the
    /// guard held is observable without any asynchronous state at all.
    @Test func aSecondLoadForTheSameURLDoesNotResetPlayback() {
        let player = player()
        let url = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).m4a")
        player.load(url)
        player.seek(to: 5)
        player.load(url)
        #expect(player.currentTime == 5)
    }

    /// `isPlaying` is a claim the transport button renders directly. With nothing
    /// loaded, setting it anyway flipped the icon to Pause over silence -- which is
    /// exactly what made the reopened-window failure invisible instead of obvious.
    /// `stop()` is the reachable way back into that state: `.onDisappear` calls it,
    /// and SwiftUI may keep a closed window's `@State` alive.
    @Test func playingWithNothingLoadedDoesNotClaimToBePlaying() {
        let player = player()
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
    /// asynchronous -- AVFoundation has to actually attempt, and fail, to open
    /// the file -- so this polls with a generous bound instead of assuming a
    /// fixed delay is enough. Still no real audio file, no hardware, and no
    /// wait for `.readyToPlay`: only for the item to reach `.failed`.
    @Test func aFailedLoadCanBeRetried() async throws {
        let player = player()
        let url = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).m4a")
        player.load(url)
        player.seek(to: 5)

        var recovered = false
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(20))
            player.load(url)
            // A load that actually proceeds (rather than being guarded away)
            // always zeroes currentTime -- seeing that happen again is proof
            // the earlier failure freed `loadedURL` for a real retry.
            if player.currentTime == 0 {
                recovered = true
                break
            }
        }
        #expect(recovered)
    }

    /// `AVPlayer.rate` is the speed while playing and 0 while paused -- one
    /// property with two meanings. `AudioPlayer.rate` is the CHOSEN speed and
    /// must survive a pause, or resuming would silently drop back to 1x.
    @Test func pausingDoesNotForgetTheChosenSpeed() {
        let player = player()
        player.setRate(1.5)
        player.pause()

        #expect(player.rate == 1.5)
    }

    /// The preference is about how Angelo listens, not about one file, so it
    /// outlives the process.
    @Test func theChosenSpeedIsRestoredFromDefaults() {
        player().setRate(1.75)

        #expect(player().rate == 1.75)
    }

    @Test func aFreshInstallStartsAtNormalSpeed() {
        #expect(player().rate == 1)
    }

    /// `clampedRate` is tested directly above, but `setRate` is where a bad value
    /// actually arrives from the UI -- and it clamps on the way IN so `rate` is
    /// never a non-speed. Without this, dropping that clamp is invisible:
    /// `appliedRate` re-clamps on the way out, so playback stays at 1x while
    /// `rate` reads 0 and the speed menu renders it.
    @Test func setRateRefusesAValueThatIsNotASpeed() {
        let player = player()
        player.setRate(1.5)
        player.setRate(0)

        #expect(player.rate == 1)
    }
}
