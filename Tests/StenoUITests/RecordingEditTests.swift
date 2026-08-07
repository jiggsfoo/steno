import Foundation
import Testing
@testable import StenoUI

private func editable(
    title: String? = "Old title", topic: String? = "Old Topic",
    transcribedAt: Date? = Date(timeIntervalSince1970: 2),
    backend: String? = "speechanalyzer"
) -> Sidecar {
    Sidecar(signature: "sig", deviceFilename: "a.hda",
            relativePath: "2026-08-05/a.mp3", lengthBytes: 10,
            durationSeconds: 60, recordedAt: Date(timeIntervalSince1970: 1_754_400_000),
            syncedAt: Date(timeIntervalSince1970: 1_754_400_000),
            deviceSerial: "S", deviceModel: "hidock-p1",
            timeZoneIdentifier: "Asia/Manila", title: title, topic: topic,
            transcribedAt: transcribedAt,
            transcriptBackend: backend)
}

/// `Sidecar` is `Equatable`, so build the expected value wholesale and compare
/// against it rather than enumerating fields one at a time -- that also
/// covers every field `Sidecar` gains later, not just the ones listed here
/// today.
@Test func editingRewritesOnlyTitleAndTopic() {
    let before = editable()
    let after = AppModel.editedSidecar(from: before, title: "New title", topic: "New Topic")

    var expected = before
    expected.title = "New title"
    expected.topic = "New Topic"
    #expect(after == expected)
}

/// Clearing the topic unfiles the recording. It must become nil rather than an
/// empty string, because `TopicName` rejects empty and a `""` topic would make
/// `Filer` build a path at the library root itself.
@Test func clearingTheTopicUnfilesRatherThanFilingUnderNothing() {
    #expect(AppModel.editedSidecar(from: editable(), title: "T", topic: nil).topic == nil)

    // The case the doc comment above actually describes: a topic that trims
    // down to nothing must ALSO come back nil, not "" -- the literal-nil case
    // alone proves nothing about that claim.
    #expect(AppModel.editedSidecar(from: editable(), title: "T", topic: "   ").topic == nil)
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

// MARK: - Saving against what is actually on disk
//
// These exercise `AppModel.writeEdit` -- the whole read-edit-write step
// `updateRecording` delegates to -- against a real temp library root.
//
// `updateRecording` ITSELF is still out of reach, and deliberately so:
// reaching it needs a live `AppModel`, whose `libraryRoot` setter writes the
// user's real `UserDefaults` key and rebuilds a hardcoded
// `~/Library/Application Support/Steno/index.sqlite`, so no test may point
// one at a temp root. What that leaves uncovered is thin and named: the
// `sidecarsInFlight` guard (covered as a pure predicate above), the index
// upsert, and the `Filer` call -- none of which can lose a field. Everything
// that CAN is below, in the same function the app calls.

private func tempRoot() -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// Puts `sidecar` on disk at its own `relativePath`, audio and all, the way a
/// real sync leaves it.
private func seeded(_ sidecar: Sidecar, at root: URL) throws -> Library {
    let library = Library(root: root)
    let audio = root.appendingPathComponent(sidecar.relativePath)
    try FileManager.default.createDirectory(
        at: audio.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data([1, 2, 3, 4]).write(to: audio)
    try library.updateSidecar(sidecar)
    return library
}

/// THE data-loss sequence, reproduced end to end.
///
/// 1. The window loads recording R with no title, no topic, no `transcribedAt`
///    and no `transcriptBackend`.
/// 2. A re-transcription writes all four. Nothing tells the open window --
///    `retranscribe` never touches `transcriptionProgress`, the only thing the
///    window reloads on -- so its snapshot stays stale indefinitely.
/// 3. The user edits the title from that stale window.
/// 4. Without the re-read, `editedSidecar` copies all sixteen fields off the
///    STALE snapshot and `updateSidecar` replaces the file wholesale, reverting
///    `transcribedAt` and `transcriptBackend` to their pre-transcription
///    values while a real transcript sits on disk. `pending` then excludes the
///    recording forever, so unlike the sweep's variant this one never
///    self-heals, and the sidecar permanently misattributes the transcript.
@Test func savingAnEditRebasesOntoWhatIsOnDiskRatherThanTheWindowsSnapshot() throws {
    let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }

    let stale = editable(title: nil, topic: nil, transcribedAt: nil, backend: nil)
    let library = try seeded(stale, at: root)

    var transcribed = stale
    transcribed.title = "AI Title"
    transcribed.topic = "Receipts"
    transcribed.transcribedAt = Date(timeIntervalSince1970: 1_754_500_000)
    transcribed.transcriptBackend = "deepgram"
    try library.updateSidecar(transcribed)

    let write = AppModel.writeEdit(for: stale, title: "My Title", topic: "Receipts", in: library)
    guard case let .wrote(previous, edited) = write else {
        Issue.record("expected a write, got \(write)")
        return
    }

    #expect(edited.title == "My Title")
    #expect(edited.transcribedAt == transcribed.transcribedAt)
    #expect(edited.transcriptBackend == "deepgram")

    // The note removal is driven off `previous.topic`. Off the stale snapshot
    // it is nil, `removeNote` never runs, and because `Filer.rebuild` only
    // ever revisits folders that are some CURRENT sidecar's topic, the note
    // left behind in "Receipts" is orphaned permanently.
    #expect(previous.topic == "Receipts")

    // The file itself, not just the returned value.
    let onDisk = try #require(library.sidecar(atRelativePath: stale.relativePath))
    #expect(onDisk.title == "My Title")
    #expect(onDisk.transcribedAt == transcribed.transcribedAt)
    #expect(onDisk.transcriptBackend == "deepgram")
}

/// Deleted from under the window. Falling back to the caller's snapshot here
/// would be worse than refusing: `updateSidecar` would RESURRECT a sidecar
/// describing audio that may no longer exist.
@Test func anEditOfAVanishedRecordingIsRefusedRatherThanRewrittenFromTheSnapshot() {
    let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let gone = editable()

    #expect(AppModel.writeEdit(for: gone, title: "T", topic: nil,
                               in: Library(root: root)) == .vanished)
    #expect(Library(root: root).sidecar(atRelativePath: gone.relativePath) == nil)
}

/// A DIFFERENT recording at the same path is the same refusal, for the same
/// reason `Library.commit` fails closed on one: a matching path is not
/// identity, a matching signature is.
@Test func anEditIsRefusedWhenADifferentRecordingOccupiesThePath() throws {
    let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }

    var incumbent = editable(title: "Not yours", topic: "Theirs")
    incumbent.signature = "some-other-recording"
    let library = try seeded(incumbent, at: root)

    #expect(AppModel.writeEdit(for: editable(), title: "T", topic: nil, in: library) == .vanished)
    #expect(library.sidecar(atRelativePath: incumbent.relativePath) == incumbent)
}
