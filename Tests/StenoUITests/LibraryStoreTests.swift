import Foundation
import Testing
@testable import StenoUI

private func tempRoot() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

private func storeSidecar(_ signature: String, title: String? = nil) -> Sidecar {
    Sidecar(signature: signature, deviceFilename: "\(signature).hda",
            relativePath: "2026-08-05/\(signature).mp3", lengthBytes: 10,
            durationSeconds: 60, recordedAt: Date(timeIntervalSince1970: 1_754_400_000),
            syncedAt: Date(timeIntervalSince1970: 1_754_400_000),
            deviceSerial: "S", deviceModel: "hidock-p1",
            timeZoneIdentifier: "Asia/Manila", title: title)
}

@MainActor
@Test func loadPairsEachSidecarWithItsTranscript() async throws {
    let root = tempRoot()
    let store = TranscriptStore(root: root)
    let withText = storeSidecar("aaa", title: "Has a transcript")
    let without = storeSidecar("bbb")

    try store.write(TranscriptBody(text: "hello there", segments: [],
                                   locale: "en_US", backend: "speechanalyzer", modelID: "m"),
                    for: withText, at: Date(timeIntervalSince1970: 1))

    let library = LibraryStore()
    await library.load(root: root, sidecars: [withText, without])

    #expect(library.recordings.count == 2)
    #expect(library.recordings.first(where: { $0.id == "aaa" })?.transcript?.text == "hello there")
    #expect(library.recordings.first(where: { $0.id == "bbb" })?.transcript == nil)
}

/// A transcript whose stored signature belongs to a different recording is
/// refused by `TranscriptStore`, and the store must surface that as "not
/// transcribed" rather than showing someone else's words.
@MainActor
@Test func aMismatchedTranscriptIsTreatedAsAbsent() async throws {
    let root = tempRoot()
    let store = TranscriptStore(root: root)
    let mine = storeSidecar("mine")
    let theirs = Sidecar(signature: "theirs", deviceFilename: "t.hda",
                         relativePath: mine.relativePath, lengthBytes: 10,
                         durationSeconds: 60, recordedAt: nil,
                         syncedAt: Date(timeIntervalSince1970: 1), deviceSerial: "S",
                         deviceModel: "hidock-p1", timeZoneIdentifier: "Asia/Manila")

    try store.write(TranscriptBody(text: "a different meeting", segments: [],
                                   locale: "en_US", backend: "speechanalyzer", modelID: "m"),
                    for: theirs, at: Date(timeIntervalSince1970: 1))

    let library = LibraryStore()
    await library.load(root: root, sidecars: [mine])

    #expect(library.recordings.first?.transcript == nil)
}

@MainActor
@Test func loadingClearsWhenItFinishes() async {
    let library = LibraryStore()
    await library.load(root: tempRoot(), sidecars: [])

    #expect(library.isLoading == false)
    #expect(library.recordings.isEmpty)
}

@MainActor
@Test func aSecondLoadReplacesRatherThanAppends() async {
    let root = tempRoot()
    let library = LibraryStore()

    await library.load(root: root, sidecars: [storeSidecar("aaa")])
    await library.load(root: root, sidecars: [storeSidecar("bbb")])

    #expect(library.recordings.map(\.id) == ["bbb"])
}
