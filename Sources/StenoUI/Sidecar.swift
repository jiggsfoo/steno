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

    // MARK: - Spec 2
    //
    // All optional, so every sidecar written before spec 2 still decodes. They
    // are the DERIVED half of the record: the canonical transcript is its own
    // file, and the note in a topic folder is regenerated from these.

    /// Model-derived short title. Feeds `MenuRow`'s second line.
    public var title: String?
    /// Sanitised folder name, or nil when nothing was filed. Always the output
    /// of `TopicName.sanitised(_:)` — never a raw model string.
    public var topic: String?
    public var transcribedAt: Date?
    /// The `Transcriber.id` that produced the transcript.
    public var transcriptBackend: String?
    /// Bounds automatic retry so a permanently undecodable recording does not
    /// re-attempt on every launch forever. Manual retry ignores it.
    public var transcriptionAttempts: Int?

    public init(signature: String, deviceFilename: String, relativePath: String,
                lengthBytes: Int, durationSeconds: Double?, recordedAt: Date?,
                syncedAt: Date, deviceSerial: String, deviceModel: String,
                timeZoneIdentifier: String,
                title: String? = nil, topic: String? = nil,
                transcribedAt: Date? = nil, transcriptBackend: String? = nil,
                transcriptionAttempts: Int? = nil) {
        self.signature = signature
        self.deviceFilename = deviceFilename
        self.relativePath = relativePath
        self.lengthBytes = lengthBytes
        self.durationSeconds = durationSeconds
        self.recordedAt = recordedAt
        self.syncedAt = syncedAt
        self.deviceSerial = deviceSerial
        self.deviceModel = deviceModel
        self.timeZoneIdentifier = timeZoneIdentifier
        self.title = title
        self.topic = topic
        self.transcribedAt = transcribedAt
        self.transcriptBackend = transcriptBackend
        self.transcriptionAttempts = transcriptionAttempts
    }
}
