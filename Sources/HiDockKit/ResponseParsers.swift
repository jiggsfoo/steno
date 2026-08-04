import Foundation

public enum ResponseParsers {

    public static func deviceInfo(_ body: Data) throws -> DeviceInfo {
        // 4 version bytes plus a serial of at least one character.
        //
        // The reference implementations assume a fixed 16-byte serial field
        // (20 bytes total). A real P1 on firmware 1.4.5 returns a 13-character
        // serial with NO padding, so the body is 17 bytes. Requiring 20 would
        // throw shortBody on every connect. Measured 2026-08-04.
        guard body.count >= 5 else {
            throw JensenError.shortBody(command: 1, expected: 5, got: body.count)
        }
        let b = [UInt8](body)
        let versionNumber = UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
        let versionCode = "\(b[1]).\(b[2]).\(b[3])"
        let serial = String(decoding: b[4...].filter { $0 > 0 }, as: UTF8.self)
        return DeviceInfo(versionCode: versionCode, versionNumber: versionNumber, serialNumber: serial)
    }

    public static func cardInfo(_ body: Data) throws -> CardInfo {
        guard body.count >= 12 else {
            throw JensenError.shortBody(command: 16, expected: 12, got: body.count)
        }
        let b = [UInt8](body)
        func u32(_ i: Int) -> Int {
            Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
        }
        return CardInfo(freeMiB: u32(0), capacityMiB: u32(4), status: u32(8))
    }

    public static func fileList(_ body: Data) throws -> (files: [FileInfo], headerTotal: Int) {
        let b = [UInt8](body)
        var pos = 0
        var headerTotal = 0
        var files: [FileInfo] = []

        if b.count >= 6, b[0] == 0xFF, b[1] == 0xFF {
            headerTotal = Int(b[2]) << 24 | Int(b[3]) << 16 | Int(b[4]) << 8 | Int(b[5])
            pos = 6
        }

        while pos < b.count {
            let start = pos
            guard pos + 4 <= b.count else { break }
            let version = b[pos]; pos += 1

            let nameLength = Int(b[pos]) << 16 | Int(b[pos + 1]) << 8 | Int(b[pos + 2])
            pos += 3

            guard pos + nameLength <= b.count else { pos = start; break }
            let name = String(decoding: b[pos ..< pos + nameLength].filter { $0 > 0 }, as: UTF8.self)
            pos += nameLength

            guard pos + 4 <= b.count else { pos = start; break }
            let length = Int(b[pos]) << 24 | Int(b[pos + 1]) << 16 | Int(b[pos + 2]) << 8 | Int(b[pos + 3])
            pos += 4

            guard pos + 6 <= b.count else { pos = start; break }
            pos += 6                                        // padding

            guard pos + 16 <= b.count else { pos = start; break }
            let signature = b[pos ..< pos + 16].map { String(format: "%02x", $0) }.joined()
            pos += 16

            files.append(FileInfo(
                name: name,
                lengthBytes: length,
                signature: signature,
                version: version,
                recordedAt: recordedAt(fromFilename: name)))
        }

        return (files, headerTotal)
    }

    private static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                     "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// The P1 has no timezone concept, so its clock is read as local wall time.
    public static func recordedAt(fromFilename filename: String) -> Date? {
        if let d = parseMonthNameForm(filename) { return d }
        return parseNumericForm(filename)
    }

    /// e.g. 2026Aug04-143022-Rec59.hda
    private static func parseMonthNameForm(_ s: String) -> Date? {
        let pattern = /(\d{4})(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)(\d{1,2})-(\d{2})(\d{2})(\d{2})/
        guard let m = s.firstMatch(of: pattern),
              let monthIndex = monthNames.firstIndex(of: String(m.2)) else { return nil }
        return makeDate(year: Int(m.1), month: monthIndex + 1, day: Int(m.3),
                        hour: Int(m.4), minute: Int(m.5), second: Int(m.6))
    }

    /// e.g. 20260804143022REC001.wav
    private static func parseNumericForm(_ s: String) -> Date? {
        let pattern = /(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})/
        guard let m = s.firstMatch(of: pattern) else { return nil }
        return makeDate(year: Int(m.1), month: Int(m.2), day: Int(m.3),
                        hour: Int(m.4), minute: Int(m.5), second: Int(m.6))
    }

    private static func makeDate(year: Int?, month: Int?, day: Int?,
                                 hour: Int?, minute: Int?, second: Int?) -> Date? {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day
        c.hour = hour; c.minute = minute; c.second = second
        return Calendar.current.date(from: c)
    }
}
