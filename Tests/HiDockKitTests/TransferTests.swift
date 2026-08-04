// Tests/HiDockKitTests/TransferTests.swift
import Foundation
import Testing
@testable import HiDockKit

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

@Test func transferThrowsAndRemovesPartialOnShortStream() async throws {
    let t = FakeTransport(script: .init(responses: [5: [Data(repeating: 1, count: 100)]]))
    let device = JensenDevice(transport: t)
    try await device.open()

    let url = tempURL()
    await #expect(throws: JensenError.transferIncomplete(expected: 1000, got: 100)) {
        try await device.transferFile(makeFile(length: 1000), to: url) { _, _ in }
    }
    #expect(FileManager.default.fileExists(atPath: url.path) == false)
}
