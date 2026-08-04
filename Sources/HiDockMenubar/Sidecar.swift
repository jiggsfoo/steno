import Foundation

/// The full record for one synced recording. Written next to the audio file.
/// Because sidecars hold everything, the SQLite index is disposable.
public struct Sidecar: Codable, Sendable, Equatable {
    public var signature: String
    public var deviceFilename: String
    /// Relative to the library root, so the library survives being moved.
    public var relativePath: String
    public var lengthBytes: Int
    public var durationSeconds: Double?
    public var recordedAt: Date?
    public var syncedAt: Date
    public var deviceSerial: String
    public var deviceModel: String
    /// The zone the device clock was interpreted in. The P1 has no timezone
    /// concept, so this records the assumption for later correction.
    public var timeZoneIdentifier: String
}
