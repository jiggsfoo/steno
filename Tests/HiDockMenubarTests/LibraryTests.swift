import Foundation
import Testing
@testable import HiDockKit
@testable import HiDockMenubar

private func tempRoot() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

private func sampleFile(name: String = "20260804143022REC001.mp3", length: Int = 4) -> FileInfo {
    FileInfo(name: name, lengthBytes: length, signature: "sig-\(name)",
             version: 1, recordedAt: ResponseParsers.recordedAt(fromFilename: name))
}

@Test func destinationIsDateFolderedWithCorrectedExtension() {
    let lib = Library(root: URL(fileURLWithPath: "/tmp/x"))
    let url = lib.destinationURL(for: sampleFile())
    #expect(url.deletingLastPathComponent().lastPathComponent == "2026-08-04")
    #expect(url.lastPathComponent == "143022.mp3")
}

/// A device-named `.hda` must land as `.mp3`; the bytes are already MP3.
@Test func hdaRecordingLandsAsMp3() {
    let lib = Library(root: URL(fileURLWithPath: "/tmp/x"))
    let file = FileInfo(name: "2026Aug04-135302-Wip02.hda", lengthBytes: 53568,
                        signature: "sig", version: 5,
                        recordedAt: ResponseParsers.recordedAt(fromFilename: "2026Aug04-135302-Wip02.hda"))
    #expect(lib.destinationURL(for: file).lastPathComponent == "135302.mp3")
}

@Test func commitMovesFileAndWritesSidecar() throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let lib = Library(root: root)
    let file = sampleFile()

    let incoming = lib.incomingURL(for: file)
    try FileManager.default.createDirectory(
        at: incoming.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data([1, 2, 3, 4]).write(to: incoming)

    let sidecar = try lib.commit(incoming: incoming, file: file, deviceSerial: "SN1")

    let audio = lib.destinationURL(for: file)
    #expect(FileManager.default.fileExists(atPath: audio.path))
    #expect(FileManager.default.fileExists(atPath: incoming.path) == false)

    let json = audio.deletingPathExtension().appendingPathExtension("json")
    #expect(FileManager.default.fileExists(atPath: json.path))
    #expect(sidecar.signature == file.signature)
    #expect(sidecar.lengthBytes == 4)
    #expect(sidecar.deviceSerial == "SN1")
}

@Test func scanSidecarsFindsEveryCommittedRecording() throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let lib = Library(root: root)

    for name in ["20260804143022REC001.mp3", "20260805090000REC002.wav"] {
        let f = sampleFile(name: name)
        let incoming = lib.incomingURL(for: f)
        try FileManager.default.createDirectory(
            at: incoming.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3, 4]).write(to: incoming)
        _ = try lib.commit(incoming: incoming, file: f, deviceSerial: "SN1")
    }

    #expect(try lib.scanSidecars().count == 2)
}

@Test func reachabilityIsFalseForMissingRoot() {
    let lib = Library(root: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
    #expect(lib.isReachable() == false)
}
