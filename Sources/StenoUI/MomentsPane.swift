import SwiftUI

/// The library window's right pane while a search is active: matching lines
/// from anywhere in the library, each one playable where it sits.
public struct MomentsPane: View {
    let moments: [Moment]
    let capped: Bool
    let onPlay: (Moment) -> Void

    public init(moments: [Moment], capped: Bool, onPlay: @escaping (Moment) -> Void) {
        self.moments = moments
        self.capped = capped
        self.onPlay = onPlay
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Self.summary(count: moments.count, capped: capped))
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 6)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Self.grouped(moments), id: \.signature) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.title).font(.caption).foregroundStyle(.secondary)
                            ForEach(group.moments) { moment in
                                Button { onPlay(moment) } label: {
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Image(systemName: "play.fill").font(.caption2)
                                        Text(TranscriptPane.timestamp(moment.segment.start))
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.tertiary)
                                        Text(highlighted(moment))
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.vertical, 3).padding(.horizontal, 6)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(12)
            }
        }
    }

    /// The matched word marked, using the range the search already computed
    /// rather than searching the string a second time.
    private func highlighted(_ moment: Moment) -> AttributedString {
        var text = AttributedString(moment.segment.text)
        if let lower = AttributedString.Index(moment.highlight.lowerBound, within: text),
           let upper = AttributedString.Index(moment.highlight.upperBound, within: text) {
            text[lower..<upper].backgroundColor = .yellow.opacity(0.35)
        }
        return text
    }

    /// Groups moments by recording, in first-appearance order.
    ///
    /// PURE. First-appearance rather than alphabetical, so the order matches
    /// the order the search walked the library — which is recency.
    ///
    /// Keyed on `signature`, not `recordingTitle`: titles are model output,
    /// and two recordings can legitimately get the same one (a weekly
    /// meeting called "Weekly Work Update" every time). Keying on title
    /// would merge those into a single group with interleaved moments and
    /// no way to tell which recording a line came from. `signature` is the
    /// one thing guaranteed unique per recording — `onPlay` already routes
    /// on it, not on the title, so the display grouping now agrees with the
    /// click routing.
    nonisolated static func grouped(
        _ moments: [Moment]
    ) -> [(signature: String, title: String, moments: [Moment])] {
        var order: [String] = []
        var buckets: [String: [Moment]] = [:]
        for moment in moments {
            if buckets[moment.signature] == nil { order.append(moment.signature) }
            buckets[moment.signature, default: []].append(moment)
        }
        return order.map {
            (signature: $0,
             title: buckets[$0]?.first?.recordingTitle ?? "",
             moments: buckets[$0] ?? [])
        }
    }

    /// What the header says above the results.
    ///
    /// PURE. Says when the cap bit, because a list that silently stopped at 500
    /// would otherwise read as "that is everything".
    nonisolated static func summary(count: Int, capped: Bool) -> String {
        if count == 0 { return "No matches" }
        if capped { return "First \(count) moments" }
        return count == 1 ? "1 moment" : "\(count) moments"
    }
}
