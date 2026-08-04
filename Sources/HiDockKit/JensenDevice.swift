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
        await acquire()
        defer { release() }
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
            await drainLocked(maxDuration: .milliseconds(500))
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
                // Deliberately `try`, not `try?`. Swallowing cancellation here
                // strips the backoff and spins this loop while holding the gate
                // until the deadline.
                try await Task.sleep(for: .milliseconds(5))
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
        await acquire()
        defer { release() }
        await drainLocked(maxDuration: maxDuration)
    }

    /// Caller must already hold the gate. `perform`'s error path calls this
    /// directly, since it is still inside its own gated section.
    private func drainLocked(maxDuration: Duration) async {
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

    // MARK: - Typed commands

    public func deviceInfo(timeout: Duration = .seconds(5)) async throws -> DeviceInfo {
        try ResponseParsers.deviceInfo(await send(.getDeviceInfo, timeout: timeout))
    }

    public func cardInfo(timeout: Duration = .seconds(5)) async throws -> CardInfo {
        try ResponseParsers.cardInfo(await send(.getCardInfo, timeout: timeout))
    }

    public func fileCount(timeout: Duration = .seconds(5)) async throws -> Int {
        let body = try await send(.getFileCount, timeout: timeout)
        guard body.count >= 4 else {
            throw JensenError.shortBody(command: 6, expected: 4, got: body.count)
        }
        let b = [UInt8](body)
        return Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
    }

    public func listFiles(timeout: Duration = .seconds(20)) async throws -> [FileInfo] {
        try ResponseParsers.fileList(await send(.getFileList, timeout: timeout)).files
    }

    /// Streams a recording to `url`. Never buffers the whole file in memory.
    /// Throws `transferIncomplete` and deletes the partial file if the byte
    /// count does not match what the device reported.
    public func transferFile(
        _ file: FileInfo,
        to url: URL,
        chunkTimeout: Duration = .seconds(30),
        progress: @Sendable (Int, Int) -> Void
    ) async throws {
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        fm.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else {
            throw JensenError.interfaceUnavailable("cannot open \(url.path) for writing")
        }

        var received = 0
        var failure: (any Error)?

        // Holds the same FIFO gate as every other command: a transfer streams
        // many packets, and a concurrent command would interleave with them.
        await acquire()
        defer { release() }

        let seq = sequence
        sequence &+= 1

        do {
            let body = Data(file.name.utf8)
            try await transport.write(
                JensenPacket(command: JensenCommand.transferFile.rawValue,
                             sequence: seq, body: body).encoded())

            // Resets on every received chunk. A single deadline for the whole
            // transfer would cap a 170 MB WAV at chunkTimeout regardless of
            // link speed; this bounds the gap *between* chunks instead.
            var deadline = ContinuousClock.now.advanced(by: chunkTimeout)
            while received < file.lengthBytes {
                if let chunk = try takeBufferedPacket(
                    command: JensenCommand.transferFile.rawValue, sequence: seq), !chunk.isEmpty {
                    let slice = chunk.prefix(file.lengthBytes - received)
                    try handle.write(contentsOf: slice)
                    received += slice.count
                    progress(received, file.lengthBytes)
                    deadline = ContinuousClock.now.advanced(by: chunkTimeout)
                    continue
                }

                guard ContinuousClock.now < deadline else { break }
                let raw = try await transport.read(maxLength: 64 * 1024, timeout: chunkTimeout)
                if raw.isEmpty {
                    try await Task.sleep(for: .milliseconds(5))
                } else {
                    buffer.append(raw)
                }
            }
        } catch {
            failure = error
        }

        try? handle.close()

        if let failure {
            try? fm.removeItem(at: url)
            buffer.removeAll(keepingCapacity: true)
            // drainLocked, NOT drain(): transferFile already holds the gate and
            // the public drain() takes it. Calling it here self-deadlocks.
            await drainLocked(maxDuration: .milliseconds(500))
            throw failure
        }
        guard received == file.lengthBytes else {
            try? fm.removeItem(at: url)
            // Same cleanup as the sibling catch above: a short transfer leaves
            // unread bytes on the endpoint that would corrupt the next command.
            buffer.removeAll(keepingCapacity: true)
            await drainLocked(maxDuration: .milliseconds(500))
            throw JensenError.transferIncomplete(expected: file.lengthBytes, got: received)
        }
    }
}
