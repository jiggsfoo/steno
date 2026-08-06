import SwiftUI

/// The library window's left pane: recordings grouped by topic.
public struct LibrarySidebar: View {
    @Bindable var store: LibraryStore

    public init(store: LibraryStore) { self.store = store }

    /// The name a recording with no topic is filed under on screen.
    ///
    /// Filing has never run on the real library, so today every recording lands
    /// here — which makes this a real heading rather than an edge case.
    ///
    /// `nonisolated`: `LibrarySidebar` is a `View` and therefore implicitly
    /// `@MainActor`, but `grouped(_:)` below has to stay `nonisolated` to be
    /// the pure, synchronously-testable function the interface calls for. A
    /// plain `static let` of a `Sendable` value (`String`) can be `nonisolated`
    /// with no `(unsafe)` needed — same rationale as `MenuBarView.dateFormatter`.
    nonisolated static let unfiled = "Unfiled"

    public var body: some View {
        List(selection: $store.selection) {
            ForEach(Self.grouped(store.recordings), id: \.topic) { group in
                Section(group.topic) {
                    ForEach(group.recordings) { recording in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(recording.displayTitle).lineLimit(1)
                            Text(Self.subtitle(for: recording))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(recording.id)
                    }
                }
            }
        }
    }

    /// Groups recordings by topic, named topics alphabetically then Unfiled.
    ///
    /// PURE, and therefore the testable part. Unfiled sorts last so a library
    /// that is entirely unfiled today does not bury real topics under a growing
    /// pile tomorrow. The comparator treats Unfiled as strictly greater than
    /// every named topic and named topics compare among themselves alphabetically
    /// — a consistent strict weak ordering for any number of groups, not just
    /// the two-element cases the tests exercise, since a bucket key is unique
    /// per topic string and "Unfiled" can therefore appear on at most one side
    /// of any comparison.
    nonisolated static func grouped(
        _ recordings: [LoadedRecording]
    ) -> [(topic: String, recordings: [LoadedRecording])] {
        let buckets = Dictionary(grouping: recordings) { $0.sidecar.topic ?? unfiled }
        return buckets
            .map { (topic: $0.key, recordings: $0.value) }
            .sorted {
                if $0.topic == unfiled { return false }
                if $1.topic == unfiled { return true }
                return $0.topic.localizedCaseInsensitiveCompare($1.topic) == .orderedAscending
            }
    }

    nonisolated static func subtitle(for recording: LoadedRecording) -> String {
        let duration = recording.sidecar.durationSeconds.map {
            String(format: "%d:%02d", Int($0) / 60, Int($0) % 60)
        } ?? "—"
        guard let recorded = recording.sidecar.recordedAt else { return duration }
        return "\(Self.dayFormatter.string(from: recorded)) · \(duration)"
    }

    /// `nonisolated`: `DateFormatter` is `Sendable`, so this needs no
    /// `(unsafe)` — same rationale as `unfiled` above and `MenuBarView`'s own
    /// `dateFormatter`. `subtitle(for:)` reads it synchronously and must stay
    /// `nonisolated` to remain a pure, testable function.
    nonisolated private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "MMM d"
        return f
    }()
}
