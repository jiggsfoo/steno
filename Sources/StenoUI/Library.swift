import AVFoundation
import Foundation
import JensenKit

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

    /// Reads the sidecar at `file`'s computed path, if one is there and decodes.
    /// The locally recorded length in it is the trusted source for anything
    /// gating a destructive action — see `SyncEngine.isAlreadySynced`.
    public func sidecar(for file: FileInfo) -> Sidecar? {
        guard let data = try? Data(contentsOf: sidecarURL(for: file)) else { return nil }
        return try? Self.decoder.decode(Sidecar.self, from: data)
    }

    /// Reads the sidecar beside the audio at `relativePath`, if one is there
    /// and decodes.
    ///
    /// The counterpart to `updateSidecar(_:)`, which writes to exactly this
    /// path — so this is how a caller holding a possibly-stale `Sidecar`
    /// value re-reads what is actually on disk before overwriting it. Keyed on
    /// `relativePath` rather than signature because that is the only field
    /// that names a location, and it never changes for a recording: the audio
    /// is installed once by `commit` and never moved (only the derived NOTE
    /// moves between topic folders). Returns nil rather than throwing —
    /// missing, unreadable and undecodable are one answer here, "there is no
    /// trustworthy sidecar at that path", and the caller must not proceed on
    /// any of them.
    public func sidecar(atRelativePath relativePath: String) -> Sidecar? {
        let audio = root.appendingPathComponent(relativePath)
        guard let data = try? Data(contentsOf: Self.sidecarURL(forAudio: audio)) else { return nil }
        return try? Self.decoder.decode(Sidecar.self, from: data)
    }

    static func sidecarURL(forAudio url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("json")
    }

    /// Moves a verified download into place and writes its sidecar.
    ///
    /// The audio is installed BEFORE the sidecar (see the comment on the
    /// install calls below for why): the failure window this leaves is audio
    /// on disk with no sidecar, which `scanSidecars` cannot see, so the next
    /// sync harmlessly re-downloads and re-commits over the same path.
    @discardableResult
    public func commit(incoming: URL, file: FileInfo, deviceSerial: String) throws -> Sidecar {
        let destination = destinationURL(for: file)
        let sidecarDestination = Self.sidecarURL(forAudio: destination)
        let fm = FileManager.default

        // Refuse to clobber a DIFFERENT recording. Signature is identity, so a
        // matching signature is the same file being re-synced and is safe to
        // replace; anything else is a collision and must not be destroyed.
        //
        // Fails CLOSED: a sidecar that exists but will not decode might describe
        // any recording at all, so refuse rather than overwrite on an assumption.
        if fm.fileExists(atPath: sidecarDestination.path) {
            guard let data = try? Data(contentsOf: sidecarDestination),
                  let existing = try? Self.decoder.decode(Sidecar.self, from: data) else {
                throw LibraryError.destinationOccupied(destination.path, "unreadable sidecar")
            }
            guard existing.signature == file.signature else {
                throw LibraryError.destinationOccupied(destination.path, existing.signature)
            }
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
            // The hardware's model identifier, persisted into every sidecar on
            // disk. Not an app name, and not renameable: changing it would
            // make new sidecars disagree with every one already written.
            deviceModel: "hidock-p1",
            timeZoneIdentifier: TimeZone.current.identifier)

        let stagedSidecar = incoming.appendingPathExtension("json")
        try Self.encoder.encode(sidecar).write(to: stagedSidecar)

        // AUDIO FIRST, then the sidecar. Two files cannot be installed
        // atomically, so the question is not how to avoid an intermediate state
        // but which intermediate state is safer. This ordering was reversed
        // twice before settling here; the reasoning is worth keeping.
        //
        // Audio-first worst case: audio present, sidecar missing or stale.
        // scanSidecars does not see it, so the next sync re-downloads and
        // re-commits over the same path. Redundant work, self-healing, and
        // nothing on disk ever lies.
        //
        // Sidecar-first worst case: a sidecar describing a recording that was
        // never installed, sitting beside different audio. That does NOT
        // self-heal, and the library's source of truth is then simply wrong.
        //
        // A redundant download is a far better failure than a confident lie.
        try Self.install(incoming, at: destination)
        do {
            try Self.install(stagedSidecar, at: sidecarDestination)
        } catch {
            try? fm.removeItem(at: stagedSidecar)
            throw error
        }
        return sidecar
    }

    /// Rewrites an existing sidecar in place. Used when transcription adds
    /// fields to a recording already on disk. Never touches the audio.
    ///
    /// UUID-suffixed staging, written `.atomic`: the automatic transcription
    /// sweep and a manual retry can both call this for the SAME sidecar. A
    /// shared `.part` name means two writers share one inode, and a plain
    /// (non-atomic) `Data.write` is open/truncate/write, so two interleaved
    /// calls could tear the staged file before either install runs. Unlike a
    /// torn `.transcript` (which self-heals -- it fails to decode, reads as
    /// absent, and is redone free), a torn SIDECAR is fatal: `scanSidecars`
    /// skips anything that fails to decode, so the recording would vanish
    /// from the library permanently, with no way back once it is off the P1.
    public func updateSidecar(_ sidecar: Sidecar) throws {
        let audio = root.appendingPathComponent(sidecar.relativePath)
        let destination = Self.sidecarURL(forAudio: audio)
        let staged = destination.appendingPathExtension("\(UUID().uuidString).part")
        try Self.encoder.encode(sidecar).write(to: staged, options: .atomic)
        do {
            try Self.install(staged, at: destination)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
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

    /// Same-volume atomic install. `replaceItemAt` when something is already
    /// there, `moveItem` when not — never a delete followed by a move.
    static func install(_ source: URL, at destination: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: destination.path) else {
            try fm.moveItem(at: source, to: destination)
            return
        }
        // replaceItemAt may report a different resulting URL on some volumes.
        // Everything here lives under a plain local root, but verify rather than
        // assume: a silent rename would hide the file from scanSidecars.
        let result = try fm.replaceItemAt(destination, withItemAt: source)
        if let result, result.standardizedFileURL != destination.standardizedFileURL {
            try fm.moveItem(at: result, to: destination)
        }
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

extension LibraryError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .destinationOccupied(let path, _):
            return "Skipped a recording — a different file already exists at \(path)."
        }
    }
}
