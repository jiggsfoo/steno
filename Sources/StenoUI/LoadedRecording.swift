import Foundation

/// One recording with its transcript, held in memory for the library window's
/// lifetime.
///
/// `transcript` is nil until the transcription queue has been through this
/// recording. That is not an error state: the sweep is asynchronous, so a
/// freshly synced recording legitimately has none yet, and everything that
/// consumes this type has to cope with that rather than treating it as broken.
public struct LoadedRecording: Identifiable, Sendable, Equatable {
    public let sidecar: Sidecar
    public let transcript: Transcript?

    public init(sidecar: Sidecar, transcript: Transcript?) {
        self.sidecar = sidecar
        self.transcript = transcript
    }

    public var id: String { sidecar.signature }

    /// What to call this recording on screen.
    ///
    /// The title is model output and is absent until transcription runs, so
    /// there has to be something readable to fall back to. The device filename
    /// is the one string every recording is guaranteed to have.
    public var displayTitle: String {
        if let title = sidecar.title, !title.isEmpty { return title }
        return sidecar.deviceFilename
    }
}
