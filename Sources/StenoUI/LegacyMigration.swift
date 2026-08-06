import Foundation

/// One-shot carry-over from the app's former "HiDock" identity to "Steno".
///
/// Renaming the bundle identifier hands the app a brand new
/// `UserDefaults.standard` domain, a new Application Support directory, and a
/// new log directory. Nothing is lost on disk, but without this the app comes
/// up believing it is a fresh install: it reads no stored library root, falls
/// back to the default folder, finds an empty index, and re-syncs every
/// recording on the device into a folder the user never chose.
///
/// Runs from `AppModel.init`, before it reads a single setting.
///
/// **Nothing here deletes anything, ever.** Directories are MOVED, never
/// copied-then-removed, and a move whose destination already exists leaves the
/// source untouched rather than overwriting it. Where this cannot establish
/// what happened it changes nothing and says so in the diagnostic log --
/// the standing rule for this project: a redundant download is a better
/// failure than a confident lie.
///
/// A recordings folder the user chose by hand is never touched. Only the
/// *pointer* to it is carried across; wherever it is, it stays. The folder the
/// app picked for a user who never chose one is a different case -- see
/// `adoptLegacyDefaultLibrary()`.
struct LegacyMigration {
    /// The former bundle identifier, which is also the name of the former
    /// `UserDefaults.standard` domain.
    static let legacyDomain = "com.jiggsfoo.hidock"

    /// The former product name, as it appeared in directory names.
    static let legacyDirectoryName = "HiDock"

    /// Written into the NEW domain once a pass completes, so this runs at most
    /// once per install. Deliberately set even when a pass finds nothing to do
    /// -- a fresh install has nothing to migrate and should not keep looking.
    static let completedKey = "didMigrateFromHiDockIdentity"

    /// Where the chosen recordings folder is stored, in both domains. The one
    /// definition both this and `AppModel` read, so the two cannot drift.
    ///
    /// Written ONLY when the folder is changed by hand, which is why its
    /// absence cannot be read as "no library" -- see
    /// `adoptLegacyDefaultLibrary()`.
    static let libraryRootKey = "libraryRoot"

    /// Settings carried across.
    ///
    /// `libraryRoot` is the load-bearing one: lose it and the app re-syncs the
    /// whole device into a folder the user never chose. Launch at Login is
    /// deliberately absent -- it lives in LaunchServices keyed by bundle
    /// identifier, not in this defaults domain, and there is no supported way
    /// to read (let alone transfer) another bundle's registration.
    static let carriedKeys = [libraryRootKey]

    /// The former log file names, paired positionally with the new ones
    /// derived from `logURL`: `hidock.log` -> `steno.log`, and the rotation
    /// `hidock.log.1` -> `steno.log.1`.
    static let legacyLogFilenames = ["hidock.log", "hidock.log.1"]

    let defaults: UserDefaults
    /// `nil` when the legacy domain cannot be opened at all -- which is what
    /// `UserDefaults(suiteName:)` returns if the name collides with the
    /// current bundle identifier. Treated as "nothing to carry", never as an
    /// error worth failing the launch over.
    let legacyDefaults: UserDefaults?
    /// The full path of the new log FILE, not its directory: the file's own
    /// name is what the legacy log is renamed to inside the moved directory.
    let logURL: URL
    let legacyLogDirectory: URL
    let applicationSupport: URL
    let legacyApplicationSupport: URL
    /// The folder the app falls back to when no `libraryRoot` is stored --
    /// `~/Recordings/Steno` in production, and the same value `AppModel`
    /// computes after this has run.
    let defaultLibraryRoot: URL
    /// What that fallback was before the rename: `~/Recordings/HiDock`.
    let legacyDefaultLibraryRoot: URL
    let fileManager: FileManager

    /// What one move did. Every case except `.moved` left the filesystem
    /// exactly as it was found.
    enum MoveOutcome: Equatable {
        /// No source to move. The ordinary fresh-install case.
        case nothingToMove
        /// Something is already at the destination. The source is left alone;
        /// overwriting it could destroy a newer index or log.
        case destinationExists
        case moved
        /// The move threw. The source is still where it was.
        case failed(String)

