import Foundation
import Testing
@testable import JensenKit
@testable import StenoUI

private func tempRoot() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

private func sampleFile(name: String = "20260804143022REC001.mp3", length: Int = 4) -> FileInfo {
    FileInfo(name: name, lengthBytes: length, signature: "sig-\(name)",
             version: 1, recordedAt: ResponseParsers.recordedAt(fromFilename: name))
}

@Test func destinationIsDateFolderedWithSignatureSuffix() {
    let lib = Library(root: URL(fileURLWithPath: "/tmp/x"))
    let url = lib.destinationURL(for: sampleFile())
    #expect(url.deletingLastPathComponent().lastPathComponent == "2026-08-04")
    #expect(url.lastPathComponent.hasPrefix("143022-"))
    #expect(url.pathExtension == "mp3")
}

/// A device-named `.hda` must land as `.mp3`; the bytes are already MP3.
@Test func hdaRecordingLandsAsMp3() {
    let lib = Library(root: URL(fileURLWithPath: "/tmp/x"))
    let name = "2026Aug04-135302-Wip02.hda"
    let file = FileInfo(name: name, lengthBytes: 53568, signature: "c74e0ac92b1708dd",
                        version: 5, recordedAt: ResponseParsers.recordedAt(fromFilename: name))
    #expect(lib.destinationURL(for: file).lastPathComponent == "135302-c74e0ac9.mp3")
}

/// Two recordings in the same second must NOT resolve to one path. Keyed on
/// timestamp alone they did, and commit deleted before it moved — silently
/// destroying the earlier recording.
@Test func sameSecondRecordingsGetDistinctPaths() {
    let lib = Library(root: URL(fileURLWithPath: "/tmp/x"))
    let a = sampleFile(name: "20260804143022REC001.mp3")
    let b = FileInfo(name: "20260804143022REC002.mp3", lengthBytes: 9, signature: "ffffffffffff",
                     version: 1, recordedAt: a.recordedAt)
    #expect(lib.destinationURL(for: a) != lib.destinationURL(for: b))
}

/// An unparseable filename must still resolve to a STABLE path. The old
/// fallback was `Date()`, so every undated recording collided with every
/// other one and moved on every sync.
@Test func undatedRecordingsGetStableDistinctPaths() {
    let lib = Library(root: URL(fileURLWithPath: "/tmp/x"))
    let a = FileInfo(name: "mystery.hda", lengthBytes: 1, signature: "aaaaaaaaaaaaaaaaaaaa",
                     version: 1, recordedAt: nil)
    let b = FileInfo(name: "other.hda", lengthBytes: 1, signature: "bbbbbbbbbbbbbbbbbbbb",
                     version: 1, recordedAt: nil)
    #expect(lib.destinationURL(for: a) == lib.destinationURL(for: a))   // stable
    #expect(lib.destinationURL(for: a) != lib.destinationURL(for: b))   // distinct
    #expect(lib.destinationURL(for: a).deletingLastPathComponent().lastPathComponent == "undated")
}

/// commit must refuse to overwrite a DIFFERENT recording rather than destroy it.
@Test func commitRefusesToClobberADifferentRecording() throws {
    let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let lib = Library(root: root)

    let first = sampleFile()
    let incoming = lib.incomingURL(for: first)
    try FileManager.default.createDirectory(
        at: incoming.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data([1, 2, 3, 4]).write(to: incoming)
    _ = try lib.commit(incoming: incoming, file: first, deviceSerial: "SN1")

    // Same computed path, different signature: force the collision by hand.
    let impostor = FileInfo(name: first.name, lengthBytes: 4,
                            signature: first.signature, version: 1, recordedAt: first.recordedAt)
    let clobberPath = lib.destinationURL(for: impostor)
    let sidecarPath = clobberPath.deletingPathExtension().appendingPathExtension("json")
    let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
    var stored = try dec.decode(Sidecar.self, from: Data(contentsOf: sidecarPath))
    stored.signature = "a-completely-different-recording"
    let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
    try enc.encode(stored).write(to: sidecarPath)

    let second = lib.incomingURL(for: impostor)
    try Data([9, 9, 9, 9]).write(to: second)
    #expect(throws: (any Error).self) {
        _ = try lib.commit(incoming: second, file: impostor, deviceSerial: "SN1")
    }
    // The original audio must still be there and unchanged.
    #expect(try Data(contentsOf: clobberPath) == Data([1, 2, 3, 4]))
}

