import Foundation
import HiDockKit
@testable import HiDockMenubar

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