        var pairs: KeyValuePairs<String, String> {
            switch self {
            case .nothingToMove:            return ["result": "nothing-to-move"]
            case .destinationExists:        return ["result": "skipped", "why": "destination exists"]
            case .moved:                    return ["result": "moved"]
            case .failed(let reason):       return ["result": "failed", "error": reason]
            }
        }
    }

    // MARK: - Entry point

    /// Runs the migration once, writing what it did to the diagnostic log.
    ///
    /// Logging happens AFTER the directory moves, never before: the log write
    /// creates the new log directory on demand, and a directory conjured into
    /// existence early would make the move below see an occupied destination
    /// and skip the very thing it was called to do.
    static func runIfNeeded(logURL: URL, applicationSupport: URL, defaultLibraryRoot: URL) {
        let migration = LegacyMigration(
            defaults: .standard,
            legacyDefaults: UserDefaults(suiteName: legacyDomain),
            logURL: logURL,
            legacyLogDirectory: sibling(of: logURL.deletingLastPathComponent()),
            applicationSupport: applicationSupport,
            legacyApplicationSupport: sibling(of: applicationSupport),
            defaultLibraryRoot: defaultLibraryRoot,
            legacyDefaultLibraryRoot: sibling(of: defaultLibraryRoot),
            fileManager: .default)

        for line in migration.run() {
            DiagnosticLog.append(line, to: logURL)
        }
    }

    /// The legacy-named directory next to `url`, e.g.
    /// `~/Library/Logs/Steno` -> `~/Library/Logs/HiDock`.
    static func sibling(of url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(legacyDirectoryName)
    }

    /// Performs the migration and returns the lines describing what happened,
    /// formatted but not yet written. Empty when there was nothing to do
    /// because a previous pass already completed.
    func run() -> [String] {
        guard !defaults.bool(forKey: Self.completedKey) else { return [] }

        var lines = [DiagnosticLog.format(event: "migrate.begin", pairs: ["from": Self.legacyDomain])]
        lines += carrySettings()
        lines += adoptLegacyDefaultLibrary()
        lines += moveDirectories()
        lines += renameLogFiles()

        defaults.set(true, forKey: Self.completedKey)
        lines.append(DiagnosticLog.format(event: "migrate.end"))
        return lines
    }

    // MARK: - Settings

    /// Copies each carried key that the new domain does not already hold.
    ///
    /// "Does not already hold" is the whole guard: a value written since the
    /// rename is the user's current intent and outranks anything left in the
    /// old domain.
    private func carrySettings() -> [String] {
        guard let legacyDefaults else {
            return [DiagnosticLog.format(
                event: "migrate.settings", pairs: ["result": "skipped", "why": "no legacy domain"])]
        }

        return Self.carriedKeys.map { key in
            if defaults.object(forKey: key) != nil {
                return DiagnosticLog.format(
                    event: "migrate.setting",
                    pairs: ["key": key, "result": "skipped", "why": "already set"])
            }
            guard let value = legacyDefaults.object(forKey: key) else {
                return DiagnosticLog.format(
                    event: "migrate.setting", pairs: ["key": key, "result": "nothing-to-carry"])
            }
            defaults.set(value, forKey: key)
            return DiagnosticLog.format(
                event: "migrate.setting", pairs: ["key": key, "result": "carried"])
        }
    }

    // MARK: - The library folder nobody chose

