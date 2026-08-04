import AVFoundation
import Foundation
import HiDockKit

public struct Library: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    private static let incomingFolder = ".incoming"

    public func isReachable() -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir)
            && isDir.boolValue
    }

    public func hasFreeSpace(forBytes bytes: Int) -> Bool {
        guard let values = try? root.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage else {
            return true                                  // unknown, let the write decide
        }
        return available > Int64(bytes) + 50_000_000     // keep 50 MB headroom
    }

    public func incomingURL(for file: FileInfo) -> URL {
        root.appendingPathComponent(Self.incomingFolder)
            .appendingPathComponent("\(file.signature).part")
    }

    /// `<root>/YYYY-MM-DD/HHMMSS.<corrected extension>`
    /// Uses `preferredExtension`, so a device-named `.hda` lands as `.mp3`.
    public func destinationURL(for file: FileInfo) -> URL {
        let ext = file.preferredExtension
        let date = file.recordedAt ?? Date()
        let folder = Self.dayFormatter.string(from: date)
        let stem = Self.timeFormatter.string(from: date)
        return root.appendingPathComponent(folder)
            .appendingPathComponent(ext.isEmpty ? stem : "\(stem).\(ext)")
    }

    public func sidecarURL(for file: FileInfo) -> URL {
        destinationURL(for: file).deletingPathExtension().appendingPathExtension("json")
    }

    /// Moves a verified download into place and writes its sidecar.
    /// Duration is measured from the audio header, not inferred from bitrate.
    @discardableResult
    public func commit(incoming: URL, file: FileInfo, deviceSerial: String) throws -> Sidecar {
        let destination = destinationURL(for: file)
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: incoming, to: destination)

        let sidecar = Sidecar(
            signature: file.signature,
            deviceFilename: file.name,
            relativePath: destination.path.replacingOccurrences(
                of: root.path.hasSuffix("/") ? root.path : root.path + "/", with: ""),
            lengthBytes: file.lengthBytes,
            durationSeconds: Self.measureDuration(of: destination),
            recordedAt: file.recordedAt,
            syncedAt: Date(),
            deviceSerial: deviceSerial,
            deviceModel: "hidock-p1",
            timeZoneIdentifier: TimeZone.current.identifier)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(sidecar).write(to: sidecarURL(for: file))
        return sidecar
    }

    public func scanSidecars() throws -> [Sidecar] {
        guard isReachable() else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var results: [Sidecar] = []
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants])

        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "json" else { continue }
            guard let data = try? Data(contentsOf: url),
                  let sidecar = try? decoder.decode(Sidecar.self, from: data) else { continue }
            results.append(sidecar)
        }
        return results
    }

    /// Reads duration synchronously via `AVAudioFile` rather than the
    /// deprecated `AVURLAsset.duration` sync accessor. `AVURLAsset.load(.duration)`
    /// is the modern replacement but is async, which would force `commit(...)`
    /// to become async and change its declared (synchronous, throwing) interface.
    private static func measureDuration(of url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let seconds = Double(file.length) / file.fileFormat.sampleRate
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HHmmss"
        return f
    }()
}
