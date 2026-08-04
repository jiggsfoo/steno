import Foundation

public struct DeviceInfo: Sendable, Equatable {
    public let versionCode: String
    public let versionNumber: UInt32
    public let serialNumber: String
}

public struct FileInfo: Sendable, Equatable {
    public let name: String
    public let lengthBytes: Int
    public let signature: String
    public let version: UInt8
    /// Parsed from the filename. Nil when the device uses an unrecognised naming scheme.
    public let recordedAt: Date?
}

public struct CardInfo: Sendable, Equatable {
    public let freeMiB: Int
    public let capacityMiB: Int
    public let status: Int

    public var usedMiB: Int { max(0, capacityMiB - freeMiB) }
}

extension FileInfo {
    /// The device names its MP3 recordings `.hda`, but the bytes are plain
    /// MPEG-1 Layer III. Verified on hardware 2026-08-04: a pulled `.hda`
    /// de-frames to exactly the device-reported length and `afinfo` reports
    /// `1 ch, 48000 Hz, .mp3`, 96 kbps, with a correct duration.
    ///
    /// Nothing is transcoded and no header is wrapped — ONLY the extension is
    /// corrected, so Finder, QuickLook and AVURLAsset can all read the file.
    /// The original device filename is preserved in the sidecar.
    public var preferredExtension: String {
        let raw = (name as NSString).pathExtension.lowercased()
        return raw == "hda" ? "mp3" : raw
    }
}
