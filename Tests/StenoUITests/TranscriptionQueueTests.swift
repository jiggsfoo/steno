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
    let done = queueSidecar(signature: "done")
    let todo = queueSidecar(signature: "todo")

    _ = await queue.process(done)

    let pending = await queue.pending(from: [done, todo])
    #expect(pending.map(\.signature) == ["todo"])
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

    let after = await queue.process(original)

    #expect(after.signature == original.signature)
    #expect(after.relativePath == original.relativePath)
    #expect(after.transcribedAt == nil)
}
