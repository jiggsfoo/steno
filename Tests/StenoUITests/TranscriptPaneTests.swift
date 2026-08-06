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
