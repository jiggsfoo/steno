import Foundation

/// One span of recognised speech.
public struct Segment: Codable, Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var text: String
    /// Populated only by backends that diarize. `SpeechAnalyzer` leaves it nil.
    public var speaker: Int?

    public init(start: Double, end: Double, text: String, speaker: Int? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.speaker = speaker
    }
}

/// What a `Transcriber` produces. Carries NO signature on purpose — only
/// `TranscriptStore.write` may stamp one, and it takes it from the sidecar it
/// was handed. A backend therefore cannot mislabel its own output.
public struct TranscriptBody: Sendable, Equatable {
    public var text: String
    public var segments: [Segment]
    public var locale: String
    public var backend: String
    public var modelID: String

    public init(text: String, segments: [Segment], locale: String,
                backend: String, modelID: String) {
        self.text = text
        self.segments = segments
        self.locale = locale
        self.backend = backend
        self.modelID = modelID
    }
}

/// The canonical transcript for one recording, stored beside its audio.
///
/// Expensive to recompute in money and minutes, so unlike `index.sqlite` this
/// is NOT disposable derived state. The note in a topic folder is rendered from
/// it; this file is the thing that must survive.
public struct Transcript: Codable, Sendable, Equatable {
    /// Binds this transcript to exactly one recording. Verified on every read.
    public var signature: String
    public var text: String
    public var segments: [Segment]
    public var locale: String
    public var backend: String
    public var modelID: String
    public var transcribedAt: Date
    public var audioDurationSeconds: Double?

    public init(signature: String, text: String, segments: [Segment], locale: String,
                backend: String, modelID: String, transcribedAt: Date,
                audioDurationSeconds: Double?) {
        self.signature = signature
        self.text = text
        self.segments = segments
        self.locale = locale
        self.backend = backend
        self.modelID = modelID
        self.transcribedAt = transcribedAt
        self.audioDurationSeconds = audioDurationSeconds
    }

    init(body: TranscriptBody, sidecar: Sidecar, transcribedAt: Date) {
        self.init(signature: sidecar.signature,
                  text: body.text,
                  segments: body.segments,
                  locale: body.locale,
                  backend: body.backend,
                  modelID: body.modelID,
                  transcribedAt: transcribedAt,
                  audioDurationSeconds: sidecar.durationSeconds)
    }
}
