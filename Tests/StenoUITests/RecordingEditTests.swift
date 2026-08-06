import Foundation
import Testing
@testable import StenoUI

private func editable(title: String? = "Old title", topic: String? = "Old Topic") -> Sidecar {
    Sidecar(signature: "sig", deviceFilename: "a.hda",
            relativePath: "2026-08-05/a.mp3", lengthBytes: 10,
            durationSeconds: 60, recordedAt: Date(timeIntervalSince1970: 1_754_400_000),
            syncedAt: Date(timeIntervalSince1970: 1_754_400_000),
            deviceSerial: "S", deviceModel: "hidock-p1",
            timeZoneIdentifier: "Asia/Manila", title: title, topic: topic,
            transcribedAt: Date(timeIntervalSince1970: 2),
            transcriptBackend: "speechanalyzer")
}

@Test func editingRewritesOnlyTitleAndTopic() {
    let before = editable()
    let after = AppModel.editedSidecar(from: before, title: "New title", topic: "New Topic")

    #expect(after.title == "New title")
    #expect(after.topic == "New Topic")

    // Everything identifying or provenance-bearing must survive untouched.
    #expect(after.signature == before.signature)
    #expect(after.relativePath == before.relativePath)
    #expect(after.deviceModel == "hidock-p1")
    #expect(after.transcribedAt == before.transcribedAt)
    #expect(after.transcriptBackend == before.transcriptBackend)
    #expect(after.lengthBytes == before.lengthBytes)
    #expect(after.recordedAt == before.recordedAt)
}

/// Clearing the topic unfiles the recording. It must become nil rather than an
/// empty string, because `TopicName` rejects empty and a `""` topic would make
/// `Filer` build a path at the library root itself.
@Test func clearingTheTopicUnfilesRatherThanFilingUnderNothing() {
    let after = AppModel.editedSidecar(from: editable(), title: "T", topic: nil)

    #expect(after.topic == nil)
}

/// A blank title means "no title", the same state a recording has before
/// transcription — not a recording literally called "".
@Test func aBlankTitleBecomesNoTitle() {
    #expect(AppModel.editedSidecar(from: editable(), title: "   ", topic: "T").title == nil)
}

@Test func titleAndTopicAreTrimmed() {
    let after = AppModel.editedSidecar(from: editable(), title: "  New  ", topic: "  Topic  ")

    #expect(after.title == "New")
    #expect(after.topic == "Topic")
}

/// The guard the sweep uses, reused here. A recording already being written by
/// the transcription queue must not be editable at the same instant.
@Test func aRecordingTheSweepIsWritingIsNotEditable() {
    #expect(!AppModel.mayStartTranscribing(signature: "sig", inFlight: ["sig"]))
    #expect(AppModel.mayStartTranscribing(signature: "sig", inFlight: ["other"]))
}
