import Foundation
import Testing
@testable import StenoUI

private actor CallCounter {
    private(set) var count = 0
    func bump() { count += 1 }
}

private struct CountingTranscriber: Transcriber {
    let id = "counting"
    let displayName = "Counting"
    let counter: CallCounter
    var failing = false

    func isAvailable() async -> Bool { true }

    func transcribe(audio: URL, locale: Locale) async throws -> TranscriptBody {
        await counter.bump()
        if failing { throw TranscriberError.backendFailed("nope") }
        return TranscriptBody(text: "File this under Grocery List. Buy eggs.",
                              segments: [], locale: "en_PH",
                              backend: "counting", modelID: "counting-1")
    }
}

/// Hands out one string per call, sticking on the last once exhausted.
/// `actor`-backed so it is safely shared with a `Sendable` `Transcriber`.
private actor TextQueue {
    private var items: [String]
    private var index = 0
    init(_ items: [String]) { self.items = items }
    func next() -> String {
        defer { index = min(index + 1, items.count - 1) }
        return items[index]
    }
}

/// Returns a DIFFERENT transcript text on each call, both carrying the SAME
/// filing directive ("File this under Grocery List.") so the topic a
/// re-transcription resolves to stays fixed while the title — derived from
/// the transcript's own leading words — changes. This is what a real Deepgram
/// re-transcription looks like: same topic, different title, almost always.
private struct RetitlingTranscriber: Transcriber {
    let id = "retitling"
    let displayName = "Retitling"
    let texts: TextQueue

    func isAvailable() async -> Bool { true }

    func transcribe(audio: URL, locale: Locale) async throws -> TranscriptBody {
        let text = await texts.next()
        return TranscriptBody(text: text, segments: [], locale: "en_US",
                              backend: "retitling", modelID: "retitling-1")
    }
}

private func tempRoot() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

private func queueSidecar(signature: String = "sig-1") -> Sidecar {
    Sidecar(signature: signature, deviceFilename: "a.hda",
            relativePath: "2026-08-05/130006-\(signature).mp3",
            lengthBytes: 10, durationSeconds: 60,
            recordedAt: Date(timeIntervalSince1970: 1_754_370_006),
            syncedAt: Date(timeIntervalSince1970: 1_754_380_000),
            deviceSerial: "S", deviceModel: "hidock-p1", timeZoneIdentifier: "Asia/Manila")
}

private func makeQueue(root: URL, transcriber: Transcriber) -> TranscriptionQueue {
    TranscriptionQueue(root: root,
                       store: TranscriptStore(root: root),
                       filer: Filer(root: root),
                       resolver: TopicResolver(suggester: nil),
                       transcriber: transcriber,
                       maxAttempts: 3)
}

/// THE money test. Transcription is the expensive step, so the already-done
/// check is the presence of a valid transcript file — NOT sidecar.transcribedAt.
/// A crash after the transcript write must never re-spend.
@Test func aSecondPassNeverRetranscribes() async throws {
    let root = tempRoot()
    let counter = CallCounter()
    let queue = makeQueue(root: root, transcriber: CountingTranscriber(counter: counter))
    let sidecar = queueSidecar()

    _ = await queue.process(sidecar)
    // Simulate the crash window: the transcript landed but the sidecar update
    // never did, so the caller still holds the ORIGINAL sidecar.
    _ = await queue.process(sidecar)

    #expect(await counter.count == 1)
}

@Test func pendingSkipsAnythingThatAlreadyHasAValidTranscript() async throws {
    let root = tempRoot()
    let counter = CallCounter()
    let queue = makeQueue(root: root, transcriber: CountingTranscriber(counter: counter))
    var done = queueSidecar(signature: "done")
    let todo = queueSidecar(signature: "todo")

    // The persisted sidecar, as a fresh `scanSidecars()` would read it back --
    // NOT the pre-process value. `process`'s own return is what carries
    // `transcribedAt`, and `pending` now also keys off that field (see
    // `pendingReadmitsATranscriptWrittenButNeverPersistedToTheSidecar`), so a
    // fully-persisted "done" sidecar has to actually carry it to prove this
    // case is distinct from that one.
    done = await queue.process(done)

    let pending = await queue.pending(from: [done, todo])
    #expect(pending.map(\.signature) == ["todo"])
}