    /// Carries the recordings across for the user who never picked a folder.
    ///
    /// `libraryRoot` is written only when the folder is changed by hand, so its
    /// absence does not mean "no library" -- it means the app has been using
    /// the computed default all along, and the rename moved that default from
    /// `Recordings/HiDock` to `Recordings/Steno`. Carrying the stored key alone
    /// misses this case entirely, and it is the COMMON case: nothing to carry,
    /// a new default pointing at a folder that does not exist, an empty index,
    /// and every recording re-synced off the device.
    ///
    /// Deliberately ordered after `carrySettings()`: an explicit root -- stored
    /// since the rename, or just carried out of the old domain -- names where
    /// the recordings actually are, and this folder is not it.
    ///
    /// Three outcomes, none of which deletes anything:
    /// - legacy folder, no new folder: MOVE it, exactly as the log and
    ///   Application Support directories are moved. The computed default then
    ///   finds it, so no pointer is stored.
    /// - both folders: the new one is someone's data. Never merge, never
    ///   overwrite -- store the legacy path as an explicit `libraryRoot` so the
    ///   app keeps using the folder the recordings are actually in.
    /// - neither: a genuine fresh install. The new default stands.
    private func adoptLegacyDefaultLibrary() -> [String] {
        guard defaults.object(forKey: Self.libraryRootKey) == nil else {
            return [DiagnosticLog.format(
                event: "migrate.library",
                pairs: ["result": "skipped", "why": "explicit root set"])]
        }

        switch move(legacyDefaultLibraryRoot, to: defaultLibraryRoot) {
        case .nothingToMove:
            return [DiagnosticLog.format(
                event: "migrate.library", pairs: ["result": "nothing-to-move"])]
        case .moved:
            return [DiagnosticLog.format(
                event: "migrate.library",
                pairs: ["result": "moved", "to": defaultLibraryRoot.path])]
        case .destinationExists:
            return [pointAtLegacyLibrary(why: "destination exists")]
        case .failed(let reason):
            // The move threw, so the recordings are still at the legacy path.
            // Pointing at them there is the honest outcome: better a stale
            // folder name than a default that resolves to nothing.
            return [pointAtLegacyLibrary(why: reason)]
        }
    }

    /// Records the legacy folder as the explicit `libraryRoot`, leaving both
    /// folders exactly as they were found.
    private func pointAtLegacyLibrary(why: String) -> String {
        defaults.set(legacyDefaultLibraryRoot.path, forKey: Self.libraryRootKey)
        return DiagnosticLog.format(
            event: "migrate.library",
            pairs: ["result": "pointed", "why": why, "at": legacyDefaultLibraryRoot.path])
    }

    // MARK: - Directories

    private func moveDirectories() -> [String] {
        let newLogDirectory = logURL.deletingLastPathComponent()
        return [
            line("migrate.logs", move(legacyLogDirectory, to: newLogDirectory)),
            line("migrate.support", move(legacyApplicationSupport, to: applicationSupport)),
        ]
    }

    /// Renames the log files inside the (now migrated) log directory so the
    /// history stays in the one file the app writes to, rather than being
    /// split across an orphaned `hidock.log` and a fresh `steno.log`.
    private func renameLogFiles() -> [String] {
        let directory = logURL.deletingLastPathComponent()
        let newNames = [logURL.lastPathComponent, logURL.appendingPathExtension("1").lastPathComponent]

        return zip(Self.legacyLogFilenames, newNames).map { legacy, new in
            line("migrate.logfile",
                 move(directory.appendingPathComponent(legacy),
                      to: directory.appendingPathComponent(new)))
        }
    }

    /// Moves `source` onto `destination`, or does nothing at all.
    ///
    /// The two guards are the safety property: no source means nothing to do,
    /// and an occupied destination means stop -- never merge, never overwrite,
    /// never delete to make room. `moveItem` leaves the source in place when it
    /// throws, so the `.failed` path is also non-destructive.
    func move(_ source: URL, to destination: URL) -> MoveOutcome {
        guard fileManager.fileExists(atPath: source.path) else { return .nothingToMove }
        guard !fileManager.fileExists(atPath: destination.path) else { return .destinationExists }

        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: source, to: destination)
            return .moved
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func line(_ event: String, _ outcome: MoveOutcome) -> String {
        DiagnosticLog.format(event: event, pairs: outcome.pairs)
    }
}
