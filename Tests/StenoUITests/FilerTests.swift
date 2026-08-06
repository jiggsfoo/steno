import Foundation
import Testing
@testable import StenoUI

private func tempRoot() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

private func filed(
    signature: String = "c8357e00d535682319c8e19d50685d1a",
    title: String = "Grocery list and the supplier call",
    topic: String? = "Grocery List",
    relativePath: String = "2026-08-05/130006-c8357e00.mp3"
) -> Sidecar {
    Sidecar(signature: signature,
            deviceFilename: "2026Aug05-130006-Rec09.hda",
            relativePath: relativePath,
            lengthBytes: 47_814_924,
            durationSeconds: 3984.576,
            recordedAt: Date(timeIntervalSince1970: 1_754_370_006),
            syncedAt: Date(timeIntervalSince1970: 1_754_380_000),
            deviceSerial: "HDP1254506027",
            deviceModel: "hidock-p1",
            timeZoneIdentifier: "Asia/Manila",
            title: title, topic: topic,
            transcribedAt: Date(timeIntervalSince1970: 1_754_390_000),
            transcriptBackend: "speechanalyzer",
            transcriptionAttempts: nil)
}

private func sampleTranscript(_ signature: String = "c8357e00d535682319c8e19d50685d1a") -> Transcript {
    Transcript(signature: signature, text: "buy eggs and milk", segments: [],
               locale: "en_PH", backend: "speechanalyzer", modelID: "SpeechTranscriber",
               transcribedAt: Date(timeIntervalSince1970: 1_754_390_000),
               audioDurationSeconds: 3984.576)
}

@Test func theNoteLandsInATopicFolderAtTheLibraryRoot() throws {
    let root = tempRoot()
    let filer = Filer(root: root)
    let sidecar = filed()

    let url = try filer.write(for: sidecar, transcript: sampleTranscript())

    #expect(url.deletingLastPathComponent().lastPathComponent == "Grocery List")
    #expect(url.deletingLastPathComponent().deletingLastPathComponent().path == root.path)
    #expect(url.pathExtension == "md")
    #expect(FileManager.default.fileExists(atPath: url.path))
}

@Test func theNoteCarriesFrontMatterBindingItToTheRecording() throws {
    let root = tempRoot()
    let sidecar = filed()
    let url = try Filer(root: root).write(for: sidecar, transcript: sampleTranscript())
    let text = try String(contentsOf: url, encoding: .utf8)

    #expect(text.hasPrefix("---\n"))
    #expect(text.contains("signature: c8357e00d535682319c8e19d50685d1a"))
    #expect(text.contains("audio: ../2026-08-05/130006-c8357e00.mp3"))
    #expect(text.contains("backend: speechanalyzer"))
    #expect(text.contains("buy eggs and milk"))

    // `render` uses `Date.ISO8601Format()` (a value-type format style) rather
    // than a shared `ISO8601DateFormatter` instance. Proven byte-identical
    // against that formatter directly — a local instance here, never shared
    // across tasks, carries none of the concurrency risk a static one would.
    let expectedRecordedAt = ISO8601DateFormatter().string(from: sidecar.recordedAt!)
    #expect(text.contains("recordedAt: \(expectedRecordedAt)"))
}

/// Writing twice must not produce two notes. The front-matter signature is what
/// makes the write idempotent.
@Test func rewritingTheSameRecordingOverwritesRatherThanDuplicates() throws {
    let root = tempRoot()
    let filer = Filer(root: root)

    let first = try filer.write(for: filed(), transcript: sampleTranscript())
    let second = try filer.write(for: filed(), transcript: sampleTranscript())

    #expect(first == second)
    let contents = try FileManager.default.contentsOfDirectory(
        atPath: root.appendingPathComponent("Grocery List").path)
    #expect(contents.count == 1)
}

/// Two recordings, same title, same minute. The incumbent must survive — the
/// audio path learned this expensively and the note path inherits it.
@Test func aDifferentRecordingAtTheSamePathGetsASignatureSuffix() throws {
    let root = tempRoot()
    let filer = Filer(root: root)
    let mine = filed(signature: "aaaa1111aaaa")
    let theirs = filed(signature: "bbbb2222bbbb")

    let first = try filer.write(for: mine, transcript: sampleTranscript("aaaa1111aaaa"))
    let second = try filer.write(for: theirs, transcript: sampleTranscript("bbbb2222bbbb"))

    #expect(first != second)
    #expect(second.lastPathComponent.contains("bbbb2222"))
    #expect(FileManager.default.fileExists(atPath: first.path))
}