/// Reconciliation for the crash window `run` documents: the transcript lands
/// on disk before the caller persists the sidecar, so a crash in between
/// leaves a transcript describing a sidecar whose OWN `transcribedAt` never
/// learned about it. `pending` must still surface that sidecar -- otherwise
/// `store.has` alone reads it as "already done" and title/topic/note are never
/// written, permanently -- but re-processing it must not pay for another
/// transcription: `run`'s step 1 still finds the valid transcript and reuses it.
@Test func pendingReadmitsATranscriptWrittenButNeverPersistedToTheSidecar() async throws {
    let root = tempRoot()
    let counter = CallCounter()
    let queue = makeQueue(root: root, transcriber: CountingTranscriber(counter: counter))
    let sidecar = queueSidecar()

    // Simulate the crash window directly: a valid transcript exists, but this
    // sidecar (as if freshly re-read from disk) never recorded it.
    _ = try TranscriptStore(root: root).write(
        TranscriptBody(text: "buy eggs", segments: [], locale: "en_US",
                      backend: "counting", modelID: "counting-1"),
        for: sidecar, at: Date())
    #expect(sidecar.transcribedAt == nil)

    #expect(await queue.pending(from: [sidecar]).map(\.signature) == [sidecar.signature])

    let updated = await queue.process(sidecar)
    #expect(await counter.count == 0)          // reused the existing transcript
    #expect(updated.transcribedAt != nil)      // and is now persisted
}

@Test func processingWritesTranscriptSidecarFieldsAndNote() async throws {
    let root = tempRoot()
    let queue = makeQueue(root: root, transcriber: CountingTranscriber(counter: CallCounter()))

    let updated = await queue.process(queueSidecar())

    #expect(updated.transcribedAt != nil)
    #expect(updated.transcriptBackend == "counting")
    #expect(updated.topic == "Grocery List")
    #expect(updated.title?.isEmpty == false)
    #expect(FileManager.default.fileExists(
        atPath: root.appendingPathComponent("Grocery List").path))
}

/// A permanently undecodable recording must stop being retried, or it re-spends
/// on every launch forever.
@Test func repeatedFailuresStopBeingRetriedAtTheCap() async throws {
    let root = tempRoot()
    let counter = CallCounter()
    let queue = makeQueue(root: root,
                          transcriber: CountingTranscriber(counter: counter, failing: true))
    var sidecar = queueSidecar()

    for _ in 0..<5 { sidecar = await queue.process(sidecar) }

    #expect(sidecar.transcriptionAttempts == 3)
    #expect(await counter.count == 3)
    #expect(await queue.pending(from: [sidecar]).isEmpty)
}

