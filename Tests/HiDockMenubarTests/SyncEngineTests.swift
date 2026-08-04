import Foundation
import Testing
@testable import HiDockKit
@testable import HiDockMenubar

private func tempRoot() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

private func makeEngine(root: URL) throws -> (SyncEngine, Library, LibraryIndex) {
    let library = Library(root: root)
    let index = try LibraryIndex(url: root.appendingPathComponent("index.sqlite"))
    return (SyncEngine(library: library, index: index), library, index)
}

private func file(_ name: String, _ bytes: Int, sig: String) -> FileInfo {
    FileInfo(name: name, lengthBytes: bytes, signature: sig, version: 1,
             recordedAt: ResponseParsers.recordedAt(fromFilename: name))
}

@Test func freshSyncDownloadsEverything() async throws {
    let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let (engine, library, _) = try makeEngine(root: root)

    let a = file("20260804143022REC001.mp3", 4, sig: "sa")
    let b = file("20260804150000REC002.mp3", 3, sig: "sb")
    let device = FakeDevice(files: [a, b],
                            payloads: [a.name: Data([1, 2, 3, 4]), b.name: Data([5, 6, 7])])

    let result = try await engine.sync(device: device, serial: "SN1") { _ in }
    #expect(result.downloaded.count == 2)
    #expect(result.failed.isEmpty)
    #expect(FileManager.default.fileExists(atPath: library.destinationURL(for: a).path))
}

@Test func resyncIsANoOp() async throws {
    let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let (engine, _, _) = try makeEngine(root: root)

    let a = file("20260804143022REC001.mp3", 4, sig: "sa")
    let device = FakeDevice(files: [a], payloads: [a.name: Data([1, 2, 3, 4])])

    _ = try await engine.sync(device: device, serial: "SN1") { _ in }
    let second = try await engine.sync(device: device, serial: "SN1") { _ in }

    #expect(second.downloaded.isEmpty)
    #expect(second.skipped == 1)
}

@Test func failedTransferIsReportedAndNotCommitted() async throws {
    let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let (engine, library, index) = try makeEngine(root: root)

    let a = file("20260804143022REC001.mp3", 4, sig: "sa")
    let device = FakeDevice(files: [a], payloads: [:], failTransfersFor: [a.name])

    let result = try await engine.sync(device: device, serial: "SN1") { _ in }
    #expect(result.downloaded.isEmpty)
    #expect(result.failed.count == 1)
    #expect(index.contains(signature: "sa") == false)
    #expect(FileManager.default.fileExists(atPath: library.destinationURL(for: a).path) == false)
}

@Test func oneFailureDoesNotStopTheRest() async throws {
    let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let (engine, _, _) = try makeEngine(root: root)

    let bad = file("20260804143022REC001.mp3", 4, sig: "sbad")
    let good = file("20260804150000REC002.mp3", 3, sig: "sgood")
    let device = FakeDevice(files: [bad, good],
                            payloads: [good.name: Data([5, 6, 7])],
                            failTransfersFor: [bad.name])

    let result = try await engine.sync(device: device, serial: "SN1") { _ in }
    #expect(result.downloaded.map(\.signature) == ["sgood"])
    #expect(result.failed.count == 1)
}

@Test func syncFailsFastWhenLibraryUnreachable() async throws {
    let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
    let index = try LibraryIndex(url: FileManager.default.temporaryDirectory
        .appendingPathComponent("\(UUID().uuidString).sqlite"))
    let engine = SyncEngine(library: Library(root: missing), index: index)
    let device = FakeDevice(files: [], payloads: [:])

    await #expect(throws: SyncError.libraryUnreachable) {
        _ = try await engine.sync(device: device, serial: "SN1") { _ in }
    }
}

@Test func progressReportsEachPhase() async throws {
    let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let (engine, _, _) = try makeEngine(root: root)

    let a = file("20260804143022REC001.mp3", 4, sig: "sa")
    let device = FakeDevice(files: [a], payloads: [a.name: Data([1, 2, 3, 4])])

    final class Box: @unchecked Sendable { var events: [SyncProgress] = [] }
    let box = Box()
    _ = try await engine.sync(device: device, serial: "SN1") { box.events.append($0) }

    #expect(box.events.contains { if case .listing = $0 { return true }; return false })
    #expect(box.events.contains { if case .finished = $0 { return true }; return false })
}
