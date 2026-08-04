// Tests/HiDockKitTests/FakeTransport.swift
import Foundation
@testable import HiDockKit

/// Scriptable transport. Each written command id maps to the responses the
/// device would return, popped in order.
actor FakeTransport: USBTransport {
    struct Script: Sendable {
        var responses: [UInt16: [Data]] = [:]
        var readTimeoutFor: Set<UInt16> = []
    }

    private var script: Script
    private var pending: [Data] = []
    private(set) var written: [JensenPacket] = []
    private(set) var openCount = 0
    private(set) var closeCount = 0

    init(script: Script) { self.script = script }

    func open() async throws { openCount += 1 }
    func close() async { closeCount += 1 }

    func write(_ data: Data) async throws {
        guard case let .packet(p, _) = try JensenPacket.decode(from: data) else { return }
        written.append(p)
        if script.readTimeoutFor.contains(p.command) { return }   // deliberately answer nothing
        for body in script.responses[p.command] ?? [] {
            pending.append(JensenPacket(command: p.command, sequence: p.sequence, body: body).encoded())
        }
    }

    /// Hands back at most `readSplit` bytes per call, so encoded packets
    /// genuinely arrive across multiple reads and the device layer has to
    /// reassemble them. A fake that always returns whole packets would let a
    /// broken reassembler pass.
    private static let readSplit = 64

    func read(maxLength: Int, timeout: Duration) async throws -> Data {
        guard !pending.isEmpty else { return Data() }
        let next = pending.removeFirst()
        guard next.count > Self.readSplit else { return next }
        pending.insert(next.dropFirst(Self.readSplit), at: 0)
        return Data(next.prefix(Self.readSplit))
    }

    /// Queue an unsolicited packet, simulating a late response arriving after a timeout.
    func injectStrayResponse(command: UInt16, sequence: UInt32, body: Data) {
        pending.append(JensenPacket(command: command, sequence: sequence, body: body).encoded())
    }
}