@Test func changingTopicRemovesTheNoteAtTheOldLocation() throws {
    let root = tempRoot()
    let filer = Filer(root: root)
    let old = filed(topic: "Groceries")
    let new = filed(topic: "Receipts")

    let oldURL = try filer.write(for: old, transcript: sampleTranscript())
    filer.removeNote(for: old, topic: "Groceries")
    _ = try filer.write(for: new, transcript: sampleTranscript())

    #expect(!FileManager.default.fileExists(atPath: oldURL.path))
    #expect(FileManager.default.fileExists(
        atPath: root.appendingPathComponent("Receipts").path))
}

/// `removeNote`'s `topic` parameter is untrusted the same way `write`'s is —
/// EVERY other path into a filesystem write re-sanitises through
/// `TopicName.sanitised` before use; this delete path took `topic` on faith.
/// Proven with an actual escape attempt: a topic that walks up and out of the
/// library root at a file this type does not own must be refused outright,
/// not resolved and acted on.
@Test func removeNoteRefusesATopicThatWouldEscapeTheLibraryRoot() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let root = base.appendingPathComponent("library")
    let outside = base.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

    let sidecar = filed()
    let decoy = outside.appendingPathComponent("decoy.md")
    try """
        ---
        signature: \(sidecar.signature)
        ---

        Not actually owned by this library.
        """.write(to: decoy, atomically: true, encoding: .utf8)

    Filer(root: root).removeNote(for: sidecar, topic: "../outside")

    #expect(FileManager.default.fileExists(atPath: decoy.path))
}

/// `noteURL(for:topic:)` — and so the unsuffixed path `removeNote` used to
/// assume — only ever names the BASE stem. A note that collided and took a
/// signature suffix lives somewhere else, so `removeNote` must locate it by
/// front-matter signature rather than by recomputing that base path, or the
/// suffixed note is silently orphaned.
@Test func removeNoteFindsASuffixedNoteByItsSignature() throws {
    let root = tempRoot()
    let filer = Filer(root: root)
    let a = filed(signature: "aaaa1111aaaa")
    let b = filed(signature: "bbbb2222bbbb")

    let aURL = try filer.write(for: a, transcript: sampleTranscript("aaaa1111aaaa"))
    let bURL = try filer.write(for: b, transcript: sampleTranscript("bbbb2222bbbb"))
    #expect(bURL != aURL)
    #expect(bURL.lastPathComponent.contains("bbbb2222"))   // confirms b actually took the suffix

    filer.removeNote(for: b, topic: "Grocery List")

    #expect(!FileManager.default.fileExists(atPath: bURL.path))
    #expect(FileManager.default.fileExists(atPath: aURL.path))
}

/// The topic tree is DERIVED. Deleting it and rebuilding must give back exactly
/// what was there, which is what makes "Rebuild Topic Folders" a button rather
/// than a recovery operation.
///
/// REWRITTEN from the brief. The brief's fixture called `filed(...)` for all
/// three sidecars without varying `relativePath`, so all three shared the same
/// hardcoded path. `TranscriptStore`'s file location is keyed on the audio's
/// relative path, not the signature, so the three sequential `store.write`
/// calls collided: only the LAST one (signature "cccc3333", no topic) actually
/// survived on disk. `store.transcript(for:)` then returned nil for "aaaa1111"
/// and "bbbb2222" (signature mismatch at that shared path), so `rebuild` wrote
/// no note for either of them and neither "Groceries" nor "Receipts" was ever
/// created — the brief's `fileExists` assertions on those two folders do not
/// survive contact with the real fixture. Passing twice proved nothing; the
/// bug was in the setup, not in `Filer`.
///
/// Fixed by giving each sidecar its own `relativePath` (so each transcript
/// lands at its own file), and by actually proving regeneration: build the
/// tree, snapshot every note's CONTENT (not just its path — a path-only diff
/// would not catch a rebuild that reproduces the right filenames with the
/// wrong text), physically delete the derived folders, rebuild, and compare.
@Test func rebuildFromSidecarsReproducesTheTreeExactly() throws {
    let root = tempRoot()
    let filer = Filer(root: root)
    let store = TranscriptStore(root: root)
    let sidecars = [
        filed(signature: "aaaa1111", topic: "Groceries", relativePath: "2026-08-05/aaaa1111.mp3"),
        filed(signature: "bbbb2222", topic: "Receipts", relativePath: "2026-08-05/bbbb2222.mp3"),
        filed(signature: "cccc3333", topic: nil, relativePath: "2026-08-05/cccc3333.mp3"),
    ]
    for s in sidecars {
        try store.write(
            TranscriptBody(text: "text for \(s.signature)", segments: [], locale: "en_PH",
                           backend: "speechanalyzer", modelID: "m"), for: s, at: Date())
    }

    try filer.rebuild(from: sidecars, store: store)

    func notes() throws -> [String: String] {
        var out: [String: String] = [:]
        for topic in ["Groceries", "Receipts"] {
            let folder = root.appendingPathComponent(topic)
            guard FileManager.default.fileExists(atPath: folder.path) else { continue }
            for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
                out["\(topic)/\(name)"] = try String(
                    contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
            }
        }
        return out
    }

    let before = try notes()
    #expect(before.count == 2)   // one note per topiced sidecar; the untopiced one contributes none
    #expect(before.keys.contains { $0.hasPrefix("Groceries/") })
    #expect(before.keys.contains { $0.hasPrefix("Receipts/") })

    // Delete the whole derived tree — what "Rebuild Topic Folders" actually
    // recovers from, not merely a second call over a tree that's already there.
    for topic in ["Groceries", "Receipts"] {
        try FileManager.default.removeItem(at: root.appendingPathComponent(topic))
    }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Groceries").path))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Receipts").path))

    try filer.rebuild(from: sidecars, store: store)
    let after = try notes()

    #expect(before == after)

    // The third sidecar carries no topic, so it must contribute no folder.
    let topLevel = try FileManager.default.contentsOfDirectory(atPath: root.path)
    #expect(topLevel.filter { !$0.hasPrefix("2026-") }.count == 2)
}

