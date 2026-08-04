import Foundation

public actor JensenDevice {
    private let transport: any USBTransport
    private var sequence: UInt32 = 0
    private var buffer = Data()

    /// Bulk reads are capped at this size. The device streams file data in
    /// chunks well under this, and oversizing costs nothing but a temp buffer.
    private static let readChunk = 64 * 1024

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
    }

    @discardableResult
    public func send(
        _ command: JensenCommand,
        body: Data = Data(),
        timeout: Duration = .seconds(5)
    ) async throws -> Data {
        try await sendRaw(command.rawValue, body: body, timeout: timeout)
    }

    func sendRaw(_ command: UInt16, body: Data, timeout: Duration) async throws -> Data {
        let seq = sequence
        sequence &+= 1
        try await transport.write(
            JensenPacket(command: command, sequence: seq, body: body).encoded())
        return try await awaitResponse(command: command, timeout: timeout)
    }

    /// Reads until a packet whose command id matches arrives, or the deadline passes.
    /// Packets for other commands are discarded as stale.
    private func awaitResponse(command: UInt16, timeout: Duration) async throws -> Data {
        let deadline = ContinuousClock.now.advanced(by: timeout)

        while true {
            if let packet = try takeBufferedPacket(matching: command) { return packet }

            guard ContinuousClock.now < deadline else {
                throw JensenError.timeout(command: command)
            }

            let chunk = try await transport.read(maxLength: Self.readChunk, timeout: timeout)
            if chunk.isEmpty {
                try await Task.sleep(for: .milliseconds(5))
                continue
            }
            buffer.append(chunk)
        }
    }

    private func takeBufferedPacket(matching command: UInt16) throws -> Data? {
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
            if packet.command == command { return packet.body }
            // else: stale response for an earlier command, drop it and keep looking
        }
        return nil
    }

    /// Reads and discards anything still queued on the IN endpoint.
    /// Must be called after a timeout before issuing the next command.
    public func drain(maxDuration: Duration = .milliseconds(500)) async {
        buffer.removeAll(keepingCapacity: true)
        let deadline = ContinuousClock.now.advanced(by: maxDuration)
        while ContinuousClock.now < deadline {
            guard let chunk = try? await transport.read(
                maxLength: Self.readChunk, timeout: .milliseconds(50)),
                  !chunk.isEmpty else { return }
        }
    }
}
