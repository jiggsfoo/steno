import Foundation
import SwiftUI
import Testing
@testable import StenoUI

/// The detach rule IS the feature. Auto-scroll that keeps yanking the view
/// while you are re-reading something is worse than no auto-scroll at all.
@Test func scrollingByHandStopsTheTranscriptFollowing() {
    #expect(!TranscriptPane.remainsFollowing(isFollowing: true, userScrolled: true))
}

@Test func followingContinuesWhenTheUserHasNotScrolled() {
    #expect(TranscriptPane.remainsFollowing(isFollowing: true, userScrolled: false))
}

/// Scrolling while already detached must not silently re-attach.
@Test func scrollingWhileDetachedLeavesItDetached() {
    #expect(!TranscriptPane.remainsFollowing(isFollowing: false, userScrolled: true))
    #expect(!TranscriptPane.remainsFollowing(isFollowing: false, userScrolled: false))
}

/// The ruling behind the transport row: a scrub is a deliberate navigation
/// act, the same class as clicking a transcript line — which already
/// re-attaches — and the opposite of a hand scroll, which says "let me read
/// elsewhere while the audio keeps going". So it re-attaches, INCLUDING from
/// the detached state, which is what makes a scrub a way back to following
/// without hunting for the Resume banner.
@Test func movingThePlayheadReattachesFollowing() {
    #expect(TranscriptPane.followsAfterPlayheadMove())
}

/// A recording whose asset has not loaded yet — and one with no usable audio
/// at all — reports duration 0. A `Slider` over `0...0` divides by its own
/// range length.
@Test func anUnknownDurationGivesADisabledScrubberWithNoZeroLengthRange() {
    let scrubber = TranscriptPane.scrubber(currentTime: 0, duration: 0)
    #expect(scrubber.isEnabled == false)
    #expect(scrubber.upperBound > 0)
    #expect(scrubber.position == 0)
}

@Test func aNonFiniteOrNegativeDurationIsTreatedAsUnknown() {
    #expect(!TranscriptPane.scrubber(currentTime: 5, duration: -1).isEnabled)
    #expect(!TranscriptPane.scrubber(currentTime: 5, duration: .nan).isEnabled)
    #expect(!TranscriptPane.scrubber(currentTime: 5, duration: .infinity).isEnabled)
}

@Test func aKnownDurationScrubsAcrossTheWholeRecording() {
    #expect(TranscriptPane.scrubber(currentTime: 41, duration: 3985)
            == TranscriptPane.Scrubber(position: 41, upperBound: 3985, isEnabled: true))
}

/// `AVPlayer` can report a `currentTime` a hair past the item's duration at
/// the end of playback, and a `Slider` value outside its own range is not a
/// defined state.
@Test func aPositionOutsideTheRecordingIsClamped() {
    #expect(TranscriptPane.scrubber(currentTime: 4000, duration: 3985).position == 3985)
    #expect(TranscriptPane.scrubber(currentTime: -3, duration: 3985).position == 0)
    #expect(TranscriptPane.scrubber(currentTime: .nan, duration: 3985).position == 0)
}

// MARK: - Which duration drives the transport
//
// `AudioPlayer.duration` starts at 0 and is only written from inside the
// periodic observer, which does not fire again until playback begins — and at
// registration the item's duration is still indefinite, so `isFinite` leaves it
// 0. Driving the transport off that alone gave a dead grey bar reading
// `0:00 / --:--` on every freshly selected recording until you pressed play.

/// The sidecar's length is measured at `Library.commit` time and known long
/// before any audio loads, so the control is live the moment a recording is
/// selected.
@Test func theSidecarsLengthDrivesTheTransportBeforePlaybackStarts() {
    #expect(TranscriptPane.transportDuration(observed: 0, sidecar: 3985) == 3985)

    let scrubber = TranscriptPane.scrubber(
        currentTime: 0,
        duration: TranscriptPane.transportDuration(observed: 0, sidecar: 3985) ?? 0)
    #expect(scrubber.isEnabled)
    #expect(scrubber.upperBound == 3985)
}

/// The observed value wins once it arrives: the sidecar's is measured from the
/// staged file at sync time, the observer's is what this `AVPlayer` will
/// actually play. Where they disagree, the thing doing the playing is right.
@Test func theObservedDurationOutranksTheSidecarsOnceItArrives() {
    #expect(TranscriptPane.transportDuration(observed: 4000, sidecar: 3985) == 4000)
}

/// A sidecar written before duration measurement existed, or one whose audio
/// could not be measured, carries nil — and must not resurrect the dead bar as
/// a live one scrubbing a length nobody knows.
@Test func neitherSourceHavingADurationLeavesTheTransportDisabled() {
    #expect(TranscriptPane.transportDuration(observed: 0, sidecar: nil) == nil)
    #expect(TranscriptPane.transportDuration(observed: 0, sidecar: 0) == nil)
    #expect(TranscriptPane.transportDuration(observed: 0, sidecar: -5) == nil)
    #expect(TranscriptPane.transportDuration(observed: 0, sidecar: .nan) == nil)
    #expect(TranscriptPane.transportDuration(observed: .nan, sidecar: nil) == nil)

    #expect(!TranscriptPane.scrubber(
        currentTime: 0,
        duration: TranscriptPane.transportDuration(observed: 0, sidecar: nil) ?? 0).isEnabled)
}

