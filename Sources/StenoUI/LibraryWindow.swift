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
    /// Set when `reload()` is asked to run again while a load is already in
    /// flight. See `reload()`'s own doc comment for why this caller, unlike
    /// the other two, cannot just let that request be dropped.
    @State private var reloadQueued = false

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        NavigationSplitView {
            LibrarySidebar(store: store)
                .searchable(text: $store.query, prompt: "Search transcripts")
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            let search = TranscriptSearch.moments(matching: store.query, in: store.recordings)
            Self.detailContent(
                for: store.recordings.first(where: { $0.id == store.selection }),
                player: player,
                query: store.query,
                moments: search.moments,
                capped: search.capped,
                knownTopics: RecordingEditor.topicChoices(from: store.recordings),
                model: model,
                onSaved: { await reload() }
            ) { moment in
                // A moment lands you somewhere: seek and play its recording,
                // then select it so clearing the query leaves you in that
                // transcript at that position. Loading is left to the
                // `.onChange(of: store.selection)` below where possible;
                // `player.load` here is the one that actually runs when the
                // recording is not already the loaded one, and it is a
                // guarded no-op (see `AudioPlayer.load`) on the redundant
                // call that `.onChange` schedules for the same URL — so
                // whichever of the two runs second cannot reset the seek
                // this closure is about to perform.
                if let recording = store.recordings.first(where: { $0.id == moment.signature }) {
                    player.load(model.libraryRoot
                        .appendingPathComponent(recording.sidecar.relativePath))
                    player.seek(to: moment.segment.start)
                    player.play()
                }
                store.selection = moment.signature
            }
        }
        .task {
            await reload()
            // REOPENING. `.onDisappear` below stopped the player, which nils
            // its `AVPlayer` and its `loadedURL`. But `@State` is owned by
            // SwiftUI, which is free to keep a closed window's state alive --
            // the same premise `.onDisappear` exists for, read in the other
            // direction. A window reopened with its `store.selection` intact
            // therefore has a selection and no player, and
            // `.onChange(of: store.selection)` cannot fire for a selection
            // that never changed: every transcript line click and the play
            // button would be silent no-ops.
            //
            // Here rather than in a bare `.onAppear` because it must run
            // AFTER `reload()` -- the lookup needs `store.recordings`
            // populated, which is not guaranteed on a fresh window. On a fresh
            // window `selection` is nil and this is a no-op; on a reopened one
            // it restores exactly what was playing.
            loadAudio(for: store.selection)
        }
        // The Dock icon, paired exactly with `.onDisappear` below. Not folded
        // into the `.task` above: that one is `async`, and a hop would let the
        // window draw before the app had an icon, which is the flicker this
        // pairing exists to avoid. See `activationPolicy(isLibraryOpen:)`.
        .onAppear { NSApp.setActivationPolicy(Self.activationPolicy(isLibraryOpen: true)) }
        // Closing the window must stop the audio. `AudioPlayer`'s `isolated
        // deinit` already tears the periodic observer down, but only once the
        // player is actually deallocated -- and `@State` is owned by SwiftUI,
        // which is free to keep a closed window's state alive. One explicit
        // line is cheap next to a window that is gone but still playing.
        //
        // The policy revert rides along here rather than getting its own more
        // reliable AppKit trigger. `.onDisappear` on a `Window` scene is not
        // guaranteed -- the comment above says so -- and if it does not fire,
        // the app keeps a Dock icon until it is relaunched. That degradation
        // is cosmetic and self-correcting, which the audio next to it is not:
        // the two SHARE A FATE, so the existing human check for "closing the
        // window stops playback" is also the check for this. Buying more
        // reliability means bridging to AppKit to find and observe this
        // window's `NSWindow` -- new untestable machinery in a view, to fix a
        // stuck icon. Not proportionate.
        .onDisappear {
            player.stop()
            NSApp.setActivationPolicy(Self.activationPolicy(isLibraryOpen: false))
        }
        // Loading audio belongs here rather than inside a detail branch: a
        // closure created in one branch would capture the selection that was
        // current when that branch was built, and load the previous
        // recording's audio.
        .onChange(of: store.selection) { _, newValue in loadAudio(for: newValue) }
        // The sweep finishing is exactly when new transcripts exist. `AppModel`
        // is `@Observable`, so this needs no timer and no polling.
        .onChange(of: model.transcriptionProgress) { _, progress in
            if progress == nil { Task { await reload() } }
        }
    }

    /// The activation policy the app should hold while the library window is,
    /// or is not, on screen.
    ///
    /// PURE, and the whole ruling in one line — extracted for the same reason
    /// as `TranscriptPane.followsAfterPlayheadMove`, and with the same honest
    /// limit: it pins the DECISION, and nothing enforces that the view calls
    /// it. `Info.plist` sets `LSUIElement`, which was right while Steno was
    /// menu-bar-only and is wrong now that it owns a window. With no Dock icon
    /// and no app-switcher entry, a library window sent behind another app
    /// cannot be Command-Tabbed back to at all — the only way back is the menu
    /// bar icon and "Library…" again.
    ///
    /// `.regular` only WHILE that window is open, not permanently: a menu-bar
    /// utility that keeps a Dock icon after its one window closes has quietly
    /// become the wrong kind of app. Settings and Reclaim deliberately do not
    /// count — they are short-lived forms that were fine without a Dock icon
    /// for the whole of specs 1–3, and making them count would mean the icon
    /// appears for a window nobody switches away from.
    ///
    /// Going `.regular` also gives this app a main menu bar it has never had.
    /// That is accepted rather than worked around, and it is arguably the
    /// point: a user looking at a Dock icon and a focused window expects ⌘W to
    /// close it and ⌘Q to quit, and both come from that menu. Nothing dead
    /// appears in it — there is no `WindowGroup`, so no "New Window", and no
    /// `Settings` scene, so no ⌘, that opens nothing.
    nonisolated static func activationPolicy(
        isLibraryOpen: Bool
    ) -> NSApplication.ActivationPolicy {
        isLibraryOpen ? .regular : .accessory
    }

    /// Points the player at whichever recording `signature` names.
    ///
    /// One definition for the two callers that need it -- the selection
    /// change, and the `.task` that restores playback on a reopened window.
    /// A no-op when nothing is selected or the signature is not in the loaded
    /// list, and `AudioPlayer.load` is itself a guarded no-op for a URL it
    /// already holds, so calling it redundantly cannot disturb a seek.
    private func loadAudio(for signature: String?) {
        guard let recording = store.recordings.first(where: { $0.id == signature })
        else { return }
        player.load(model.libraryRoot
            .appendingPathComponent(recording.sidecar.relativePath))
    }

    /// The `detail:` pane's content, factored out of `body` so a test can
    /// call it directly and inspect the returned view's runtime type.
    ///
    /// `.id(recording.id)` here is load-bearing, not decorative: without it,
    /// a selection change is an UPDATE to the same `TranscriptPane`
    /// identity, not a new instance — SwiftUI preserves `@State private var
    /// isFollowing` across it. A hand-scroll that detaches following on one
    /// recording would then leak into every recording selected afterwards,
    /// each opening already "paused" with no scroll position of its own.
    /// Forcing a fresh identity per recording resets both `isFollowing` and
    /// the transcript's scroll position together, which is what a different
    /// recording actually is: unrelated content, not a continuation of the
    /// last one.
    ///
    /// `query`, `moments`, `capped`, and `knownTopics` are resolved by `body`
    /// (which is where `store.query` and `store.recordings` live) and handed
    /// in here, rather than this function reaching for them itself — that
    /// keeps this a pure composition of already-known values, which is what
    /// makes it something a test can call directly. `model` is passed through
    /// unchanged so `TranscriptPane` can hand it to `RecordingEditor`, which
    /// needs it to save an edit. `onSaved` is `body`'s own `reload()`,
    /// forwarded the same way — `RecordingEditor` writes through `model` but
    /// has no way back into `store.recordings` on its own; see
    /// `RecordingEditor.onSaved`'s doc comment.
    @ViewBuilder
    static func detailContent(
        for recording: LoadedRecording?,
        player: AudioPlayer,
        query: String,
        moments: [Moment],
        capped: Bool,
        knownTopics: [String],
        model: AppModel,
        onSaved: @escaping () async -> Void,
        onPlay: @escaping (Moment) -> Void
    ) -> some View {
        // Trimmed to match `TranscriptSearch.moments`, which trims before
        // comparing against `minimumQueryLength`. Comparing the raw query
        // here would let an all-whitespace query past the minimum count
        // show the (empty) search pane instead of the transcript, even
        // though `TranscriptSearch` itself would treat it as too short to
        // search on.
        if !moments.isEmpty
            || query.trimmingCharacters(in: .whitespacesAndNewlines).count
                >= TranscriptSearch.minimumQueryLength {
            MomentsPane(moments: moments, capped: capped, onPlay: onPlay)
        } else if let recording {
            TranscriptPane(recording: recording, player: player,
                            knownTopics: knownTopics, model: model, onSaved: onSaved)
                .id(recording.id)
        } else {
            ContentUnavailableView("No recording selected", systemImage: "waveform")
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
    ///
    /// A dropped call used to be harmless for the original two callers
    /// (`.task`, and the sweep's `transcriptionProgress` going nil) — either
    /// one landing on top of an in-flight load is redundant with what that
    /// load is already about to produce. `RecordingEditor`'s `onSaved` is
    /// different: it exists to make ONE specific edit visible, and scanning
    /// every sidecar (`store.load`) is not instant, so a save landing while a
    /// sweep-driven reload is already mid-scan is a real, reachable case on a
    /// library of any size — not hypothetical. Dropping that call silently
    /// would leave the corrected title showing stale until whatever
    /// incidental trigger comes next. `reloadQueued` closes that: a call that
    /// arrives mid-load is remembered rather than lost, and runs exactly once
    /// more right after, still without a second concurrent `store.load`.
    private func reload() async {
        guard !store.isLoading else {
            reloadQueued = true
            return
        }
        await store.load(root: model.libraryRoot, sidecars: model.librarySidecars())
        if reloadQueued {
            reloadQueued = false
            await reload()
        }
    }
}
