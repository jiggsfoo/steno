// Tests/HiDockKitTests/ResponseParserTests.swift
import Foundation
import Testing
@testable import HiDockKit

private func fileListEntry(
    version: UInt8, name: String, length: UInt32, signature: [UInt8]
) -> Data {
    var d = Data()
    d.append(version)
    let nameBytes = Array(name.utf8)
    d.append(UInt8(truncatingIfNeeded: nameBytes.count >> 16))
    d.append(UInt8(truncatingIfNeeded: nameBytes.count >> 8))
    d.append(UInt8(truncatingIfNeeded: nameBytes.count))
    d.append(contentsOf: nameBytes)
    d.append(UInt8(truncatingIfNeeded: length >> 24))
    d.append(UInt8(truncatingIfNeeded: length >> 16))
    d.append(UInt8(truncatingIfNeeded: length >> 8))
    d.append(UInt8(truncatingIfNeeded: length))
    d.append(contentsOf: [UInt8](repeating: 0, count: 6))   // padding
    d.append(contentsOf: signature)
    return d
}

@Test func parsesDeviceInfoWithPaddedSerial() throws {
    var body = Data([0x00, 0x01, 0x04, 0x03])               // version
    body.append(contentsOf: Array("SN12345".utf8))
    body.append(contentsOf: [UInt8](repeating: 0, count: 16 - 7))
    let info = try ResponseParsers.deviceInfo(body)
    #expect(info.versionCode == "1.4.3")
    #expect(info.versionNumber == 0x00010403)
    #expect(info.serialNumber == "SN12345")
}

/// Golden case captured from a real HiDock P1 on firmware 1.4.5, 2026-08-04.
/// The body is 17 bytes: a 13-character serial with no padding, NOT the
/// 16-byte padded field the reference implementations assume. Requiring 20
/// bytes here would throw shortBody on every connect to real hardware.
@Test func parsesDeviceInfoFromRealHardware() throws {
    let body = Data([
        0x00, 0x01, 0x04, 0x05,
        0x48, 0x44, 0x50, 0x31, 0x32, 0x35, 0x34, 0x35, 0x30, 0x36, 0x30, 0x32, 0x37,
    ])
    #expect(body.count == 17)
    let info = try ResponseParsers.deviceInfo(body)
    #expect(info.versionCode == "1.4.5")
    #expect(info.versionNumber == 0x00010405)
    #expect(info.serialNumber == "HDP1254506027")
}

@Test func deviceInfoThrowsOnShortBody() {
    #expect(throws: (any Error).self) { _ = try ResponseParsers.deviceInfo(Data([1, 2])) }
}

@Test func parsesSingleFileListEntry() throws {
    let sig = (0..<16).map { UInt8($0) }
    let body = fileListEntry(version: 1, name: "2026Aug04-143022-Rec1.mp3",
                             length: 1_234_567, signature: sig)
    let result = try ResponseParsers.fileList(body)
    #expect(result.files.count == 1)
    #expect(result.files[0].name == "2026Aug04-143022-Rec1.mp3")
    #expect(result.files[0].lengthBytes == 1_234_567)
    #expect(result.files[0].signature == "000102030405060708090a0b0c0d0e0f")
    #expect(result.files[0].version == 1)
}

@Test func parsesFileListWithCountHeader() throws {
    var body = Data([0xFF, 0xFF, 0x00, 0x00, 0x00, 0x02])
    body.append(fileListEntry(version: 1, name: "a.mp3", length: 10,
                              signature: [UInt8](repeating: 0xAA, count: 16)))
    body.append(fileListEntry(version: 1, name: "b.wav", length: 20,
                              signature: [UInt8](repeating: 0xBB, count: 16)))
    let result = try ResponseParsers.fileList(body)
    #expect(result.headerTotal == 2)
    #expect(result.files.map(\.name) == ["a.mp3", "b.wav"])
}

@Test func fileListStopsCleanlyOnTruncatedTrailingEntry() throws {
    var body = fileListEntry(version: 1, name: "a.mp3", length: 10,
                             signature: [UInt8](repeating: 0xAA, count: 16))
    body.append(contentsOf: [0x01, 0x00, 0x00])             // start of an entry, then nothing
    let result = try ResponseParsers.fileList(body)
    #expect(result.files.count == 1)
}

@Test func fileListSkipsEmbeddedNulBytesInNames() throws {
    var name = Array("a.mp3".utf8)
    name.append(0)
    var d = Data([1])
    d.append(contentsOf: [0, 0, UInt8(name.count)])
    d.append(contentsOf: name)
    d.append(contentsOf: [0, 0, 0, 10])
    d.append(contentsOf: [UInt8](repeating: 0, count: 6))
    d.append(contentsOf: [UInt8](repeating: 0xCC, count: 16))
    let result = try ResponseParsers.fileList(d)
    #expect(result.files[0].name == "a.mp3")
}

/// Real filenames captured from a P1 on firmware 1.4.5, 2026-08-04.
@Test func hdaRecordingsAreRenamedToMp3() {
    let f = FileInfo(name: "2026Aug04-135302-Wip02.hda", lengthBytes: 53568,
                     signature: "c74e0ac92b1708ddd40045f6b938d75c", version: 5, recordedAt: nil)
    #expect(f.preferredExtension == "mp3")
}

@Test func nonHdaExtensionsArePreserved() {
    for (name, expected) in [("a.mp3", "mp3"), ("b.WAV", "wav"), ("c.hda", "mp3")] {
        let f = FileInfo(name: name, lengthBytes: 1, signature: "s", version: 1, recordedAt: nil)
        #expect(f.preferredExtension == expected)
    }
}

@Test func parsesCardInfo() throws {
    let body = Data([0, 0, 0x30, 0x00,  0, 0, 0x78, 0x00,  0, 0, 0, 1])
    let info = try ResponseParsers.cardInfo(body)
    #expect(info.freeMiB == 0x3000)
    #expect(info.capacityMiB == 0x7800)
    #expect(info.status == 1)
}

@Test func parsesMonthNameFilenameTimestamp() throws {
    let date = try #require(ResponseParsers.recordedAt(fromFilename: "2026Aug04-143022-Rec59.hda"))
    let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    #expect(c.year == 2026 && c.month == 8 && c.day == 4)
    #expect(c.hour == 14 && c.minute == 30 && c.second == 22)
}

@Test func parsesNumericFilenameTimestamp() throws {
    let date = try #require(ResponseParsers.recordedAt(fromFilename: "20260804143022REC001.wav"))
    let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    #expect(c.year == 2026 && c.month == 8 && c.day == 4)
    #expect(c.hour == 14 && c.minute == 30 && c.second == 22)
}

@Test func returnsNilForUnparseableFilename() {
    #expect(ResponseParsers.recordedAt(fromFilename: "whatever.mp3") == nil)
}
