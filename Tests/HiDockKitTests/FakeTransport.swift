// Tests/HiDockKitTests/FakeTransport.swift
import Foundation
@testable import HiDockKit

/// Scriptable transport. Responses are keyed by command id and echo the
/// request's sequence, matching real device behaviour.
actor FakeTransport: USBTransport {
    struct Script: Sendable {
        var responses: [UInt16: [Data]] = [:]
        /// Commands the device deliberately never answers.
        var readTimeoutFor: Set<UInt16> = []
        /// Wall-clock cost of every read. Without this no test can exercise a
        /// timeout path, which is how a whole class of bugs stayed invisible.
        var readDelay: Duration = .zero
    }

    private let script: Script
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
        if script.readTimeoutFor.contains(p.command) { return }
        for body in script.responses[p.command] ?? [] {
            pending.append(JensenPacket(command: p.command, sequence: p.sequence, body: body).encoded())
        }
    }

    /// Hands back at most `readSplit` bytes per call, so encoded packets
    /// genuinely arrive across multiple reads and the device layer has to
    /// reassemble them. A fake that always returned whole packets would let a
    /// broken reassembler pass.
    private static let readSplit = 64

    func read(maxLength: Int, timeout: Duration) async throws -> Data {
        if script.readDelay > .zero {
            try? await Task.sleep(for: min(script.readDelay, timeout))
        }
        guard !pending.isEmpty else { return Data() }
        let next = pending.removeFirst()
        guard next.count > Self.readSplit else { return next }
        pending.insert(next.dropFirst(Self.readSplit), at: 0)
        return Data(next.prefix(Self.readSplit))
    }

    /// Queue an unsolicited packet, simulating a response that arrives after
    /// its command already timed out. `delay` defers it so the late-arrival
    /// case is exercised rather than the trivially-already-queued one.
    func injectStrayResponse(
        command: UInt16, sequence: UInt32, body: Data, after delay: Duration = .zero
    ) async {
        if delay > .zero { try? await Task.sleep(for: delay) }
        pending.append(JensenPacket(command: command, sequence: sequence, body: body).encoded())
    }
}
