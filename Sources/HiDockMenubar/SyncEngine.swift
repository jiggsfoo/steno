import Foundation
import HiDockKit

/// The subset of JensenDevice the engine needs, so tests can fake it.
///
/// `chunkTimeout` is part of the requirement on purpose: Swift matches a
/// protocol witness on its full declaration name, and a default argument does
/// not synthesize the shorter form. Omitting it here makes
/// `extension JensenDevice: SyncDevice {}` fail to compile.
public protocol SyncDevice: Sendable, Actor {
    func listFiles() async throws -> [FileInfo]
    func transferFile(_ file: FileInfo, to url: URL, chunkTimeout: Duration,
                      progress: @Sendable (Int, Int) -> Void) async throws
    func deleteFile(named name: String) async throws
}

public enum SyncError: Error, Equatable {
    case libraryUnreachable
    case insufficientSpace(needed: Int)
    case alreadyRunning
}

/// Outcome of a reclaim. Names rather than FileInfo, so the menubar can report
/// it without holding device state.
public struct DeleteResult: Sendable, Equatable {
    /// Confirmed gone from the device's own file listing.
    public var deleted: [String] = []
    /// Not deleted because they no longer verify as present on disk.
    public var skipped: [String] = []
    /// The device errored, or still lists the file afterwards.
    public var failed: [String] = []
}

public enum SyncProgress: Sendable {
    case listing
    case downloading(name: String, index: Int, of: Int, bytesDone: Int, bytesTotal: Int)
    case finished(downloaded: Int, skipped: Int, failed: Int)
}

public struct SyncResult: Sendable {
    public var downloaded: [Sidecar] = []
    public var skipped: Int = 0
    public var failed: [(name: String, error: any Error)] = []
}

