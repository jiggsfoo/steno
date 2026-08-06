import Foundation
import Testing
@testable import StenoUI

private func tempRoot() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

private func sampleSidecar(
    signature: String = "c8357e00d535682319c8e19d50685d1a",
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
            timeZoneIdentifier: "Asia/Manila")
}

private func sampleBody(text: String = "buy eggs and milk") -> TranscriptBody {
    TranscriptBody(text: text,
                   segments: [Segment(start: 0, end: 1.5, text: text, speaker: nil)],
                   locale: "en_PH",
                   backend: "speechanalyzer",
                   modelID: "SpeechTranscriber")
}

@Test func writtenTranscriptRoundTrips() throws {
    let root = tempRoot()
    let store = TranscriptStore(root: root)
    let sidecar = sampleSidecar()

    let written = try store.write(sampleBody(), for: sidecar, at: Date(timeIntervalSince1970: 1))
    let read = store.transcript(for: sidecar)

    #expect(read == written)
    #expect(read?.text == "buy eggs and milk")
    #expect(read?.segments.first?.speaker == nil)
}

/// The signature is stamped from the sidecar, never supplied by the backend,
/// so a transcriber cannot mislabel its own output.
@Test func writeStampsTheSidecarsSignature() throws {
    let root = tempRoot()
    let store = TranscriptStore(root: root)
    let sidecar = sampleSidecar(signature: "aaaa1111")

    let written = try store.write(sampleBody(), for: sidecar, at: Date())

    #expect(written.signature == "aaaa1111")
    #expect(written.audioDurationSeconds == 3984.576)
}

/// THE load-bearing test. A transcript sitting at the right path but carrying a
/// different recording's signature must be refused, not displayed. Paying to
/// transcribe twice beats showing someone else's meeting.
@Test func transcriptWithAMismatchedSignatureIsRefused() throws {
    let root = tempRoot()
    let store = TranscriptStore(root: root)
    let mine = sampleSidecar(signature: "mine-1111")
    let theirs = sampleSidecar(signature: "theirs-9999")

    // Write THEIR transcript, then hand the file MY sidecar at the same path.
    try store.write(sampleBody(text: "a different meeting"), for: theirs, at: Date())

    #expect(store.transcript(for: mine) == nil)
    #expect(store.has(mine) == false)
    #expect(store.has(theirs) == true)
}

@Test func transcriptExtensionIsNotJsonSoScanSidecarsIgnoresIt() {
    let audio = URL(fileURLWithPath: "/tmp/x/2026-08-05/130006-c8357e00.mp3")
    let url = TranscriptStore.url(forAudio: audio)

    #expect(url.pathExtension == "transcript")
    #expect(url.lastPathComponent == "130006-c8357e00.transcript")
}

@Test func missingOrCorruptTranscriptReadsAsNil() throws {
    let root = tempRoot()
    let store = TranscriptStore(root: root)
    let sidecar = sampleSidecar()

    #expect(store.transcript(for: sidecar) == nil)

    let url = store.url(for: sidecar)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("not json at all".utf8).write(to: url)

    #expect(store.transcript(for: sidecar) == nil)
}
