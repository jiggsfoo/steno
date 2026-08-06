import SwiftUI

/// Content of the `Window(_:id: MenuBarView.libraryWindowID)` scene.
///
/// A window, not a popover: `MenuBarExtra(.window)` builds its content lazily
/// and constrains its height, which is what collapsed the menu's two-line rows
/// in spec 2. Nothing about this window belongs in there.
public struct LibraryWindow: View {
    @Bindable var model: AppModel
    @State private var store = LibraryStore()
    @State private var player = AudioPlayer()

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        NavigationSplitView {
            LibrarySidebar(store: store)
                .searchable(text: $store.query, prompt: "Search transcripts")
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            if let selected = store.recordings.first(where: { $0.id == store.selection }) {
                // `.id(selected.id)`: without this, a selection change is an
                // UPDATE to the same `TranscriptPane` identity, not a new
                // instance — SwiftUI preserves `@State private var
                // isFollowing` across it. A hand-scroll that detaches
                // following on one recording would then leak into every
                // recording selected afterwards, each opening already
                // "paused" with no scroll position of its own. Forcing a
                // fresh identity per recording resets both `isFollowing` and
                // the transcript's scroll position together, which is what
                // a different recording actually is: unrelated content, not
                // a continuation of the last one.
                TranscriptPane(recording: selected, player: player)
                    .id(selected.id)
            } else {
                // The real empty state, not scaffolding: Task 7 adds a branch
                // above this one, and this stays as the nothing-selected case.
                ContentUnavailableView("No recording selected", systemImage: "waveform")
            }
        }
        .task { await reload() }
        // Loading audio belongs here rather than inside a detail branch: a
        // closure created in one branch would capture the selection that was
        // current when that branch was built, and load the previous
        // recording's audio.
        .onChange(of: store.selection) { _, newValue in
            guard let recording = store.recordings.first(where: { $0.id == newValue })
            else { return }
            player.load(model.libraryRoot
                .appendingPathComponent(recording.sidecar.relativePath))
        }
        // The sweep finishing is exactly when new transcripts exist. `AppModel`
        // is `@Observable`, so this needs no timer and no polling.
        .onChange(of: model.transcriptionProgress) { _, progress in
            if progress == nil { Task { await reload() } }
        }
    }

    /// `LibraryStore.load` (Task 2, closed — not modified here) has no guard
    /// of its own against overlapping invocations, and this view calls
    /// `reload()` from both `.task` and the `transcriptionProgress` change
    /// above: exactly the pattern where a slower earlier load could finish
    /// after, and clobber, a newer one's results.
    ///
    /// Guarded here instead, by simply refusing to start a second load while
    /// one is in flight. That is sufficient — not just a narrowed race — because
    /// `store` and this view are both `@MainActor`, `MainActor` is a serial
    /// executor, and `store.load` sets `isLoading = true` synchronously before
    /// its first `await`. So between this guard check and that assignment there
    /// is no suspension point at which a second caller could observe
    /// `isLoading == false` and slip through: the whole "check, then start" step
    /// runs as one uninterrupted turn on the actor.
    private func reload() async {
        guard !store.isLoading else { return }
        await store.load(root: model.libraryRoot, sidecars: model.librarySidecars())
    }
}
