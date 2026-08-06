import Foundation

/// The one seam of spec 2. A new backend is a new file and a registry line,
/// never a change to the pipeline.
public protocol Transcriber: Sendable {
    /// Stable and persisted into every transcript's `backend` field. Renaming
    /// one orphans the provenance of every transcript already on disk.
    var id: String { get }
    var displayName: String { get }
    /// May be false for reasons outside the app's control: a model asset not
    /// downloaded, Apple Intelligence disabled, no API key.
    func isAvailable() async -> Bool
    func transcribe(audio: URL, locale: Locale) async throws -> TranscriptBody
}

public enum TranscriberError: Error, Equatable {
    case unavailable(String)
    case audioUnreadable(String)
    case backendFailed(String)
    case missingCredential(String)
}

extension TranscriberError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unavailable(let who):
            return "\(who) isn't available on this Mac right now."
        case .audioUnreadable(let path):
            return "Couldn't read the audio at \(path)."
        case .backendFailed(let detail):
            return "Transcription failed: \(detail)."
        case .missingCredential(let who):
            return "\(who) needs an API key. Add one in Settings."
        }
    }
}
