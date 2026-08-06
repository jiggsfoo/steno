import Foundation
import SQLite3
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
/// recreated — which is safe precisely because the index is derived, PROVIDED
/// something refills it afterwards. `AppModel.start()` is that something,
/// gated on `didRecreateTable`; this test proves the signal the gate reads,
/// and that a row genuinely present under v1 is genuinely gone (not just
/// superseded) until something re-upserts it.
@Test func aV1DatabaseIsRecreatedAtV2() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("index.sqlite")

    // Genuine pre-migration schema AND DATA, built OUTSIDE LibraryIndex so it
    // really lacks the four spec-2 columns, and really has a row for the
    // migration to lose. Going through LibraryIndex(url:schemaVersionOverride:)
    // would NOT produce this — it creates the full v2 table and only stamps a
    // lower user_version, so there would be no real row at risk and this test
    // could not have caught `AppModel.start()` skipping the refill.
    var raw: OpaquePointer?
    #expect(sqlite3_open(url.path, &raw) == SQLITE_OK)
    #expect(sqlite3_exec(raw, """
        CREATE TABLE recordings (
            signature TEXT PRIMARY KEY,
            device_filename TEXT NOT NULL,
            relative_path TEXT NOT NULL,
            length_bytes INTEGER NOT NULL,
            duration_seconds REAL,
            recorded_at REAL,
            synced_at REAL NOT NULL,
            device_serial TEXT NOT NULL,
            device_model TEXT NOT NULL,
            timezone TEXT NOT NULL
        );
        INSERT INTO recordings
          (signature, device_filename, relative_path, length_bytes,
           duration_seconds, recorded_at, synced_at, device_serial, device_model, timezone)
        VALUES
          ('c8357e00d535682319c8e19d50685d1a', '2026Aug05-130006-Rec09.hda',
           '2026-08-05/130006-c8357e00.mp3', 47814924, 3984.576, 1754370006,
           1754380000, 'HDP1254506027', 'hidock-p1', 'Asia/Manila');
        PRAGMA user_version = 1;
        """, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(raw)

    // Opening at v2 drops the v1 table — the row above is genuinely gone, not
    // merely superseded — and reports that it happened.
    let v2 = try LibraryIndex(url: url)
    #expect(v2.didRecreateTable)
    #expect(v2.record(signature: "c8357e00d535682319c8e19d50685d1a") == nil)

    // That signal is exactly what `AppModel.start()` uses to know it must
    // call `rebuildIndex()`. Simulated here by re-upserting the same
    // recording — standing in for `rebuildIndex()`'s real sidecar rescan —
    // and asserting the ORIGINAL row's signature is present again afterwards.
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
    #expect(read.transcribedAt == sidecar.transcribedAt)
    #expect(read.transcriptBackend == "B")
}
