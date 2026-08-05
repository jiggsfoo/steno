// Tests/HiDockKitTests/JensenDeviceTests.swift
import Foundation
import Testing
@testable import HiDockKit

@Test func sendReturnsMatchingResponseBody() async throws {
    let t = FakeTransport(script: .init(responses: [1: [Data([0xAB])]]))
    let device = JensenDevice(transport: t)
    try await device.open()
    #expect(try await device.send(.getDeviceInfo) == Data([0xAB]))
}

@Test func sequenceNumbersIncrementPerCommand() async throws {
    let t = FakeTransport(script: .init(responses: [1: [Data([1])], 6: [Data([2])]]))
    let device = JensenDevice(transport: t)
    try await device.open()
    _ = try await device.send(.getDeviceInfo)
    _ = try await device.send(.getFileCount)
    #expect(await t.written.map(\.sequence) == [0, 1])
}

@Test func reassemblesBodySplitAcrossReads() async throws {
    // FakeTransport hands back 64 bytes per read, so this 300-byte body
    // arrives across five reads and must be reassembled.
    let t = FakeTransport(script: .init(responses: [4: [Data(repeating: 0x7, count: 300)]]))
    let device = JensenDevice(transport: t)
    try await device.open()
    #expect(try await device.send(.getFileList).count == 300)
}

@Test func timesOutWhenDeviceNeverAnswers() async throws {
    let t = FakeTransport(script: .init(responses: [:], readTimeoutFor: [1]))
    let device = JensenDevice(transport: t)
    try await device.open()
    await #expect(throws: JensenError.timeout(command: 1)) {
        _ = try await device.send(.getDeviceInfo, timeout: .milliseconds(100))
    }
}

/// Pins the per-read cap directly. A wall-clock assertion cannot tell the fix
/// from the bug: reverting to a full-budget read timeout leaves elapsed time
/// unchanged on the common path, so an elapsed bound passes either way. What
/// matters is the value actually handed to the transport.
@Test func perReadTimeoutNeverExceedsTheCap() async throws {
    let t = FakeTransport(script: .init(
        responses: [:], readTimeoutFor: [1], readDelay: .milliseconds(400)))
    let device = JensenDevice(transport: t)
    try await device.open()

    _ = try? await device.send(.getDeviceInfo, timeout: .seconds(5))
    #expect(await t.maxReadTimeoutSeen <= .milliseconds(250))
}

/// A timed-out command must return rather than hang. The bound is generous on
/// purpose: elapsed time legitimately exceeds the command timeout, because the
/// error path then drains for three 50 ms quiet windows. That drain is required
/// by C3/I1. This test documents its cost; it does NOT claim the timeout is an
/// upper bound on elapsed time.
@Test func timedOutCommandReturnsWithoutHanging() async throws {
    let t = FakeTransport(script: .init(
        responses: [:], readTimeoutFor: [1], readDelay: .milliseconds(400)))
    let device = JensenDevice(transport: t)
    try await device.open()

    let start = ContinuousClock.now
    _ = try? await device.send(.getDeviceInfo, timeout: .milliseconds(300))
    #expect(ContinuousClock.now - start < .seconds(2))
}

/// A buffered reply whose command id matches but whose sequence does not is a
/// leftover from a command that already timed out. It must be skipped rather
/// than returned, and the scan must continue on to the real answer.
///
/// Sequence 99 is deliberately one this device never issues in this test. Do
/// NOT inject a stray carrying the same sequence the next command will use:
/// that is a genuine collision no matching scheme can resolve, and it models
/// nothing real, since a retry always advances the sequence.
@Test func staleResponseWithWrongSequenceIsSkipped() async throws {
    let t = FakeTransport(script: .init(responses: [1: [Data([0x22])]]))
    let device = JensenDevice(transport: t)
    try await device.open()

    await t.injectStrayResponse(command: 1, sequence: 99, body: Data([0x11]))
    let body = try await device.send(.getDeviceInfo, timeout: .seconds(1))
    #expect(body == Data([0x22]))          // never the stale 0x11
}

