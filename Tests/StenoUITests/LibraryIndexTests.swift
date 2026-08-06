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
