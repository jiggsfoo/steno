import Foundation
import Testing
@testable import StenoUI

@Test func bodyJoinsSegmentsIntoOneTextInOrder() {
    let segments = [
        Segment(start: 0, end: 1, text: "File this under"),
        Segment(start: 1, end: 2, text: "Grocery List."),
    ]
    let body = SpeechAnalyzerTranscriber.body(fromSegments: segments, locale: "en_PH")

    #expect(body.text == "File this under Grocery List.")
    #expect(body.segments.count == 2)
    #expect(body.locale == "en_PH")
    #expect(body.backend == "speechanalyzer")
}

/// On-device does not diarize. Every speaker must be nil, or downstream code
/// will render speaker labels that were never measured.
@Test func onDeviceSegmentsCarryNoSpeaker() {
    let body = SpeechAnalyzerTranscriber.body(
        fromSegments: [Segment(start: 0, end: 1, text: "hello")], locale: "en_US")

    #expect(body.segments.allSatisfy { $0.speaker == nil })
}

@Test func emptySegmentsProduceEmptyTextNotWhitespace() {
    let body = SpeechAnalyzerTranscriber.body(fromSegments: [], locale: "en_US")

    #expect(body.text.isEmpty)
    #expect(body.segments.isEmpty)
}

@Test func transcriberIdIsStableBecauseItIsPersistedInEveryTranscript() {
    #expect(SpeechAnalyzerTranscriber().id == "speechanalyzer")
}
