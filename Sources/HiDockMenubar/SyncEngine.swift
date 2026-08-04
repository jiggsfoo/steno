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
        guard library.isReachable() else { throw SyncError.libraryUnreachable }

        progress(.listing)
        let files = try await device.listFiles()

        // Oldest first, so an interrupted sync still makes forward progress
        // through the backlog rather than repeatedly retrying the newest file.
        let ordered = files.sorted {
            ($0.recordedAt ?? .distantPast) < ($1.recordedAt ?? .distantPast)
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
        let url = library.destinationURL(for: file)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int else { return false }
        return size == file.lengthBytes
    }

    /// Reclaim. Only ever called from the explicit menubar action.
    /// Re-verifies on disk at call time rather than trusting the index.
    public func reclaimable(device: any SyncDevice) async throws -> [FileInfo] {
        try await device.listFiles().filter { isAlreadySynced($0) }
    }

    public func deleteFromDevice(_ files: [FileInfo], device: any SyncDevice) async throws -> Int {
        var deleted = 0
        for file in files where isAlreadySynced(file) {
            try await device.deleteFile(named: file.name)
            deleted += 1
        }
        return deleted
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