/// CRITICAL: a topic folder sits at the library root, in Finder — exactly the
/// kind of folder a person drops their own file into, or where an unrelated
/// note with no matching signature might already live. `removeNote` already
/// says so ("Leave the folder even if now empty: the user may have put other
/// things in it."); `rebuild` must honour the same rule. Pressing "Rebuild
/// Topic Folders" must never destroy a file this type does not own.
@Test func rebuildLeavesFilesItDoesNotOwnAlone() throws {
    let root = tempRoot()
    let filer = Filer(root: root)
    let store = TranscriptStore(root: root)
    let sidecar = filed(signature: "aaaa1111", topic: "Groceries",
                        relativePath: "2026-08-05/aaaa1111.mp3")
    try store.write(
        TranscriptBody(text: "buy eggs", segments: [], locale: "en_PH",
                       backend: "speechanalyzer", modelID: "m"), for: sidecar, at: Date())

    // First pass creates the folder and the owned note.
    try filer.rebuild(from: [sidecar], store: store)
    let folder = root.appendingPathComponent("Groceries")

    // A user-authored file that happens to live in this topic folder.
    let userFile = folder.appendingPathComponent("Notes.txt")
    try "keep me".write(to: userFile, atomically: true, encoding: .utf8)

    // An unrelated `.md` with no matching signature — not this type's note.
    let unrelatedNote = folder.appendingPathComponent("Unrelated.md")
    try """
        ---
        signature: not-a-real-signature
        ---

        Somebody else's note.
        """.write(to: unrelatedNote, atomically: true, encoding: .utf8)

    try filer.rebuild(from: [sidecar], store: store)

    #expect(FileManager.default.fileExists(atPath: userFile.path))
    #expect(try String(contentsOf: userFile, encoding: .utf8) == "keep me")
    #expect(FileManager.default.fileExists(atPath: unrelatedNote.path))

    // The owned note must still be correctly regenerated alongside them.
    let ownedNames = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        .filter { $0.hasSuffix(".md") && $0 != "Unrelated.md" }
    #expect(ownedNames.count == 1)
    let ownedText = try String(
        contentsOf: folder.appendingPathComponent(ownedNames[0]), encoding: .utf8)
    #expect(ownedText.contains("signature: aaaa1111"))
    #expect(ownedText.contains("buy eggs"))
}

@Test func aSidecarWithNoTopicProducesNoNote() throws {
    let root = tempRoot()
    let unfiled = filed(topic: nil)

    #expect(throws: Never.self) {
        try Filer(root: root).rebuild(from: [unfiled], store: TranscriptStore(root: root))
    }
    let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
    #expect(entries.isEmpty)
}

/// `rebuild` reaches this guard only by silently skipping — added directly so
/// the `write(for:transcript:)` entry point itself is proven to refuse rather
/// than write somewhere wrong when handed an untopiced sidecar.
@Test func writingASidecarWithNoTopicThrowsRatherThanGuessingAPlace() throws {
    let root = tempRoot()
    let unfiled = filed(topic: nil)

    #expect(throws: FilerError.noTopic(unfiled.signature)) {
        try Filer(root: root).write(for: unfiled, transcript: sampleTranscript())
    }
}
