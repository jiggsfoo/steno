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
/// The user's recordings folder is never touched. Only the *pointer* to it is
/// carried across; wherever it is, it stays.
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

    /// Settings carried across.
    ///
    /// `libraryRoot` is the load-bearing one: lose it and the app re-syncs the
    /// whole device into a folder the user never chose. Launch at Login is
    /// deliberately absent -- it lives in LaunchServices keyed by bundle
    /// identifier, not in this defaults domain, and there is no supported way
    /// to read (let alone transfer) another bundle's registration.
    static let carriedKeys = ["libraryRoot"]

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
    static func runIfNeeded(logURL: URL, applicationSupport: URL) {
        let migration = LegacyMigration(
            defaults: .standard,
            legacyDefaults: UserDefaults(suiteName: legacyDomain),
            logURL: logURL,
            legacyLogDirectory: sibling(of: logURL.deletingLastPathComponent()),
            applicationSupport: applicationSupport,
            legacyApplicationSupport: sibling(of: applicationSupport),
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
