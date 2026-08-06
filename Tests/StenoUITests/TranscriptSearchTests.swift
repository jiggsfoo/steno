import Foundation
import Testing
@testable import StenoUI

private func segment(_ text: String, at start: Double) -> Segment {
    Segment(start: start, end: start + 3, text: text, speaker: nil)
}

private func loaded(
    _ signature: String, title: String?, _ segments: [Segment]
) -> LoadedRecording {
    let sidecar = Sidecar(
        signature: signature, deviceFilename: "\(signature).hda",
        relativePath: "2026-08-05/\(signature).mp3", lengthBytes: 10,
        durationSeconds: 600, recordedAt: Date(timeIntervalSince1970: 1_754_400_000),
        syncedAt: Date(timeIntervalSince1970: 1_754_400_000),
        deviceSerial: "S", deviceModel: "hidock-p1",
        timeZoneIdentifier: "Asia/Manila", title: title)
    let transcript = Transcript(
        signature: signature, text: segments.map(\.text).joined(separator: " "),
        segments: segments, locale: "en_US", backend: "speechanalyzer",
        modelID: "m", transcribedAt: Date(timeIntervalSince1970: 1),
        audioDurationSeconds: 600)
    return LoadedRecording(sidecar: sidecar, transcript: transcript)
}

private let library = [
    loaded("aaa", title: "Distribution Networking Explained", [
        segment("but you know what consignment is versus like", at: 87),
        segment("the consignment model means he never fronts cash", at: 842),
        segment("nothing relevant in this line at all", at: 900),
    ]),
    loaded("bbb", title: "Meeting Prep and Messaging Plan", [
        segment("we could do consignment for the first batch", at: 527),
    ]),
]

@Test func aMatchBecomesAMomentCarryingItsOwnStartTime() {
    let (moments, capped) = TranscriptSearch.moments(matching: "consignment", in: library)

    #expect(moments.count == 3)
    #expect(capped == false)
    #expect(moments.first?.segment.start == 87)
    #expect(moments.first?.recordingTitle == "Distribution Networking Explained")
    #expect(moments.first?.signature == "aaa")
}

/// The highlight indexes into the SEGMENT's text, so the pane can mark the
/// matched word without searching the string a second time.
@Test func theHighlightPointsAtTheMatchWithinItsSegment() throws {
    let (moments, _) = TranscriptSearch.moments(matching: "consignment", in: library)
    let first = try #require(moments.first)

    #expect(String(first.segment.text[first.highlight]).lowercased() == "consignment")
}

@Test func matchingIgnoresCase() {
    #expect(TranscriptSearch.moments(matching: "CONSIGNMENT", in: library).moments.count == 3)
}

@Test func matchingIgnoresDiacritics() {
    let accented = [loaded("ccc", title: "Café notes", [segment("we met at the cafe", at: 5)])]

    #expect(TranscriptSearch.moments(matching: "café", in: accented).moments.count == 1)
}

/// A one-character query would match nearly every segment in the library and
/// produce a result list nobody can use.
@Test func aQueryShorterThanTwoCharactersReturnsNothing() {
    #expect(TranscriptSearch.moments(matching: "c", in: library).moments.isEmpty)
    #expect(TranscriptSearch.moments(matching: "", in: library).moments.isEmpty)
    #expect(TranscriptSearch.moments(matching: "  ", in: library).moments.isEmpty)
}

@Test func noMatchesIsAnEmptyResultNotAnError() {
    #expect(TranscriptSearch.moments(matching: "zzzznothing", in: library).moments.isEmpty)
}

@Test func aQueryLongerThanAnySegmentMatchesNothing() {
    let long = String(repeating: "consignment ", count: 40)

    #expect(TranscriptSearch.moments(matching: long, in: library).moments.isEmpty)
}

/// The cap must actually cap, and must SAY it capped — silently truncating
/// would make the pane claim it had shown everything.
@Test func theResultCapBitesAndIsReported() {
    let many = (0..<50).map { i in
        loaded("sig\(i)", title: "R\(i)",
               (0..<10).map { j in segment("consignment line", at: Double(j)) })
    }

    let (moments, capped) = TranscriptSearch.moments(matching: "consignment", in: many, limit: 25)

    #expect(moments.count == 25)
    #expect(capped == true)
}

/// A recording the sweep has not reached yet has no transcript and simply
/// contributes no moments — it is not an error and must not crash the search.
@Test func aRecordingWithNoTranscriptContributesNothing() {
    let sidecar = Sidecar(
        signature: "ddd", deviceFilename: "d.hda", relativePath: "2026-08-05/d.mp3",
        lengthBytes: 10, durationSeconds: 60, recordedAt: nil,
        syncedAt: Date(timeIntervalSince1970: 1), deviceSerial: "S",
        deviceModel: "hidock-p1", timeZoneIdentifier: "Asia/Manila")
    let untranscribed = LoadedRecording(sidecar: sidecar, transcript: nil)

    #expect(TranscriptSearch.moments(matching: "consignment", in: [untranscribed]).moments.isEmpty)
}

/// Titles are model output and can be absent. A moment still has to name its
/// recording, so an untitled one falls back to something a human can read.
@Test func anUntitledRecordingStillNamesItselfInAMoment() throws {
    let untitled = [loaded("eee", title: nil, [segment("consignment terms", at: 4)])]
    let moment = try #require(TranscriptSearch.moments(matching: "consignment", in: untitled).moments.first)

    #expect(!moment.recordingTitle.isEmpty)
}
