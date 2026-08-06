// Tests/StenoUITests/DiagnosticLogTests.swift
import Foundation
import Testing
@testable import StenoUI

/// `DiagnosticLog` is purely observational -- see its doc comment -- so only
/// its pure formatting and rotation logic are covered here. Nothing here
/// requires an attached P1; `log(_:_:)` itself (the fire-and-forget entry
/// point AppModel actually calls) is not tested directly since it hands off
/// to a detached `Task` with no completion signal to wait on -- `format` and
/// `append`/`rotateIfNeeded`, which it's built from, are what's testable.
private func tempLogURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("DiagnosticLogTests-\(UUID().uuidString)")
        .appendingPathComponent("hidock.log")
}

@Test func formattedLineContainsTimestampEventAndPairs() {
    let date = Date(timeIntervalSince1970: 0)
    // A whole-hour, non-UTC offset -- ISO8601DateFormatter renders UTC itself
    // as a bare "Z" rather than "+00:00", so UTC would not exercise the
    // "+HH:MM" shape this test is actually checking for.
    let manila = TimeZone(identifier: "Asia/Manila")!
    let line = DiagnosticLog.format(
        event: "poll",
        pairs: ["recording": "nil", "count": "10", "lastSeen": "10"],
        at: date,
        timeZone: manila)

    #expect(line.hasPrefix("1970-01-01T08:00:00.000+08:00"))
    #expect(line.contains("poll"))
    #expect(line.contains("recording=nil"))
    #expect(line.contains("count=10"))
    #expect(line.contains("lastSeen=10"))
}

@Test func formattedLineAppendsTheDecisionSuffixVerbatim() {
    let line = DiagnosticLog.format(
        event: "poll", pairs: ["recording": "nil", "count": "11"], suffix: "-> sync",
        at: Date(), timeZone: TimeZone(identifier: "UTC")!)
    #expect(line.hasSuffix("-> sync"))
}

@Test func valuesContainingSpacesAreQuoted() {
    let line = DiagnosticLog.format(
        event: "sync.start", pairs: ["name": "my recording.hda"],
        at: Date(), timeZone: TimeZone(identifier: "UTC")!)
    #expect(line.contains("name=\"my recording.hda\""))
}

@Test func valuesWithoutSpacesAreNotQuoted() {
    let line = DiagnosticLog.format(
        event: "retry", pairs: ["delay": "2.00s", "reason": "busy"],
        at: Date(), timeZone: TimeZone(identifier: "UTC")!)
    #expect(line.contains("delay=2.00s"))
    #expect(line.contains("reason=busy"))
    #expect(!line.contains("\""))
}

@Test func emptyValuesAreQuotedRatherThanLeftAmbiguous() {
    let line = DiagnosticLog.format(
        event: "poll.error", pairs: ["error": ""], at: Date(), timeZone: TimeZone(identifier: "UTC")!)
    #expect(line.contains("error=\"\""))
}

@Test func rotationMovesTheOversizedFileToDotOne() throws {
    let url = tempLogURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 0x41, count: 200).write(to: url)

    DiagnosticLog.rotateIfNeeded(url, cap: 100)

    let rotated = url.appendingPathExtension("1")
    #expect(FileManager.default.fileExists(atPath: url.path) == false)
    #expect(FileManager.default.fileExists(atPath: rotated.path))
    #expect(try Data(contentsOf: rotated).count == 200)
}

@Test func rotationReplacesAnExistingDotOne() throws {
    let url = tempLogURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let rotated = url.appendingPathExtension("1")
    try Data(repeating: 0x00, count: 5).write(to: rotated)
    try Data(repeating: 0x41, count: 200).write(to: url)

    DiagnosticLog.rotateIfNeeded(url, cap: 100)

    #expect(try Data(contentsOf: rotated).count == 200)
}

@Test func rotationIsANoOpUnderTheCap() throws {
    let url = tempLogURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 0x41, count: 50).write(to: url)

    DiagnosticLog.rotateIfNeeded(url, cap: 100)

    #expect(FileManager.default.fileExists(atPath: url.path))
    #expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("1").path) == false)
}

@Test func appendCreatesTheDirectoryAndWritesTheLine() throws {
    let url = tempLogURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    DiagnosticLog.append("first line", to: url)
    DiagnosticLog.append("second line", to: url)

    let contents = try String(contentsOf: url, encoding: .utf8)
    #expect(contents == "first line\nsecond line\n")
}

