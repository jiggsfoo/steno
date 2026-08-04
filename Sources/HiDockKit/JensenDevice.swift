import Foundation

public actor JensenDevice {
    private let transport: any USBTransport
    private var sequence: UInt32 = 0
    private var buffer = Data()

    // FIFO gate. Swift actors are reentrant, so actor isolation alone does NOT
    // keep one command on the wire at a time — a caller suspended at
    // `transport.write` releases the actor and lets the next caller in.
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private static let readChunk = 64 * 1024
    private static let maxReadWindow = Duration.milliseconds(250)

    public init(transport: any USBTransport) {
        self.transport = transport
    }

    public func open() async throws {
        try await transport.open()
        buffer.removeAll(keepingCapacity: true)
        sequence = 0
        // Some devices reject commands issued immediately after interface claim.
        try? await Task.sleep(for: .milliseconds(300))
    }

    public func close() async {
        await transport.close()
        buffer.removeAll(keepingCapacity: true)
        sequence = 0
    }

    // MARK: - Serialization

    private func acquire() async {
        guard isBusy else { isBusy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { isBusy = false } else { waiters.removeFirst().resume() }
    }

    // MARK: - Commands

    @discardableResult
    public func send(
        _ command: JensenCommand,
        body: Data = Data(),
        timeout: Duration = .seconds(5)
    ) async throws -> Data {
        try await sendRaw(command.rawValue, body: body, timeout: timeout)
    }

    func sendRaw(_ command: UInt16, body: Data, timeout: Duration) async throws -> Data {
        await acquire()
        defer { release() }
        return try await perform(command: command, body: body, timeout: timeout)
    }

    /// Caller must already hold the gate.
    ///
    /// Deliberately does NOT drain before writing. `drain` issues a read with a
    /// 50 ms timeout before re-checking its own deadline, so even a 1 ms budget
    /// blocks for up to 50 ms against a quiet endpoint — on every command. The
    /// endpoint is left clean by the error path below instead.
    private func perform(command: UInt16, body: Data, timeout: Duration) async throws -> Data {
        let seq = sequence
        sequence &+= 1
        do {
            try await transport.write(
                JensenPacket(command: command, sequence: seq, body: body).encoded())
            return try await awaitResponse(command: command, sequence: seq, timeout: timeout)
        } catch {
            // A failed command must leave nothing behind: a stranded partial
            // packet would swallow the next response, and a late reply would
            // be waiting on the endpoint for whoever comes next.
            buffer.removeAll(keepingCapacity: true)
            await drain()
            throw error
        }
    }

    /// Matches on (command, sequence). The device echoes the request sequence,
    /// verified on hardware, so a stale reply to an abandoned command is
    /// distinguishable from the answer to its retry.
    private func awaitResponse(
        command: UInt16, sequence expected: UInt32, timeout: Duration
    ) async throws -> Data {
        let deadline = ContinuousClock.now.advanced(by: timeout)

        while true {
            if let body = try takeBufferedPacket(command: command, sequence: expected) {
                return body
            }

            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { throw JensenError.timeout(command: command) }

            // Never read for longer than the command has left, or the call
            // could run to roughly twice its stated timeout.
            let chunk = try await transport.read(
                maxLength: Self.readChunk, timeout: min(remaining, Self.maxReadWindow))
            if chunk.isEmpty {
                try? await Task.sleep(for: .milliseconds(5))
            } else {
                buffer.append(chunk)
            }
        }
    }

    private func takeBufferedPacket(command: UInt16, sequence expected: UInt32) throws -> Data? {
        while !buffer.isEmpty {
            let result: JensenPacket.DecodeResult
            do {
                result = try JensenPacket.decode(from: buffer)
            } catch JensenError.invalidHeader {
                // Stream is desynced. Nothing in this buffer can be trusted.
                buffer.removeAll(keepingCapacity: true)
                throw JensenError.invalidHeader
            }

            guard case let .packet(packet, consumed) = result else { return nil }
            buffer.removeFirst(consumed)
            if packet.command == command && packet.sequence == expected { return packet.body }
            // else: a reply to an abandoned command. Drop it and keep looking.
        }
        return nil
    }

    /// Reads and discards anything still queued on the IN endpoint.
    ///
    /// Requires several consecutive quiet windows rather than one, because a
    /// single empty read only means nothing arrived in the last 50 ms. The
    /// response this exists to catch is precisely the one that arrives late.
    public func drain(maxDuration: Duration = .milliseconds(500)) async {
        buffer.removeAll(keepingCapacity: true)
        let deadline = ContinuousClock.now.advanced(by: maxDuration)
        var consecutiveEmpty = 0

        while ContinuousClock.now < deadline {
            let chunk = (try? await transport.read(
                maxLength: Self.readChunk, timeout: .milliseconds(50))) ?? Data()
            if chunk.isEmpty {
                consecutiveEmpty += 1
                if consecutiveEmpty >= 3 { return }
            } else {
                consecutiveEmpty = 0
            }
        }
    }
}
