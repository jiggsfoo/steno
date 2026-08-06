import Foundation
import Testing
@testable import JensenKit

@Test func encodesTwelveByteHeaderWithSyncMarker() {
    let p = JensenPacket(command: 1, sequence: 0, body: Data())
    let bytes = [UInt8](p.encoded())
    #expect(bytes.count == 12)
    #expect(bytes[0] == 0x12)
    #expect(bytes[1] == 0x34)
    #expect(bytes[2] == 0x00 && bytes[3] == 0x01)          // command, big-endian
    #expect(Array(bytes[8...11]) == [0, 0, 0, 0])           // body length
}

@Test func encodesCommandAndSequenceBigEndian() {
    let p = JensenPacket(command: 4100, sequence: 0x01020304, body: Data())
    let bytes = [UInt8](p.encoded())
    #expect(bytes[2] == 0x10 && bytes[3] == 0x04)           // 4100 = 0x1004
    #expect(Array(bytes[4...7]) == [0x01, 0x02, 0x03, 0x04])
}

@Test func encodesBodyAndLength() {
    let p = JensenPacket(command: 5, sequence: 1, body: Data([0xAA, 0xBB, 0xCC]))
    let bytes = [UInt8](p.encoded())
    #expect(Array(bytes[8...11]) == [0, 0, 0, 3])
    #expect(Array(bytes[12...14]) == [0xAA, 0xBB, 0xCC])
}

@Test func roundTrips() throws {
    let original = JensenPacket(command: 4, sequence: 42, body: Data([1, 2, 3, 4, 5]))
    guard case let .packet(decoded, consumed) =
        try JensenPacket.decode(from: original.encoded()) else {
        Issue.record("expected a packet"); return
    }
    #expect(decoded == original)
    #expect(consumed == 17)
}

@Test func decodeReportsNeedMoreDataOnShortHeader() throws {
    let result = try JensenPacket.decode(from: Data([0x12, 0x34, 0x00]))
    #expect(result == .needMoreData)
}

@Test func decodeReportsNeedMoreDataOnTruncatedBody() throws {
    var bytes = [UInt8](JensenPacket(command: 1, sequence: 0, body: Data([9, 9, 9, 9])).encoded())
    bytes.removeLast(2)
    #expect(try JensenPacket.decode(from: Data(bytes)) == .needMoreData)
}

@Test func decodeThrowsOnBadSyncMarker() {
    #expect(throws: JensenError.invalidHeader) {
        _ = try JensenPacket.decode(from: Data([0xDE, 0xAD, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0]))
    }
}

/// The length word packs a padding byte into its top 8 bits and the body
/// length into the low 24. Padding bytes trail the body and are consumed
/// but not returned.
@Test func decodeHonoursPaddingByteInLengthWord() throws {
    var bytes: [UInt8] = [0x12, 0x34, 0x00, 0x01, 0, 0, 0, 0]
    bytes += [0x02, 0x00, 0x00, 0x03]          // padding 2, body length 3
    bytes += [0xAA, 0xBB, 0xCC]                // body
    bytes += [0x00, 0x00]                      // padding
    guard case let .packet(p, consumed) = try JensenPacket.decode(from: Data(bytes)) else {
        Issue.record("expected a packet"); return
    }
    #expect(p.body == Data([0xAA, 0xBB, 0xCC]))
    #expect(consumed == 17)
}

/// Two packets arriving in one bulk read must both decode.
@Test func decodesFirstOfTwoConcatenatedPackets() throws {
    var buffer = JensenPacket(command: 1, sequence: 1, body: Data([1])).encoded()
    buffer.append(JensenPacket(command: 2, sequence: 2, body: Data([2, 2])).encoded())

    guard case let .packet(first, consumed) = try JensenPacket.decode(from: buffer) else {
        Issue.record("expected first packet"); return
    }
    #expect(first.command == 1)

    guard case let .packet(second, _) =
        try JensenPacket.decode(from: buffer.dropFirst(consumed)) else {
        Issue.record("expected second packet"); return
    }
    #expect(second.command == 2)
    #expect(second.body == Data([2, 2]))
}

/// Pins the mask/shift arithmetic at the top of both packed fields without
/// allocating a 16 MB buffer: a maximal declared length must be read back
/// exactly and simply report needMoreData against a short buffer.
@Test func decodeHandlesMaximalDeclaredLengthWithoutOverflow() throws {
    var bytes: [UInt8] = [0x12, 0x34, 0x00, 0x01, 0, 0, 0, 0]
    bytes += [0xFF, 0xFF, 0xFF, 0xFF]          // padding 255, body length 0xFFFFFF
    #expect(try JensenPacket.decode(from: Data(bytes)) == .needMoreData)
}

/// The largest body length that still leaves the padding byte clear must
/// round-trip with padding read back as zero.
@Test func encodesLargestBodyThatKeepsPaddingByteClear() {
    let body = Data(repeating: 0xAB, count: 300_000)
    let bytes = [UInt8](JensenPacket(command: 5, sequence: 1, body: body).encoded())
    #expect(bytes[8] == 0x00)                                    // padding stays clear
    let declared = Int(bytes[9]) << 16 | Int(bytes[10]) << 8 | Int(bytes[11])
    #expect(declared == 300_000)
}

/// Regression guard: Data slices keep their parent's indices, so any decoder
/// that assumes a zero start index breaks on the second packet of a read.
@Test func decodesFromASliceWithNonZeroStartIndex() throws {
    var buffer = Data([0xFF, 0xFF, 0xFF])
    buffer.append(JensenPacket(command: 7, sequence: 3, body: Data([8])).encoded())
    let slice = buffer.dropFirst(3)
    #expect(slice.startIndex == 3)

    guard case let .packet(p, _) = try JensenPacket.decode(from: slice) else {
        Issue.record("expected a packet"); return
    }
    #expect(p.command == 7)
    #expect(p.body == Data([8]))
}
