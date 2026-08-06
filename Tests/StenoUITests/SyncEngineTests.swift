import Foundation
import Testing
@testable import JensenKit
@testable import StenoUI

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

/// The spec's headline safety property: sync copies, it never deletes. The
/// fake records every delete it is asked for, and this is the assertion that
/// makes recording it mean something.
@Test func syncNeverDeletesFromTheDevice() async throws {
    let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let (engine, _, _) = try makeEngine(root: root)

    let a = file("20260804143022REC001.mp3", 4, sig: "sa")
    let b = file("20260804150000REC002.mp3", 3, sig: "sb")
    let device = FakeDevice(files: [a, b],
                            payloads: [a.name: Data([1, 2, 3, 4]), b.name: Data([5, 6, 7])])

    _ = try await engine.sync(device: device, serial: "SN1") { _ in }
    _ = try await engine.sync(device: device, serial: "SN1") { _ in }   // re-sync too

    #expect(await device.deletedNames.isEmpty)
}

/// Actors are reentrant, so two overlapping syncs would compute the same
/// pending set and race on the same staging file.
///
/// The property that matters is that the two calls never BOTH reach the
/// device at once -- not that the second one specifically gets rejected.
/// Under load the two can simply serialize (the first completes before the
/// second's turn on the actor even starts), which is correct behaviour and
/// would make an "exactly one succeeds" assertion fail for no real reason.
/// `maxConcurrentListFiles` is the direct observable, mirroring
/// `FakeTransport.overlappingWrites` in JensenKitTests: it can only exceed 1
/// if `SyncEngine`'s `isSyncing` guard lets two `sync()` calls both reach
/// `listFiles()` at the same time, regardless of how each one resolves.
@Test func twoConcurrentSyncsNeverBothReachTheDevice() async throws {
    let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let (engine, _, _) = try makeEngine(root: root)

    let a = file("20260804143022REC001.mp3", 4, sig: "sa")
    let device = FakeDevice(files: [a], payloads: [a.name: Data([1, 2, 3, 4])])

    async let first = engine.sync(device: device, serial: "SN1") { _ in }
    async let second = engine.sync(device: device, serial: "SN1") { _ in }
    _ = await [try? first, try? second]

    #expect(await device.maxConcurrentListFiles == 1)
}

/// Reclaim must re-verify at call time. A file removed from disk after
/// reclaimable() listed it must NOT be deleted from the device.
@Test func reclaimSkipsFilesNoLongerOnDisk() async throws {
    let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let (engine, library, _) = try makeEngine(root: root)

    let a = file("20260804143022REC001.mp3", 4, sig: "sa")
    let device = FakeDevice(files: [a], payloads: [a.name: Data([1, 2, 3, 4])])
    _ = try await engine.sync(device: device, serial: "SN1") { _ in }

    #expect(try await engine.reclaimable(device: device).count == 1)

    // Pull the local copy out from under it.
    try FileManager.default.removeItem(at: library.destinationURL(for: a))

    let result = try await engine.deleteFromDevice([a], device: device)
    #expect(result.deleted.isEmpty)
    #expect(result.skipped == [a.name])
    #expect(await device.deletedNames.isEmpty)
}

/// A device that accepts the command but still lists the file afterwards must
/// be reported as failed, not deleted. The DELETE_FILE response format is
/// unverified, so the listing is the only trustworthy confirmation.
@Test func reclaimReportsFailureWhenTheDeviceStillListsTheFile() async throws {
    let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let (engine, _, _) = try makeEngine(root: root)

    let a = file("20260804143022REC001.mp3", 4, sig: "sa")
    let device = FakeDevice(files: [a], payloads: [a.name: Data([1, 2, 3, 4])],
                            ignoreDeletes: true)
    _ = try await engine.sync(device: device, serial: "SN1") { _ in }

    let result = try await engine.deleteFromDevice([a], device: device)
    #expect(result.deleted.isEmpty)
    #expect(result.failed == [a.name])
}

/// If the confirmation listing fails we know nothing about what happened, so
/// every file must be reported as failed. Reporting them deleted would
/// overstate a destructive action on precisely the evidence we could not get.
@Test func reclaimReportsFailureWhenConfirmationCannotBeObtained() async throws {
    let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let (engine, _, _) = try makeEngine(root: root)

    let a = file("20260804143022REC001.mp3", 4, sig: "sa")
    let device = FakeDevice(files: [a], payloads: [a.name: Data([1, 2, 3, 4])],
                            failListAfterDelete: true)
    _ = try await engine.sync(device: device, serial: "SN1") { _ in }

    let result = try await engine.deleteFromDevice([a], device: device)
    #expect(result.deleted.isEmpty)
    #expect(result.failed == [a.name])
}

/// Disk-full is a spec-named handled case with zero prior coverage: it must
/// be reported per-file via `SyncError.insufficientSpace`, not crash the sync
/// or silently drop the recording.
@Test func syncReportsInsufficientSpaceAsAPerFileFailure() async throws {
    let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let (engine, _, index) = try makeEngine(root: root)

    // No real machine has 10 TB free; `Library.hasFreeSpace` will say no.
    let huge = file("20260804143022REC001.mp3", 10_000_000_000_000, sig: "sbig")
    let device = FakeDevice(files: [huge], payloads: [huge.name: Data([1, 2, 3, 4])])

    let result = try await engine.sync(device: device, serial: "SN1") { _ in }
    #expect(result.downloaded.isEmpty)
    #expect(result.failed.count == 1)
    #expect(result.failed.first?.name == huge.name)
    #expect(index.contains(signature: "sbig") == false)

    let error = try #require(result.failed.first?.error as? SyncError)
    guard case .insufficientSpace = error else {
        Issue.record("expected .insufficientSpace, got \(error)")
        return
    }
}

/// Finding 3 / approved spec decision: identity is the signature, not the
/// path. `isAlreadySynced` must locate a recording via the INDEX's recorded
/// `relativePath`, not by recomputing a fresh path from `FileInfo` — or a
/// rename/move within the library looks like a missing file and gets
/// silently re-downloaded as a duplicate at the original computed name.
///
/// Mutation check: reverting `isAlreadySynced` to check only
/// `library.destinationURL(for:)` makes this test fail, because the freshly
/// computed path is empty after the move below while the indexed path is not.
@Test func isAlreadySyncedFindsARenamedRecordingByItsIndexedPath() async throws {
    let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let (engine, library, index) = try makeEngine(root: root)

    let a = file("20260804143022REC001.mp3", 4, sig: "sa")
    let device = FakeDevice(files: [a], payloads: [a.name: Data([1, 2, 3, 4])])

    _ = try await engine.sync(device: device, serial: "SN1") { _ in }

    // Simulate a Finder rename/move: relocate the committed audio, and have
    // the index record where it actually lives now — exactly what a
    // rename-aware index entry looks like, independent of how it got there.
    let original = library.destinationURL(for: a)
    let renamed = root.appendingPathComponent("moved-by-user.mp3")
    try FileManager.default.moveItem(at: original, to: renamed)

    var record = try #require(index.record(signature: "sa"))
    record.relativePath = "moved-by-user.mp3"
    try index.upsert(record)

    // Sync again with the identical FileInfo. The freshly computed path is
    // now empty, but the recording is still on disk where the index says.
    let result = try await engine.sync(device: device, serial: "SN1") { _ in }

    #expect(result.downloaded.isEmpty)
    #expect(result.skipped == 1)
    #expect(FileManager.default.fileExists(atPath: original.path) == false)
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
