// Tests/JensenKitTests/TransferTests.swift
import Foundation
import Testing
@testable import JensenKit

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
}

private func makeFile(length: Int) -> FileInfo {
    FileInfo(name: "20260804143022REC001.mp3", lengthBytes: length,
             signature: "abc123", version: 1, recordedAt: nil)
}

@Test func transferWritesAllBytesToDisk() async throws {
    let payload = Data((0..<5000).map { UInt8($0 % 251) })
    let chunks = stride(from: 0, to: payload.count, by: 1000).map {
        payload.subdata(in: $0 ..< min($0 + 1000, payload.count))
    }
    let t = FakeTransport(script: .init(responses: [5: chunks]))
    let device = JensenDevice(transport: t)
    try await device.open()

    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    try await device.transferFile(makeFile(length: payload.count), to: url) { _, _ in }

    #expect(try Data(contentsOf: url) == payload)
}

@Test func transferReportsProgress() async throws {
    let chunks = (0..<4).map { _ in Data(repeating: 1, count: 250) }
    let t = FakeTransport(script: .init(responses: [5: chunks]))
    let device = JensenDevice(transport: t)
    try await device.open()

    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url) }

    final class Box: @unchecked Sendable { var seen: [Int] = [] }
    let box = Box()
    try await device.transferFile(makeFile(length: 1000), to: url) { done, _ in
        box.seen.append(done)
    }
    #expect(box.seen.last == 1000)
    #expect(box.seen.count >= 2)
}

/// The gate must be released even when a transfer fails, or the device wedges
/// permanently. Also the regression test for transferFile calling the GATED
/// public drain() instead of drainLocked — that self-deadlocks, and this test
/// would hang rather than fail.
@Test func gateSurvivesAFailedTransfer() async throws {
    let t = FakeTransport(script: .init(responses: [
        5: [Data(repeating: 1, count: 100)],
        1: [Data(repeating: 0, count: 20)],
    ]))
    let device = JensenDevice(transport: t)
    try await device.open()
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url) }

    _ = try? await device.transferFile(
        makeFile(length: 1000), to: url, chunkTimeout: .milliseconds(200)) { _, _ in }

    // Any gated command completing proves the gate came back.
    #expect(try await device.send(.getDeviceInfo, timeout: .seconds(2)).count == 20)
}

/// A failed transfer must not destroy a good file already at the destination.
@Test func failedTransferLeavesAnExistingFileIntact() async throws {
    let t = FakeTransport(script: .init(responses: [5: [Data(repeating: 1, count: 100)]]))
    let device = JensenDevice(transport: t)
    try await device.open()

    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let original = Data("already here".utf8)
    try original.write(to: url)

    _ = try? await device.transferFile(
        makeFile(length: 1000), to: url, chunkTimeout: .milliseconds(200)) { _, _ in }

    #expect(try Data(contentsOf: url) == original)
}

/// A device sending more than it advertised must not overflow the file.
@Test func overLongStreamIsClampedToTheAdvertisedLength() async throws {
    let t = FakeTransport(script: .init(responses: [5: [Data(repeating: 9, count: 500)]]))
    let device = JensenDevice(transport: t)
    try await device.open()

    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    try await device.transferFile(
        makeFile(length: 200), to: url, chunkTimeout: .seconds(2)) { _, _ in }

    #expect(try Data(contentsOf: url).count == 200)
}

@Test func transferThrowsAndRemovesPartialOnShortStream() async throws {
    let t = FakeTransport(script: .init(responses: [5: [Data(repeating: 1, count: 100)]]))
    let device = JensenDevice(transport: t)
    try await device.open()

    let url = tempURL()
    // Pass a short chunkTimeout explicitly. The default is 30 s, and this test
    // deliberately starves the stream, so it would otherwise sit out the whole
    // deadline -- a 30-second unit test that slows every later task's run.
    await #expect(throws: JensenError.transferIncomplete(expected: 1000, got: 100)) {
        try await device.transferFile(
            makeFile(length: 1000), to: url, chunkTimeout: .milliseconds(200)) { _, _ in }
    }
    #expect(FileManager.default.fileExists(atPath: url.path) == false)
}
