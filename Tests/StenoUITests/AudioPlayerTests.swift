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
