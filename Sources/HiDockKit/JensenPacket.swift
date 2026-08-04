import Foundation

public struct JensenPacket: Sendable, Equatable {
    public let command: UInt16
    public let sequence: UInt32
    public let body: Data

    public init(command: UInt16, sequence: UInt32, body: Data = Data()) {
        self.command = command
        self.sequence = sequence
        self.body = body
    }

    public init(command: JensenCommand, sequence: UInt32, body: Data = Data()) {
        self.init(command: command.rawValue, sequence: sequence, body: body)
    }

    public static let headerSize = 12
    private static let syncMarker: [UInt8] = [0x12, 0x34]

    public func encoded() -> Data {
        var out = Data(capacity: Self.headerSize + body.count)
        out.append(contentsOf: Self.syncMarker)
        out.append(UInt8(truncatingIfNeeded: command >> 8))
        out.append(UInt8(truncatingIfNeeded: command))
        out.append(UInt8(truncatingIfNeeded: sequence >> 24))
        out.append(UInt8(truncatingIfNeeded: sequence >> 16))
        out.append(UInt8(truncatingIfNeeded: sequence >> 8))
        out.append(UInt8(truncatingIfNeeded: sequence))
        let length = UInt32(body.count)          // padding byte is 0 on send
        out.append(UInt8(truncatingIfNeeded: length >> 24))
        out.append(UInt8(truncatingIfNeeded: length >> 16))
        out.append(UInt8(truncatingIfNeeded: length >> 8))
        out.append(UInt8(truncatingIfNeeded: length))
        out.append(body)
        return out
    }

    public enum DecodeResult: Sendable, Equatable {
        case needMoreData
        case packet(JensenPacket, consumed: Int)
    }

    /// Decodes one packet from the front of `buffer`.
    /// `buffer` may be a slice; all indexing is relative to `startIndex`.
    public static func decode(from buffer: Data) throws -> DecodeResult {
        let base = buffer.startIndex
        let available = buffer.count
        guard available >= headerSize else { return .needMoreData }

        guard buffer[base] == syncMarker[0], buffer[base + 1] == syncMarker[1] else {
            throw JensenError.invalidHeader
        }

        let command = UInt16(buffer[base + 2]) << 8 | UInt16(buffer[base + 3])
        let sequence = UInt32(buffer[base + 4]) << 24
            | UInt32(buffer[base + 5]) << 16
            | UInt32(buffer[base + 6]) << 8
            | UInt32(buffer[base + 7])

        let raw = UInt32(buffer[base + 8]) << 24
            | UInt32(buffer[base + 9]) << 16
            | UInt32(buffer[base + 10]) << 8
            | UInt32(buffer[base + 11])
        let padding = Int((raw >> 24) & 0xFF)
        let bodyLength = Int(raw & 0x00FF_FFFF)

        let total = headerSize + bodyLength + padding
        guard available >= total else { return .needMoreData }

        let bodyStart = base + headerSize
        let body = Data(buffer[bodyStart ..< bodyStart + bodyLength])
        let packet = JensenPacket(command: command, sequence: sequence, body: body)
        return .packet(packet, consumed: total)
    }
}
