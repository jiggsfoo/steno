import Foundation

/// A single matching line — the unit a search returns, rather than a recording.
///
/// Carrying the whole `Segment` is what makes a result playable: `start` is the
/// second to seek to. That is the reason segment timings were persisted in
/// spec 2 rather than discarded after rendering the transcript.
public struct Moment: Identifiable, Sendable, Equatable {
    public let signature: String
    public let recordingTitle: String
    public let segment: Segment
    /// Where the query matched WITHIN `segment.text`, so the pane can mark it
    /// without searching the string a second time.
    public let highlight: Range<String.Index>

    public var id: String { "\(signature)-\(segment.start)" }
}

/// Finds playable moments across the whole library.
///
/// PURE — no I/O, no model, no stored state. The library is held in memory by
/// `LibraryStore`, so this is a function over an array, which is what makes the
/// part most likely to be wrong the part cheapest to test.
public enum TranscriptSearch {
    /// Above this, a result list stops being something a person can scan.
    public static let resultCap = 500

    /// One character matches nearly every segment in a library of prose.
    public static let minimumQueryLength = 2

    /// Returns matching moments and whether the cap bit.
    ///
    /// `capped` is reported rather than inferred from `moments.count == limit`,
    /// because a search that genuinely has exactly `limit` results is not the
    /// same as one that was truncated — and the pane says which.
    public static func moments(
        matching query: String,
        in recordings: [LoadedRecording],
        limit: Int = resultCap
    ) -> (moments: [Moment], capped: Bool) {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.count >= minimumQueryLength else { return ([], false) }

        var found: [Moment] = []
        for recording in recordings {
            guard let transcript = recording.transcript else { continue }
            for segment in transcript.segments {
                guard let range = segment.text.range(
                    of: needle, options: [.caseInsensitive, .diacriticInsensitive])
                else { continue }

                if found.count == limit { return (found, true) }
                found.append(Moment(signature: recording.sidecar.signature,
                                    recordingTitle: recording.displayTitle,
                                    segment: segment,
                                    highlight: range))
            }
        }
        return (found, false)
    }
}
