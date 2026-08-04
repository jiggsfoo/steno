// Tests/HiDockKitTests/JensenDeviceTests.swift
import Foundation
import Testing
@testable import HiDockKit

@Test func sendReturnsMatchingResponseBody() async throws {
    let t = FakeTransport(script: .init(responses: [1: [Data([0xAB])]]))
    let device = JensenDevice(transport: t)
    try await device.open()
    let body = try await device.send(.getDeviceInfo)
    #expect(body == Data([0xAB]))
}

@Test func sequenceNumbersIncrementPerCommand() async throws {
    let t = FakeTransport(script: .init(responses: [1: [Data([1])], 6: [Data([2])]]))
    let device = JensenDevice(transport: t)
    try await device.open()
    _ = try await device.send(.getDeviceInfo)
    _ = try await device.send(.getFileCount)
    let written = await t.written
    #expect(written.map(\.sequence) == [0, 1])
}

@Test func reassemblesBodySplitAcrossReads() async throws {
    // FakeTransport hands back 64 bytes per read, so this 300-byte body
    // arrives across five reads and must be reassembled.
    let t = FakeTransport(script: .init(responses: [4: [Data(repeating: 0x7, count: 300)]]))
    let device = JensenDevice(transport: t)
    try await device.open()
    let body = try await device.send(.getFileList)
    #expect(body.count == 300)
}

@Test func timesOutWhenDeviceNeverAnswers() async throws {
    let t = FakeTransport(script: .init(responses: [:], readTimeoutFor: [1]))
    let device = JensenDevice(transport: t)
    try await device.open()
    await #expect(throws: JensenError.timeout(command: 1)) {
        _ = try await device.send(.getDeviceInfo, timeout: .milliseconds(50))
    }
}

/// After a timeout the IN endpoint must be drained, or a late response
/// would be matched against the *next* command and desync everything.
@Test func drainsStrayResponseAfterTimeout() async throws {
    let t = FakeTransport(script: .init(responses: [6: [Data([0, 0, 0, 3])]], readTimeoutFor: [1]))
    let device = JensenDevice(transport: t)
    try await device.open()

    _ = try? await device.send(.getDeviceInfo, timeout: .milliseconds(50))
    await t.injectStrayResponse(command: 1, sequence: 0, body: Data([0xDE, 0xAD]))
    await device.drain()

    let body = try await device.send(.getFileCount)
    #expect(body == Data([0, 0, 0, 3]))          // not the stray 0xDEAD
}

@Test func concurrentCallersAreSerialized() async throws {
    let t = FakeTransport(script: .init(responses: [1: [Data([1])], 6: [Data([2])], 16: [Data([3])]]))
    let device = JensenDevice(transport: t)
    try await device.open()

    async let a = device.send(.getDeviceInfo)
    async let b = device.send(.getFileCount)
    async let c = device.send(.getCardInfo)
    _ = try await (a, b, c)

    let written = await t.written
    #expect(written.count == 3)
    #expect(Set(written.map(\.sequence)) == [0, 1, 2])   // no reuse
}

@Test func openAndCloseForwardToTransport() async throws {
    let t = FakeTransport(script: .init())
    let device = JensenDevice(transport: t)
    try await device.open()
    await device.close()
    #expect(await t.openCount == 1)
    #expect(await t.closeCount == 1)
}