@Test func aFailedRecordingKeepsItsAudioAndSidecar() async throws {
    let root = tempRoot()
    let queue = makeQueue(root: root,
                          transcriber: CountingTranscriber(counter: CallCounter(), failing: true))
    let original = queueSidecar()
    let audioURL = root.appendingPathComponent(original.relativePath)
    try FileManager.default.createDirectory(
        at: audioURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let audioBytes = Data("fake audio bytes".utf8)
    try audioBytes.write(to: audioURL)

    let after = await queue.process(original)

    #expect(after.signature == original.signature)
    #expect(after.relativePath == original.relativePath)
    #expect(after.transcribedAt == nil)
    #expect(FileManager.default.fileExists(atPath: audioURL.path))
    #expect(try Data(contentsOf: audioURL) == audioBytes)
}

/// A failed retry must not destroy what was already there. The old design had
/// `AppModel.retranscribe` delete the transcript BEFORE calling `retry`, so a
/// retry that then failed (a bad key, no network, a quit) left the recording
/// with NEITHER transcript, while the sidecar still claimed the now-deleted
/// old one's `transcribedAt`/`transcriptBackend`. `retry` itself never
/// deletes anything -- `store.write`'s atomic install is what replaces the
/// old file, and only once a new transcription has actually succeeded.
@Test func aFailedRetryLeavesThePreviousTranscriptIntact() async throws {
    let root = tempRoot()
    let workingQueue = makeQueue(root: root, transcriber: CountingTranscriber(counter: CallCounter()))
    var sidecar = queueSidecar()

    sidecar = await workingQueue.process(sidecar)
    #expect(sidecar.transcribedAt != nil)
    #expect(sidecar.transcriptBackend == "counting")

    let store = TranscriptStore(root: root)
    let original = try #require(store.transcript(for: sidecar))

    let failingQueue = makeQueue(
        root: root, transcriber: CountingTranscriber(counter: CallCounter(), failing: true))
    let afterFailedRetry = await failingQueue.retry(sidecar)

    // The retry attempt is recorded as failed...
    #expect(afterFailedRetry.transcriptionAttempts == 1)
    // ...but the sidecar still describes a transcript that is STILL REAL, not
    // one that used to exist and is now gone.
    #expect(afterFailedRetry.transcribedAt == sidecar.transcribedAt)
    #expect(afterFailedRetry.transcriptBackend == "counting")
    let stillThere = try #require(store.transcript(for: sidecar))
    #expect(stillThere == original)
}

/// IMPORTANT: the note's FILENAME embeds the title, not just the topic
/// (`"<stamp> <title>.md"`). Before this fix, `run` only removed the previous
/// note when `previousTopic != filing.topic` — so a re-run that keeps the
/// SAME topic but produces a DIFFERENT title (the branch's flagship action:
/// Deepgram re-transcription almost always retitles) wrote a second note at a
/// new filename and left the first one behind, so two notes on disk claimed
/// the same recording via identical `signature:` front matter. Driven through
/// `TranscriptionQueue` itself, not by calling `removeNote` by hand, because
/// the defect is in `run`'s own removal condition.
@Test func reprocessingWithADifferentTitleButTheSameTopicLeavesOnlyOneNote() async throws {
    let root = tempRoot()
    let texts = TextQueue([
        "Quick note about eggs. File this under Grocery List.",
        "Second recording about milk. File this under Grocery List.",
    ])
    let queue = makeQueue(root: root, transcriber: RetitlingTranscriber(texts: texts))
    let sidecar = queueSidecar()

    let first = await queue.process(sidecar)
    #expect(first.topic == "Grocery List")

    // A different backend run over the same recording -- new text, same
    // directive, so the topic must resolve identically while the title does not.
    let second = await queue.retry(first)
    #expect(second.topic == "Grocery List")
    #expect(second.title != first.title)

    let folder = root.appendingPathComponent("Grocery List")
    let notes = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        .filter { $0.hasSuffix(".md") }
    #expect(notes.count == 1)

    let survivor = try String(
        contentsOf: folder.appendingPathComponent(notes[0]), encoding: .utf8)
    #expect(survivor.contains("Second recording about milk"))
}

/// The cap in `Sidecar.transcriptionAttempts`'s own contract is scoped to
/// "automatic retry" — manual retry is documented to ignore it. `retry` is
/// the deliberate path through a cap `process` refuses to cross.
@Test func retryTranscribesARecordingThatProcessRefuses() async throws {
    let root = tempRoot()
    let counter = CallCounter()
    let queue = makeQueue(root: root,
                          transcriber: CountingTranscriber(counter: counter, failing: true))
    var sidecar = queueSidecar()

    for _ in 0..<3 { sidecar = await queue.process(sidecar) }
    #expect(sidecar.transcriptionAttempts == 3)
    #expect(await counter.count == 3)

    // `process` refuses: capped, no further backend call.
    sidecar = await queue.process(sidecar)
    #expect(await counter.count == 3)

    // `retry` ignores the cap: the backend is invoked again, and the
    // attempt count starts fresh rather than climbing from the spent budget.
    sidecar = await queue.retry(sidecar)
    #expect(await counter.count == 4)
    #expect(sidecar.transcriptionAttempts == 1)
}
