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

/// The bar and the readout are resolved from ONE number, so they cannot
/// disagree about how long the recording is.
@Test func theReadoutShowsTheFallbackDurationTheBarIsScrubbing() {
    let duration = TranscriptPane.transportDuration(observed: 0, sidecar: 3985) ?? 0
    #expect(TranscriptPane.elapsed(currentTime: 0, duration: duration) == "0:00 / 66:25")
}

@Test func theTransportReadoutPairsElapsedWithDuration() {
    #expect(TranscriptPane.elapsed(currentTime: 41, duration: 3985) == "0:41 / 66:25")
}

/// No invented "0:00" total: a duration that is not known yet must not read as
/// a zero-length recording.
@Test func theTransportReadoutSaysNothingItDoesNotKnow() {
    #expect(TranscriptPane.elapsed(currentTime: 0, duration: 0) == "0:00 / --:--")
    #expect(TranscriptPane.elapsed(currentTime: 5, duration: .nan) == "0:05 / --:--")
}

/// One formatter, not two. The readout sits directly under the per-line
/// stamps and has to agree with them.
@Test func theTransportReadoutUsesTheSameStampAsTheTranscriptLines() {
    #expect(TranscriptPane.elapsed(currentTime: 41, duration: 3985)
            == "\(TranscriptPane.timestamp(41)) / \(TranscriptPane.timestamp(3985))")
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
