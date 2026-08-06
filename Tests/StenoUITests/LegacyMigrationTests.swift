// Tests/StenoUITests/LegacyMigrationTests.swift
import Foundation
import Testing
@testable import StenoUI

/// Every test here runs against a fabricated old identity -- its own defaults
/// suites and its own directories under a temporary root. Nothing reads or
/// writes the real `com.jiggsfoo.hidock` domain, the real
/// `~/Library/Logs/`, or the real Application Support directory, so a test
/// run cannot disturb an installed copy of the app.
/// A class, so `deinit` tears the temporary root and both suites down when the
/// test's local goes out of scope -- no per-test cleanup to forget.
private final class Fixture {
    let root: URL
    let defaults: UserDefaults
    let legacyDefaults: UserDefaults
    private let suiteName: String
    private let legacySuiteName: String

    init() {
        let id = UUID().uuidString
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacyMigrationTests-\(id)")
        suiteName = "LegacyMigrationTests.new.\(id)"
        legacySuiteName = "LegacyMigrationTests.old.\(id)"
        defaults = UserDefaults(suiteName: suiteName)!
        legacyDefaults = UserDefaults(suiteName: legacySuiteName)!
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// `<root>/Logs/Steno/steno.log` -- the shape the real app uses, so the
    /// sibling derivation under test is the real one.
    var logURL: URL { root.appendingPathComponent("Logs/Steno/steno.log") }
    var legacyLogDirectory: URL { root.appendingPathComponent("Logs/HiDock") }
    var applicationSupport: URL { root.appendingPathComponent("Application Support/Steno") }
    var legacyApplicationSupport: URL { root.appendingPathComponent("Application Support/HiDock") }

    func migration(legacyDefaults override: UserDefaults?? = nil) -> LegacyMigration {
        LegacyMigration(
            defaults: defaults,
            legacyDefaults: override ?? legacyDefaults,
            logURL: logURL,
            legacyLogDirectory: LegacyMigration.sibling(of: logURL.deletingLastPathComponent()),
            applicationSupport: applicationSupport,
            legacyApplicationSupport: LegacyMigration.sibling(of: applicationSupport),
            fileManager: .default)
    }

    func write(_ contents: String, to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(contents.utf8).write(to: url)
    }

    func read(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    deinit {
        try? FileManager.default.removeItem(at: root)
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        UserDefaults.standard.removePersistentDomain(forName: legacySuiteName)
    }
}

// MARK: - Settings

@Test func carriesTheStoredLibraryRootOutOfTheOldDefaultsDomain() {
    let fixture = Fixture()
    fixture.legacyDefaults.set("/Users/someone/Recordings/Elsewhere", forKey: "libraryRoot")

    _ = fixture.migration().run()

    #expect(fixture.defaults.string(forKey: "libraryRoot") == "/Users/someone/Recordings/Elsewhere")
}

/// A value written since the rename is the user's current intent and outranks
/// whatever the old domain still holds.
@Test func doesNotOverwriteASettingTheNewDomainAlreadyHolds() {
    let fixture = Fixture()
    fixture.legacyDefaults.set("/old/path", forKey: "libraryRoot")
    fixture.defaults.set("/chosen/since/the/rename", forKey: "libraryRoot")

    let lines = fixture.migration().run()

    #expect(fixture.defaults.string(forKey: "libraryRoot") == "/chosen/since/the/rename")
    #expect(lines.contains { $0.contains("migrate.setting") && $0.contains("already set") })
}

@Test func survivesTheLegacyDefaultsDomainBeingUnopenable() {
    let fixture = Fixture()

    let lines = fixture.migration(legacyDefaults: .some(nil)).run()

    #expect(lines.contains { $0.contains("no legacy domain") })
    #expect(fixture.defaults.bool(forKey: LegacyMigration.completedKey))
}

// MARK: - Directories

@Test func movesTheLogAndApplicationSupportDirectoriesAcross() {
    let fixture = Fixture()
    fixture.write("log line", to: fixture.legacyLogDirectory.appendingPathComponent("hidock.log"))
    fixture.write("sqlite", to: fixture.legacyApplicationSupport.appendingPathComponent("index.sqlite"))

    _ = fixture.migration().run()

    #expect(fixture.read(fixture.logURL) == "log line")
    #expect(fixture.read(fixture.applicationSupport.appendingPathComponent("index.sqlite")) == "sqlite")
    // Moved, not copied: the old locations are gone, not duplicated.
    #expect(!fixture.exists(fixture.legacyLogDirectory))
    #expect(!fixture.exists(fixture.legacyApplicationSupport))
}

/// The rotation file rides along, so the log history stays in the two files
/// the app actually writes rather than being split across four.
@Test func renamesTheRotatedLogFileTooInsideTheMovedDirectory() {
    let fixture = Fixture()
    fixture.write("current", to: fixture.legacyLogDirectory.appendingPathComponent("hidock.log"))
    fixture.write("rotated", to: fixture.legacyLogDirectory.appendingPathComponent("hidock.log.1"))

    _ = fixture.migration().run()

    let directory = fixture.logURL.deletingLastPathComponent()
    #expect(fixture.read(directory.appendingPathComponent("steno.log")) == "current")
    #expect(fixture.read(directory.appendingPathComponent("steno.log.1")) == "rotated")
    #expect(!fixture.exists(directory.appendingPathComponent("hidock.log")))
}

/// The destination is someone else's data. Merging into it or replacing it
/// could destroy a newer index or log, so the source is left exactly where it
/// is and the skip is recorded.
@Test func leavesBothSidesAloneWhenTheDestinationAlreadyExists() {
    let fixture = Fixture()
    fixture.write("old", to: fixture.legacyApplicationSupport.appendingPathComponent("index.sqlite"))
    fixture.write("new", to: fixture.applicationSupport.appendingPathComponent("index.sqlite"))

    let lines = fixture.migration().run()

    #expect(fixture.read(fixture.applicationSupport.appendingPathComponent("index.sqlite")) == "new")
    #expect(fixture.read(fixture.legacyApplicationSupport.appendingPathComponent("index.sqlite")) == "old")
    #expect(lines.contains { $0.contains("migrate.support") && $0.contains("destination exists") })
}

@Test func neverRemovesAnythingFromTheRecordingsFolderItPointsAt() {
    let fixture = Fixture()
    let library = fixture.root.appendingPathComponent("Recordings/Somewhere")
    fixture.write("an hour-long meeting", to: library.appendingPathComponent("meeting.hda"))
    fixture.legacyDefaults.set(library.path, forKey: "libraryRoot")

    _ = fixture.migration().run()

    // The pointer moves; the recordings do not.
    #expect(fixture.defaults.string(forKey: "libraryRoot") == library.path)
    #expect(fixture.read(library.appendingPathComponent("meeting.hda")) == "an hour-long meeting")
}

// MARK: - Fresh install and idempotency

@Test func isANoOpOnAFreshInstallWithNoOldDomainAndNoOldDirectories() {
    let fixture = Fixture()

    let lines = fixture.migration().run()

    #expect(fixture.defaults.string(forKey: "libraryRoot") == nil)
    #expect(!fixture.exists(fixture.logURL))
    #expect(!fixture.exists(fixture.applicationSupport))
    #expect(lines.contains { $0.contains("migrate.logs") && $0.contains("nothing-to-move") })
    #expect(fixture.defaults.bool(forKey: LegacyMigration.completedKey))
}

/// The second pass must do nothing even though the old domain still holds a
/// value -- which is what makes a later deliberate change stick instead of
/// being reverted on the next launch.
@Test func runsAtMostOnce() {
    let fixture = Fixture()
    fixture.legacyDefaults.set("/first/run", forKey: "libraryRoot")

    _ = fixture.migration().run()
    fixture.defaults.set("/changed/afterwards", forKey: "libraryRoot")
    let second = fixture.migration().run()

    #expect(second.isEmpty)
    #expect(fixture.defaults.string(forKey: "libraryRoot") == "/changed/afterwards")
}

@Test func aSecondPassLeavesTheMigratedFilesWhereTheFirstPutThem() {
    let fixture = Fixture()
    fixture.write("log line", to: fixture.legacyLogDirectory.appendingPathComponent("hidock.log"))

    _ = fixture.migration().run()
    _ = fixture.migration().run()

    #expect(fixture.read(fixture.logURL) == "log line")
    #expect(!fixture.exists(fixture.legacyLogDirectory))
}

// MARK: - The move primitive

@Test func moveReportsNothingToMoveRatherThanFailingWhenTheSourceIsAbsent() {
    let fixture = Fixture()
    let outcome = fixture.migration().move(
        fixture.root.appendingPathComponent("absent"),
        to: fixture.root.appendingPathComponent("destination"))

    #expect(outcome == .nothingToMove)
    #expect(!fixture.exists(fixture.root.appendingPathComponent("destination")))
}

@Test func moveCreatesMissingIntermediateDirectoriesAtTheDestination() {
    let fixture = Fixture()
    let source = fixture.root.appendingPathComponent("source.txt")
    fixture.write("payload", to: source)
    let destination = fixture.root.appendingPathComponent("a/b/c/moved.txt")

    #expect(fixture.migration().move(source, to: destination) == .moved)
    #expect(fixture.read(destination) == "payload")
}
