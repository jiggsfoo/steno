import Foundation
import JensenKit
@testable import StenoUI

actor FakeDevice: SyncDevice {
    var files: [FileInfo]
    var payloads: [String: Data]
    var failTransfersFor: Set<String>
    /// Simulates a device that accepts DELETE_FILE but does not act on it —
    /// the case a status byte we cannot parse would hide.
    var ignoreDeletes: Bool
    /// Simulates the confirmation listing failing after deletes were issued.
    var failListAfterDelete: Bool
    private(set) var deletedNames: [String] = []

    /// Entry/exit counter around `listFiles`, mirroring
    /// `FakeTransport.overlappingWrites` in JensenKitTests: the direct
    /// observable for "two callers were ever inside at once". `listFiles`
    /// yields once internally specifically so this can be nonzero if
    /// `SyncEngine`'s `isSyncing` guard were ever removed -- without a
    /// suspension point inside the method, actor isolation alone would
    /// serialize any two calls and the counter could never exceed 1
    /// regardless of whether the guard actually works.
    private var activeListFiles = 0
    private(set) var maxConcurrentListFiles = 0

    init(files: [FileInfo], payloads: [String: Data],
         failTransfersFor: Set<String> = [], ignoreDeletes: Bool = false,
         failListAfterDelete: Bool = false) {
        self.files = files
        self.payloads = payloads
        self.failTransfersFor = failTransfersFor
        self.ignoreDeletes = ignoreDeletes
        self.failListAfterDelete = failListAfterDelete
    }

    func listFiles() async throws -> [FileInfo] {
        activeListFiles += 1
        maxConcurrentListFiles = max(maxConcurrentListFiles, activeListFiles)
        defer { activeListFiles -= 1 }
        // See `maxConcurrentListFiles`'s doc comment -- this yield is what
        // gives a second overlapping call an actual chance to be observed.
        await Task.yield()

        if failListAfterDelete && !deletedNames.isEmpty {
            throw JensenError.timeout(command: 4)
        }
        return files
    }

    func transferFile(_ file: FileInfo, to url: URL, chunkTimeout: Duration,
                      progress: @Sendable (Int, Int) -> Void) async throws {
        if failTransfersFor.contains(file.name) {
            throw JensenError.transferIncomplete(expected: file.lengthBytes, got: 0)
        }
        let data = payloads[file.name] ?? Data()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        progress(data.count, file.lengthBytes)
    }

    func deleteFile(named name: String) async throws {
        deletedNames.append(name)
        // A real device drops the file from its listing. Modelling that is what
        // lets deleteFromDevice's confirmation step be tested at all.
        if !ignoreDeletes { files.removeAll { $0.name == name } }
    }
}