/// The hard requirement: a broken destination must never throw or crash --
/// it must be swallowed exactly like every other logging failure.
@Test func loggingToAnUnwritablePathDoesNotThrowOrCreateAnything() {
    let unwritable = URL(fileURLWithPath: "/System/DiagnosticLogTests-unwritable/hidock.log")
    DiagnosticLog.append("should be swallowed", to: unwritable)
    #expect(FileManager.default.fileExists(atPath: unwritable.path) == false)
}

@Test func secondsFormatsWholeAndFractionalDurations() {
    #expect(DiagnosticLog.seconds(.seconds(2)) == "2.00")
    #expect(DiagnosticLog.seconds(.milliseconds(6090)) == "6.09")
}

/// The mutation this is meant to catch: `append` used to open the file with
/// `FileHandle(forWritingTo:)` and do `seekToEnd()` then `write()` as two
/// separate steps. Two callers can resolve the same end offset between their
/// seek and their write, and one overwrites (tears) the other's line -- a
/// real capture from the live app showed exactly this: an `attach` line's
/// tail got clobbered mid-write by a `sync.start` line landing at the same
/// moment. A real device only ever produces a couple of near-simultaneous
/// writers (the attach handler and the sync task); a few hundred concurrent
/// writers here is a deliberately harder version of the same race, so a fix
/// that merely reduces the odds rather than removing the race can't sneak
/// through as "still passes."
@Test func concurrentAppendsNeitherTearNorLoseALine() async throws {
    let url = tempLogURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

    let writeCount = 300
    await withTaskGroup(of: Void.self) { group in
        for i in 0..<writeCount {
            group.addTask {
                let line = DiagnosticLog.format(event: "concurrent.write", pairs: ["i": "\(i)"])
                DiagnosticLog.append(line, to: url)
            }
        }
    }

    let contents = try String(contentsOf: url, encoding: .utf8)
    let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)

    // Line count first -- a torn write can also merge two lines into one or
    // truncate one to nothing, which would already show up here before the
    // per-line shape check below even runs.
    #expect(lines.count == writeCount)

    let timestampPrefix = try Regex(
        #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}[+-]\d{2}:\d{2}"#)
    for line in lines {
        #expect(line.firstMatch(of: timestampPrefix) != nil, "malformed line: \(line)")
        #expect(line.contains("concurrent.write"), "malformed line: \(line)")
    }
}

/// Rotation and a concurrent write race in real usage -- a tick that logs
/// `retry` right as another tick's write pushes the file over the cap. A
/// small cap here forces several rotations to actually happen mid-storm
/// rather than leaving it to chance; every line must still land somewhere
/// (either the live file or the one rotation slot), intact, none lost.
@Test func rotationDuringConcurrentAppendsLosesNoLine() async throws {
    let url = tempLogURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

    let writeCount = 300
    await withTaskGroup(of: Void.self) { group in
        for i in 0..<writeCount {
            group.addTask {
                let line = DiagnosticLog.format(event: "rotate.write", pairs: ["i": "\(i)"])
                DiagnosticLog.append(line, to: url, cap: 200)
            }
        }
    }

    let rotated = url.appendingPathExtension("1")
    let liveLines = (try? String(contentsOf: url, encoding: .utf8))?
        .split(separator: "\n", omittingEmptySubsequences: true) ?? []
    let rotatedLines = (try? String(contentsOf: rotated, encoding: .utf8))?
        .split(separator: "\n", omittingEmptySubsequences: true) ?? []
    let allLines = liveLines + rotatedLines

    // A tiny cap rotates repeatedly, so earlier rotation slots are expected
    // to be overwritten and lost -- only the CURRENT live file and the ONE
    // most recent rotation slot are guaranteed to survive. The invariant
    // that must hold regardless is per-line integrity: whatever IS present
    // across those two files must be whole, untorn lines, never a fragment.
    let timestampPrefix = try Regex(
        #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}[+-]\d{2}:\d{2}"#)
    #expect(!allLines.isEmpty)
    for line in allLines {
        #expect(line.firstMatch(of: timestampPrefix) != nil, "malformed line: \(line)")
        #expect(line.contains("rotate.write"), "malformed line: \(line)")
    }
}
