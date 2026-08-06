import Foundation
import Observation

/// The library window's model: every recording, paired with its transcript,
/// held in memory for the window's lifetime.
///
/// Loading is deliberately eager and one-shot rather than lazy per row. The
/// whole point of this window is search, and search needs every transcript in
/// hand — a lazy loader would fetch them all on the first keystroke anyway,
/// just less predictably.
@MainActor
@Observable
public final class LibraryStore {
    public private(set) var recordings: [LoadedRecording] = []
    public private(set) var isLoading = false

    /// Live search text. Empty means "not searching", which is a different
    /// state from "searched and found nothing".
    public var query: String = ""

    /// Selected recording's signature, or nil before anything is chosen.
    public var selection: String?

    public init() {}

    /// Reads every transcript off the main actor and assigns the result in one
    /// go.
    ///
    /// `TranscriptStore.transcript(for:)` decodes JSON and verifies a signature
    /// per recording, so this is N decodes — the same work spec 2 had to move
    /// off the main actor for the transcription sweep. Doing it inline would
    /// hitch the window open on a large library.
    public func load(root: URL, sidecars: [Sidecar]) async {
        isLoading = true
        defer { isLoading = false }

        let loaded = await Task.detached {
            let store = TranscriptStore(root: root)
            return sidecars.map {
                LoadedRecording(sidecar: $0, transcript: store.transcript(for: $0))
            }
        }.value

        recordings = loaded
    }
}