/// A non-finite observed value is not a usable duration either — `AVPlayer`
/// reports an indefinite item's as NaN, and infinity for a live stream.
@Test func aNonFiniteObservedDurationFallsBackToTheSidecar() {
    #expect(TranscriptPane.transportDuration(observed: .nan, sidecar: 3985) == 3985)
    #expect(TranscriptPane.transportDuration(observed: .infinity, sidecar: 3985) == 3985)
}

/// Deepgram populates `speaker`; on-device leaves it nil. A recording that was
/// never diarized must not sprout a fake "Speaker 1".
@Test func onlyDiarizedSegmentsGetASpeakerLabel() {
    let diarized = Segment(start: 0, end: 1, text: "hello", speaker: 0)
    let plain = Segment(start: 0, end: 1, text: "hello", speaker: nil)

    #expect(TranscriptPane.speakerLabel(for: diarized) != nil)
    #expect(TranscriptPane.speakerLabel(for: plain) == nil)
}

@Test func speakerLabelsAreOneBasedForReading() {
    #expect(TranscriptPane.speakerLabel(for: Segment(start: 0, end: 1, text: "x", speaker: 0)) == "Speaker 1")
    #expect(TranscriptPane.speakerLabel(for: Segment(start: 0, end: 1, text: "x", speaker: 1)) == "Speaker 2")
}

@Test func theElapsedLabelIsJustTheElapsedTime() {
    #expect(TranscriptPane.elapsedLabel(currentTime: 41) == "0:41")
    #expect(TranscriptPane.elapsedLabel(currentTime: 3985) == "66:25")
}

/// A player that has not loaded reports 0, and one at the very end can report
/// a hair past. Neither should render as a negative or a NaN.
@Test func theElapsedLabelSurvivesNonsense() {
    #expect(TranscriptPane.elapsedLabel(currentTime: -5) == "0:00")
    #expect(TranscriptPane.elapsedLabel(currentTime: .nan) == "0:00")
    #expect(TranscriptPane.elapsedLabel(currentTime: .infinity) == "0:00")
}

@Test func remainingCountsDownWithALeadingMinus() {
    #expect(TranscriptPane.remaining(currentTime: 41, duration: 3985) == "-65:44")
}

@Test func remainingIsZeroAtTheEndRatherThanNegative() {
    #expect(TranscriptPane.remaining(currentTime: 3985, duration: 3985) == "-0:00")
    #expect(TranscriptPane.remaining(currentTime: 4000, duration: 3985) == "-0:00")
}

/// Zero duration means "not known yet", exactly as it does in `scrubber` and
/// `transportDuration` — the bar and both labels resolve from one number.
/// `.infinity` matters here beside `0`: a future guard narrowed to
/// `duration > 0` alone would let it slip through undetected, since
/// `.infinity > 0` is true where `.nan > 0` is false.
@Test func remainingSaysSoWhenTheLengthIsUnknown() {
    #expect(TranscriptPane.remaining(currentTime: 41, duration: 0) == "--:--")
    #expect(TranscriptPane.remaining(currentTime: 41, duration: .infinity) == "--:--")
}

@Test func totalIsTheWholeLength() {
    #expect(TranscriptPane.total(duration: 3985) == "66:25")
    #expect(TranscriptPane.total(duration: 0) == "--:--")
    #expect(TranscriptPane.total(duration: .infinity) == "--:--")
}

/// Skipping back near the start must land at 0, not at a negative time that
/// `AudioPlayer.seek` would hand to `AVPlayer` as a `CMTime`.
@Test func skippingBackNearTheStartLandsAtZero() {
    #expect(TranscriptPane.skipTarget(from: 3, by: -10, duration: 3985) == 0)
    #expect(TranscriptPane.skipTarget(from: 0, by: -10, duration: 3985) == 0)
}

@Test func skippingForwardNearTheEndLandsAtTheEnd() {
    #expect(TranscriptPane.skipTarget(from: 3980, by: 10, duration: 3985) == 3985)
}

@Test func skippingInTheMiddleMovesByExactlyTheIncrement() {
    #expect(TranscriptPane.skipTarget(from: 100, by: -10, duration: 3985) == 90)
    #expect(TranscriptPane.skipTarget(from: 100, by: 10, duration: 3985) == 110)
}

/// With no known duration there is no valid position to hold, so the target
/// collapses to the start rather than holding at `currentTime`. `from: 50`
/// is deliberate, not `0`: `skipTarget`'s unknown-duration branch returns `0`
/// unconditionally, so an input already at `0` cannot distinguish "collapses
/// to the start" from "genuinely stayed put".
@Test func skippingWithNoKnownDurationLandsAtZero() {
    #expect(TranscriptPane.skipTarget(from: 50, by: 10, duration: 0) == 0)
    #expect(TranscriptPane.skipTarget(from: 50, by: 10, duration: .infinity) == 0)
}

@Test func theSpeedChoicesRunSlowestFirstAndIncludeNormal() {
    let choices = TranscriptPane.speedChoices()

    #expect(choices == [0.75, 1, 1.25, 1.5, 1.75, 2])
    #expect(choices == choices.sorted())
}

@Test func speedLabelsReadAsSpeedsNotMeasurements() {
    #expect(TranscriptPane.speedLabel(1) == "1x")
    #expect(TranscriptPane.speedLabel(2) == "2x")
    #expect(TranscriptPane.speedLabel(0.75) == "0.75x")
    #expect(TranscriptPane.speedLabel(1.5) == "1.5x")
}