public actor SyncEngine {
    private let library: Library
    private let index: LibraryIndex

    /// Guards against overlapping runs. `sync` is an actor method with `await`
    /// points, and Swift actors are reentrant, so Task 9's auto-sync-on-attach
    /// and a manual trigger could otherwise interleave — computing the same
    /// pending set and racing on the same `.incoming` staging file.
    private var isSyncing = false

    public init(library: Library, index: LibraryIndex) {
        self.library = library
        self.index = index
    }

    /// Copies every recording not already present. Never deletes from the device.
    public func sync(
        device: any SyncDevice,
        serial: String,
        progress: @Sendable (SyncProgress) -> Void
    ) async throws -> SyncResult {
        guard !isSyncing else { throw SyncError.alreadyRunning }
        isSyncing = true
        defer { isSyncing = false }

        guard library.isReachable() else {
            progress(.finished(downloaded: 0, skipped: 0, failed: 0))
            throw SyncError.libraryUnreachable
        }

        progress(.listing)
        let files: [FileInfo]
        do {
            files = try await device.listFiles()
        } catch {
            // Always emit a terminal event, or a UI driven off progress hangs
            // on "listing" forever.
            progress(.finished(downloaded: 0, skipped: 0, failed: 0))
            throw error
        }

        // Oldest first, so an interrupted sync still makes forward progress
        // through the backlog rather than repeatedly retrying the newest file.
        // Signature breaks ties: Array.sorted is not documented stable, and every
        // undated file maps to .distantPast, so without it their relative order
        // is arbitrary between runs.
        let ordered = files.sorted {
            let l = ($0.recordedAt ?? .distantPast), r = ($1.recordedAt ?? .distantPast)
            return l == r ? $0.signature < $1.signature : l < r
        }

        var result = SyncResult()
        let pending = ordered.filter { !isAlreadySynced($0) }
        result.skipped = ordered.count - pending.count

        for (offset, file) in pending.enumerated() {
            do {
                guard library.hasFreeSpace(forBytes: file.lengthBytes) else {
                    throw SyncError.insufficientSpace(needed: file.lengthBytes)
                }

                // transferFile stages internally too, so bytes actually land in
                // `<sig>.part.part` before being moved here. Redundant but
                // harmless: the engine's `.incoming` staging is what keeps a
                // partial out of the library tree, and transferFile's is what
                // makes the write atomic. Do not "simplify" either away.
                let incoming = library.incomingURL(for: file)
                try FileManager.default.createDirectory(
                    at: incoming.deletingLastPathComponent(), withIntermediateDirectories: true)

                try await device.transferFile(
                    file, to: incoming, chunkTimeout: .seconds(30)
                ) { done, total in
                    progress(.downloading(name: file.name, index: offset + 1,
                                          of: pending.count, bytesDone: done, bytesTotal: total))
                }

                let sidecar = try library.commit(
                    incoming: incoming, file: file, deviceSerial: serial)
                try index.upsert(sidecar)
                result.downloaded.append(sidecar)
            } catch {
                try? FileManager.default.removeItem(at: library.incomingURL(for: file))
                result.failed.append((name: file.name, error: error))
            }
        }

        progress(.finished(downloaded: result.downloaded.count,
                           skipped: result.skipped,
                           failed: result.failed.count))
        return result
    }

    /// A recording counts as synced only if the index knows it *and* the bytes
    /// are still on disk at the expected length.
    private func isAlreadySynced(_ file: FileInfo) -> Bool {
        guard index.contains(signature: file.signature) else { return false }
        guard let size = Library.fileSize(at: library.destinationURL(for: file)) else {
            return false
        }
        // Compare against the LOCALLY recorded length where one exists. A check
        // that gates a destructive action should trust local truth, not the
        // device's own claim about what it is holding.
        return size == (library.sidecar(for: file)?.lengthBytes ?? file.lengthBytes)
    }

    /// Reclaim. Only ever called from the explicit menubar action.
    /// Re-verifies on disk at call time rather than trusting the index.
    public func reclaimable(device: any SyncDevice) async throws -> [FileInfo] {
        try await device.listFiles().filter { isAlreadySynced($0) }
    }

    /// Deletes from the device, then CONFIRMS against the device's own listing.
    ///
    /// The DELETE_FILE response body layout has never been verified against
    /// hardware, so a status code in it cannot be trusted. Rather than guess at
    /// one, this checks the outcome: whatever the device still lists is still
    /// there. Format-independent, and it is the only command in the project
    /// that destroys data.
    ///
    /// Per-file isolation like `sync`: one device error does not abandon the
    /// rest, and the caller can tell deleted from skipped from failed.
    public func deleteFromDevice(
        _ files: [FileInfo], device: any SyncDevice
    ) async throws -> DeleteResult {
        var result = DeleteResult()
        var requested: [FileInfo] = []

        for file in files {
            // Re-verified HERE, at call time, not trusted from the index. A file
            // removed from disk since `reclaimable()` must not be deleted.
            guard isAlreadySynced(file) else {
                result.skipped.append(file.name)
                continue
            }
            do {
                try await device.deleteFile(named: file.name)
                requested.append(file)
            } catch {
                result.failed.append(file.name)
            }
        }

        guard !requested.isEmpty else { return result }

        let stillPresent = Set((try? await device.listFiles())?.map(\.signature) ?? [])
        for file in requested {
            if stillPresent.contains(file.signature) {
                result.failed.append(file.name)
            } else {
                result.deleted.append(file.name)
            }
        }
        return result
    }
}

extension JensenDevice: SyncDevice {
    // `listFiles(timeout:)` predates this protocol and its `timeout` parameter
    // has a default, but the same witness-matching rule that requires
    // `chunkTimeout` above applies here too: a default argument does not
    // synthesize the shorter selector `listFiles()` that `SyncDevice`
    // requires. Bridge to the existing method rather than touch it.
    public func listFiles() async throws -> [FileInfo] {
        try await listFiles(timeout: .seconds(20))
    }
}
