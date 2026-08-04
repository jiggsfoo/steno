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

    /// `<root>/YYYY-MM-DD/HHMMSS-<sig8>.<corrected extension>`
    ///
    /// PURE — no I/O, and the same FileInfo always resolves to the same path.
    /// SyncEngine's diff checks the filesystem at this path, so it must be
    /// derivable without consulting the disk.
    ///
    /// The signature prefix is not decoration. Keyed on timestamp alone, two
    /// recordings sharing a second collide, and every recording whose filename
    /// does not parse collides with every other one, because the fallback was
    /// `Date()`. Combined with a commit that deleted the destination first, that
    /// silently and permanently destroyed the earlier recording.
    public func destinationURL(for file: FileInfo) -> URL {
        let ext = file.preferredExtension
        let short = String(file.signature.prefix(8))

        guard let date = file.recordedAt else {
            // No parseable timestamp. Key entirely on the signature so the path
            // is stable across runs; `Date()` here would give one recording a
            // different path on every sync.
            let stem = String(file.signature.prefix(16))
            return root.appendingPathComponent("undated")
                .appendingPathComponent(ext.isEmpty ? stem : "\(stem).\(ext)")
        }

        let stem = "\(Self.timeFormatter.string(from: date))-\(short)"
        return root.appendingPathComponent(Self.dayFormatter.string(from: date))
            .appendingPathComponent(ext.isEmpty ? stem : "\(stem).\(ext)")
    }

    public func sidecarURL(for file: FileInfo) -> URL {
        Self.sidecarURL(forAudio: destinationURL(for: file))
    }

    static func sidecarURL(forAudio url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("json")
    }

    /// Moves a verified download into place and writes its sidecar.
    ///
    /// The sidecar is written and moved BEFORE the audio, so the failure window
    /// is a single same-volume rename. Written the other way round, a failure
    /// after the audio moved would leave audio with no sidecar — and since
    /// sidecars are the source of truth, `scanSidecars` would not see that
    /// recording, so the next sync would download it again.
    @discardableResult
    public func commit(incoming: URL, file: FileInfo, deviceSerial: String) throws -> Sidecar {
        let destination = destinationURL(for: file)
        let sidecarDestination = Self.sidecarURL(forAudio: destination)
        let fm = FileManager.default

        // Refuse to clobber a DIFFERENT recording. Signature is identity, so a
        // matching signature is the same file being re-synced and is safe to
        // replace; anything else is a collision and must not be destroyed.
        if fm.fileExists(atPath: sidecarDestination.path),
           let existing = try? Self.decoder.decode(
               Sidecar.self, from: Data(contentsOf: sidecarDestination)),
           existing.signature != file.signature {
            throw LibraryError.destinationOccupied(destination.path, existing.signature)
        }

        try fm.createDirectory(at: destination.deletingLastPathComponent(),
                               withIntermediateDirectories: true)

        // Measure from the staged file; it is byte-identical to the destination.
        let sidecar = Sidecar(
            signature: file.signature,
            deviceFilename: file.name,
            relativePath: Self.relativePath(of: destination, under: root),
            lengthBytes: Self.fileSize(at: incoming) ?? file.lengthBytes,
            durationSeconds: Self.measureDuration(of: incoming),
            recordedAt: file.recordedAt,
            syncedAt: Date(),
            deviceSerial: deviceSerial,
            deviceModel: "hidock-p1",
            timeZoneIdentifier: TimeZone.current.identifier)

        let stagedSidecar = incoming.appendingPathExtension("json")
        try Self.encoder.encode(sidecar).write(to: stagedSidecar)

        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        if fm.fileExists(atPath: sidecarDestination.path) { try fm.removeItem(at: sidecarDestination) }
        try fm.moveItem(at: stagedSidecar, to: sidecarDestination)
        do {
            try fm.moveItem(at: incoming, to: destination)
        } catch {
            try? fm.removeItem(at: sidecarDestination)   // never leave an orphan sidecar
            throw error
        }
        return sidecar
    }

    /// Path relative to `root`, by path components rather than string
    /// replacement — the latter replaces every occurrence and silently yields
    /// an absolute path when the prefix does not match.
    static func relativePath(of url: URL, under root: URL) -> String {
        let rootParts = root.standardizedFileURL.pathComponents
        let urlParts = url.standardizedFileURL.pathComponents
        guard urlParts.count > rootParts.count,
              Array(urlParts.prefix(rootParts.count)) == rootParts else {
            return url.lastPathComponent
        }
        return urlParts.dropFirst(rootParts.count).joined(separator: "/")
    }

    static func fileSize(at url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
    }

    public func scanSidecars() throws -> [Sidecar] {
        guard isReachable() else { return [] }
        var results: [Sidecar] = []
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants])

        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "json" else { continue }
            guard let data = try? Data(contentsOf: url),
                  let sidecar = try? Self.decoder.decode(Sidecar.self, from: data) else { continue }
            results.append(sidecar)
        }
        return results
    }

    /// Reads duration synchronously via `AVAudioFile` rather than the
    /// deprecated `AVURLAsset.duration` sync accessor. `AVURLAsset.load(.duration)`
    /// is the modern replacement but is async, which would force `commit(...)`
    /// to become async and change its declared (synchronous, throwing) interface.
    /// Verified against a real pulled recording: reports 6.624 s, matching `afinfo`.
    private static func measureDuration(of url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let seconds = Double(file.length) / file.fileFormat.sampleRate
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    // en_US_POSIX is required for fixed-format dates. Under a non-Gregorian
    // Locale.current (Buddhist, Japanese) `yyyy` renders a different year and
    // the on-disk folder layout becomes locale-dependent.
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "HHmmss"
        return f
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

public enum LibraryError: Error, Equatable {
    /// A different recording already occupies the computed path.
    case destinationOccupied(String, String)
}
