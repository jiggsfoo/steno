import Foundation
import Testing
@testable import StenoUI

private func moment(_ signature: String, _ title: String, at start: Double) -> Moment {
    let text = "a line about consignment"
    return Moment(signature: signature, recordingTitle: title,
                  segment: Segment(start: start, end: start + 2, text: text, speaker: nil),
                  highlight: text.range(of: "consignment")!)
}

@Test func momentsAreGroupedByRecordingInFirstAppearanceOrder() {
    let groups = MomentsPane.grouped([
        moment("a", "First", at: 1), moment("b", "Second", at: 2), moment("a", "First", at: 3),
    ])

    #expect(groups.map(\.title) == ["First", "Second"])
    #expect(groups.first?.moments.count == 2)
}

/// Titles are model output and can collide (a recurring weekly meeting gets
/// the same AI-generated title every time). Grouping has to key on the one
/// thing actually unique per recording — `signature`, the same field
/// `onPlay` already routes clicks on — or two distinct recordings sharing a
/// title would merge into one group with interleaved, unattributable moments.
@Test func distinctRecordingsSharingATitleStayInSeparateGroups() {
    let groups = MomentsPane.grouped([
        moment("a", "Weekly Work Update", at: 1),
        moment("b", "Weekly Work Update", at: 2),
    ])

    #expect(groups.count == 2)
    #expect(groups.map(\.signature) == ["a", "b"])
}

/// The count is what tells you whether it is worth reading the list, so it has
/// to say when it was truncated rather than implying it showed everything.
@Test func theSummarySaysWhenTheCapBit() {
    #expect(MomentsPane.summary(count: 4, capped: false) == "4 moments")
    #expect(MomentsPane.summary(count: 500, capped: true) == "First 500 moments")
}

@Test func theSummaryIsSingularForOne() {
    #expect(MomentsPane.summary(count: 1, capped: false) == "1 moment")
}

@Test func noMatchesSaysSoRatherThanShowingZero() {
    #expect(MomentsPane.summary(count: 0, capped: false) == "No matches")
}

@Test func anEmptyResultProducesNoGroups() {
    #expect(MomentsPane.grouped([]).isEmpty)
}
