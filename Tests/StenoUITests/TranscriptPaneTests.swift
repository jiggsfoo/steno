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
