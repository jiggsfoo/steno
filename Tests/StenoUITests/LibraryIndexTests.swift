import Foundation
import Testing
@testable import StenoUI

private func tempDB() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
}

private func sidecar(_ sig: String, recordedAt: Date = Date(timeIntervalSince1970: 0)) -> Sidecar {
    Sidecar(signature: sig, deviceFilename: "\(sig).mp3", relativePath: "2026-08-04/\(sig).mp3",
            lengthBytes: 100, durationSeconds: 12.5, recordedAt: recordedAt,
            syncedAt: Date(timeIntervalSince1970: 10), deviceSerial: "SN1",
            deviceModel: "hidock-p1", timeZoneIdentifier: "Asia/Manila")
}

private func freshIndexURL() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("index.sqlite")
}

private func indexSampleSidecar(
    title: String? = nil, topic: String? = nil, backend: String? = nil
) -> Sidecar {
    Sidecar(signature: "c8357e00d535682319c8e19d50685d1a",
            deviceFilename: "2026Aug05-130006-Rec09.hda",
            relativePath: "2026-08-05/130006-c8357e00.mp3",
            lengthBytes: 47_814_924,
            durationSeconds: 3984.576,
            recordedAt: Date(timeIntervalSince1970: 1_754_370_006),
            syncedAt: Date(timeIntervalSince1970: 1_754_380_000),
            deviceSerial: "HDP1254506027",
            deviceModel: "hidock-p1",
            timeZoneIdentifier: "Asia/Manila",
            title: title,
            topic: topic,
            transcribedAt: title == nil ? nil : Date(timeIntervalSince1970: 1_754_390_000),
            transcriptBackend: backend,
            transcriptionAttempts: nil)
}

@Test func upsertThenContains() throws {
    let url = tempDB(); defer { try? FileManager.default.removeItem(at: url) }
    let index = try LibraryIndex(url: url)
    #expect(index.contains(signature: "a") == false)
    try index.upsert(sidecar("a"))
    #expect(index.contains(signature: "a"))
}

@Test func upsertIsIdempotent() throws {
    let url = tempDB(); defer { try? FileManager.default.removeItem(at: url) }
    let index = try LibraryIndex(url: url)
    try index.upsert(sidecar("a"))
    try index.upsert(sidecar("a"))
    #expect(try index.all().count == 1)
}

@Test func recentIsNewestFirstAndLimited() throws {
    let url = tempDB(); defer { try? FileManager.default.removeItem(at: url) }
    let index = try LibraryIndex(url: url)
    try index.upsert(sidecar("old", recordedAt: Date(timeIntervalSince1970: 100)))
    try index.upsert(sidecar("new", recordedAt: Date(timeIntervalSince1970: 900)))
    try index.upsert(sidecar("mid", recordedAt: Date(timeIntervalSince1970: 500)))

    #expect(try index.recent(limit: 2).map(\.signature) == ["new", "mid"])
}

@Test func rebuildReplacesEverything() throws {
    let url = tempDB(); defer { try? FileManager.default.removeItem(at: url) }
    let index = try LibraryIndex(url: url)
    try index.upsert(sidecar("stale"))
    try index.rebuild(from: [sidecar("x"), sidecar("y")])
    #expect(Set(try index.all().map(\.signature)) == ["x", "y"])
}

@Test func roundTripsAllSidecarFields() throws {
    let url = tempDB(); defer { try? FileManager.default.removeItem(at: url) }
    let index = try LibraryIndex(url: url)
    let s = sidecar("a")
    try index.upsert(s)
    let back = try #require(try index.all().first)
    #expect(back == s)
}

/// `migrate()` only ever ran CREATE TABLE IF NOT EXISTS, so it cannot add a
/// column to a table that already exists. A v1 database must be dropped and
/// recreated — which is safe precisely because the index is derived.
@Test func aV1DatabaseIsRecreatedAtV2() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("index.sqlite")

    // A v1 index holding one row.
    let v1 = try LibraryIndex(url: url, schemaVersionOverride: 1)
    try v1.upsert(indexSampleSidecar())
    #expect(v1.contains(signature: indexSampleSidecar().signature))

    // Reopening at v2 must not throw on the missing columns.
    let v2 = try LibraryIndex(url: url)
    let refilled = indexSampleSidecar(title: "Grocery list", topic: "Grocery List")
    try v2.upsert(refilled)

    #expect(v2.record(signature: refilled.signature)?.title == "Grocery list")
    #expect(v2.record(signature: refilled.signature)?.topic == "Grocery List")
}

@Test func titleAndTopicSurviveARoundTrip() throws {
    let index = try LibraryIndex(url: freshIndexURL())
    let sidecar = indexSampleSidecar(title: "Tuesday supplier call",
                                     topic: "Grocery List",
                                     backend: "speechanalyzer")
    try index.upsert(sidecar)

    let read = try #require(index.record(signature: sidecar.signature))
    #expect(read.title == "Tuesday supplier call")
    #expect(read.topic == "Grocery List")
    #expect(read.transcriptBackend == "speechanalyzer")
    #expect(read.transcriptionAttempts == nil)   // not an indexed column
}

/// `decode(_:)` reads columns BY POSITION from `SELECT *`. A new column
/// inserted rather than appended shifts every field after it, silently. This
/// test is the only thing standing between that mistake and a corrupted menu.
@Test func columnOrderMatchesTheDecoderPositions() throws {
    let index = try LibraryIndex(url: freshIndexURL())
    let sidecar = indexSampleSidecar(title: "T", topic: "P", backend: "B")
    try index.upsert(sidecar)

    let read = try #require(index.record(signature: sidecar.signature))
    #expect(read.signature == sidecar.signature)
    #expect(read.deviceFilename == sidecar.deviceFilename)
    #expect(read.relativePath == sidecar.relativePath)
    #expect(read.lengthBytes == sidecar.lengthBytes)
    #expect(read.deviceSerial == sidecar.deviceSerial)
    #expect(read.deviceModel == "hidock-p1")
    #expect(read.timeZoneIdentifier == sidecar.timeZoneIdentifier)
    #expect(read.title == "T")
    #expect(read.topic == "P")
    #expect(read.transcriptBackend == "B")
}
