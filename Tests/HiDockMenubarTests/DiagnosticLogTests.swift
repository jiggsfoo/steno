// Tests/HiDockMenubarTests/DiagnosticLogTests.swift
import Foundation
import Testing
@testable import HiDockMenubar

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