/// A timeout must not strand a partial packet in the buffer. A stranded
/// header's declared length would swallow every subsequent response, and
/// because its sync marker is intact `invalidHeader` never fires to clear it.
@Test func timeoutClearsBufferSoTheNextCommandSucceeds() async throws {
    let t = FakeTransport(script: .init(responses: [6: [Data([0, 0, 0, 3])]], readTimeoutFor: [1]))
    let device = JensenDevice(transport: t)
    try await device.open()

    await t.injectStrayResponse(command: 1, sequence: 0, body: Data(repeating: 0xEE, count: 40))
    _ = try? await device.send(.getDeviceInfo, timeout: .milliseconds(100))

    #expect(try await device.send(.getFileCount) == Data([0, 0, 0, 3]))
}

/// drain() exists to catch a response that arrives LATE. Exiting on the first
/// empty read misses exactly that case, because an empty read means "nothing
/// in the last 50 ms", not "the endpoint is empty".
@Test func drainConsumesALateArrivingResponse() async throws {
    let t = FakeTransport(script: .init(responses: [6: [Data([0, 0, 0, 9])]]))
    let device = JensenDevice(transport: t)
    try await device.open()

    async let late: Void = t.injectStrayResponse(
        command: 1, sequence: 0, body: Data([0xDE]), after: .milliseconds(120))
    await device.drain(maxDuration: .milliseconds(600))
    await late

    #expect(try await device.send(.getFileCount) == Data([0, 0, 0, 9]))
}

/// Actors are reentrant, so this pins the property the explicit gate provides:
/// every caller receives its OWN command's response, and no two commands are
/// on the wire at once.
@Test func concurrentCallersEachReceiveTheirOwnResponse() async throws {
    let t = FakeTransport(script: .init(
        responses: [1: [Data([0x11])], 6: [Data([0x66])], 16: [Data([0x16])]]))
    let device = JensenDevice(transport: t)
    try await device.open()

    async let a = device.send(.getDeviceInfo)
    async let b = device.send(.getFileCount)
    async let c = device.send(.getCardInfo)
    let (ra, rb, rc) = try await (a, b, c)

    #expect(ra == Data([0x11]))
    #expect(rb == Data([0x66]))
    #expect(rc == Data([0x16]))
    #expect(await t.written.count == 3)
    #expect(Set(await t.written.map(\.sequence)).count == 3)

    // The load-bearing assertion. Response correctness alone does not prove
    // serialization -- the fake's FIFO queue satisfies it even with the gate
    // removed. Overlapping writes are the direct observable, and reach zero
    // only when exactly one command is ever on the wire.
    #expect(await t.overlappingWrites == 0)
}

/// Command 18 (GET_RECORDING_FILE) returns an empty body when the device is
/// idle -- confirmed against the real P1 2026-08-04.
@Test func recordingFileReturnsNilForAnEmptyBody() async throws {
    let t = FakeTransport(script: .init(responses: [18: [Data()]]))
    let device = JensenDevice(transport: t)
    try await device.open()
    #expect(try await device.recordingFile() == nil)
}

@Test func recordingFileReturnsTheNameForANonEmptyBody() async throws {
    let name = "20260804143022REC003.hda"
    let t = FakeTransport(script: .init(responses: [18: [Data(name.utf8)]]))
    let device = JensenDevice(transport: t)
    try await device.open()
    #expect(try await device.recordingFile() == name)
}

/// The reference implementation pads the filename to a fixed width with
/// NUL bytes; `recordingFile` must strip them rather than return a name with
/// trailing garbage or report a false "recording" from a body that's really
/// just padding.
@Test func recordingFileStripsTrailingNULs() async throws {
    var body = Data("REC004.hda".utf8)
    body.append(contentsOf: [0, 0, 0, 0])
    let t = FakeTransport(script: .init(responses: [18: [body]]))
    let device = JensenDevice(transport: t)
    try await device.open()
    #expect(try await device.recordingFile() == "REC004.hda")
}

@Test func openAndCloseForwardToTransport() async throws {
    let t = FakeTransport(script: .init())
    let device = JensenDevice(transport: t)
    try await device.open()
    await device.close()
    #expect(await t.openCount == 1)
    #expect(await t.closeCount == 1)
}