/// The index is a DERIVED cache. This is the invariant that makes that true:
/// a full folder walk must reconstruct it exactly.
@Test func indexIsFullyReconstructableFromAFolderWalk() throws {
    let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let lib = Library(root: root)
    let index = try LibraryIndex(url: root.appendingPathComponent("index.sqlite"))

    var committed: [Sidecar] = []
    for name in ["20260804143022REC001.mp3", "20260805090000REC002.wav"] {
        let f = sampleFile(name: name)
        let incoming = lib.incomingURL(for: f)
        try FileManager.default.createDirectory(
            at: incoming.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3, 4]).write(to: incoming)
        let sc = try lib.commit(incoming: incoming, file: f, deviceSerial: "SN1")
        committed.append(sc)
        try index.upsert(sc)
    }

    // Nuke the index entirely, then rebuild it from disk alone.
    try index.rebuild(from: [])
    #expect(try index.all().isEmpty)
    try index.rebuild(from: lib.scanSidecars())

    #expect(Set(try index.all().map(\.signature)) == Set(committed.map(\.signature)))
    for sc in committed { #expect(index.contains(signature: sc.signature)) }
}

/// The sidecar is the source of truth, so every field must survive the round
/// trip to disk — including relativePath, which reveal-in-Finder depends on.
@Test func sidecarRoundTripsEveryFieldThroughDisk() throws {
    let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let lib = Library(root: root)
    let file = sampleFile()

    let incoming = lib.incomingURL(for: file)
    try FileManager.default.createDirectory(
        at: incoming.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data([1, 2, 3, 4]).write(to: incoming)
    let written = try lib.commit(incoming: incoming, file: file, deviceSerial: "SN1")

    #expect(FileManager.default.fileExists(atPath: incoming.path) == false)
    #expect(FileManager.default.fileExists(atPath: lib.destinationURL(for: file).path))

    let decoded = try #require(lib.scanSidecars().first)
    #expect(decoded.signature == written.signature)
    #expect(decoded.deviceFilename == file.name)
    #expect(decoded.relativePath == written.relativePath)
    #expect(decoded.lengthBytes == 4)                       // measured on disk, not device-reported
    #expect(decoded.deviceSerial == "SN1")
    #expect(decoded.deviceModel == "hidock-p1")
    #expect(decoded.timeZoneIdentifier == TimeZone.current.identifier)

    // relativePath must actually locate the file under the root.
    let resolved = root.appendingPathComponent(decoded.relativePath)
    #expect(FileManager.default.fileExists(atPath: resolved.path))
    #expect(decoded.relativePath.hasPrefix("2026-08-04/"))
}

/// Re-syncing the SAME recording must be safe. The overwrite path previously
/// deleted the old audio and sidecar before installing the new ones, so a
/// failure in between destroyed a recording that was already safely stored.
@Test func resyncingTheSameRecordingReplacesItCleanly() throws {
    let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let lib = Library(root: root)
    let file = sampleFile()

    func commitOnce(_ bytes: Data) throws -> Sidecar {
        let incoming = lib.incomingURL(for: file)
        try FileManager.default.createDirectory(
            at: incoming.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: incoming)
        return try lib.commit(incoming: incoming, file: file, deviceSerial: "SN1")
    }

    _ = try commitOnce(Data([1, 2, 3, 4]))
    _ = try commitOnce(Data([5, 6, 7, 8]))

    let audio = lib.destinationURL(for: file)
    #expect(try Data(contentsOf: audio) == Data([5, 6, 7, 8]))
    #expect(try lib.scanSidecars().count == 1)          // exactly one, not two
}

/// A sidecar that exists but will not decode might describe any recording, so
/// commit must refuse rather than overwrite on an assumption.
@Test func commitRefusesWhenTheExistingSidecarIsUnreadable() throws {
    let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let lib = Library(root: root)
    let file = sampleFile()

    let sidecarPath = lib.sidecarURL(for: file)
    try FileManager.default.createDirectory(
        at: sidecarPath.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("not json at all".utf8).write(to: sidecarPath)

    let incoming = lib.incomingURL(for: file)
    try FileManager.default.createDirectory(
        at: incoming.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data([1, 2, 3, 4]).write(to: incoming)

    #expect(throws: (any Error).self) {
        _ = try lib.commit(incoming: incoming, file: file, deviceSerial: "SN1")
    }
}

@Test func reachabilityIsFalseForMissingRoot() {
    let lib = Library(root: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
    #expect(lib.isReachable() == false)
}

/// Disk-full is a spec-named handled case (see `SyncError.insufficientSpace`)
/// that had zero coverage.
@Test func hasFreeSpaceIsTrueForATrivialRequest() {
    let lib = Library(root: FileManager.default.temporaryDirectory)
    #expect(lib.hasFreeSpace(forBytes: 10))
}

@Test func hasFreeSpaceIsFalseWhenTheRequestExceedsAvailableCapacity() {
    let lib = Library(root: FileManager.default.temporaryDirectory)
    // 10 TB: far more than any real test machine has free, but small enough
    // not to overflow the Int64 addition inside hasFreeSpace.
    #expect(lib.hasFreeSpace(forBytes: 10_000_000_000_000) == false)
}
