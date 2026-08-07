import SwiftUI

/// Corrects a title or topic the model got wrong.
///
/// Spec 2 assumed this existed — its design says a wrong guess is fixed by
/// "editing the topic field and regenerating" — but until now that meant
/// hand-editing JSON, which in practice meant bad titles stayed.
public struct RecordingEditor: View {
    let recording: LoadedRecording
    let knownTopics: [String]
    @Bindable var model: AppModel
    /// Tells the caller a save landed, so it can pull the corrected sidecar
    /// back into whatever list is showing it. `RecordingEditor` writes
    /// through `model.updateRecording`, but nothing reads `AppModel` back out
    /// into `LibraryStore.recordings` on its own -- see `LibraryWindow.reload()`,
    /// the closure every real caller hands in here.
    let onSaved: () async -> Void

    @State private var title: String
    @State private var topic: String
    @State private var lastOutcome: RecordingEditOutcome?
    @State private var isSaving = false

    public init(recording: LoadedRecording, knownTopics: [String], model: AppModel,
                onSaved: @escaping () async -> Void) {
        self.recording = recording
        self.knownTopics = knownTopics
        self.model = model
        self.onSaved = onSaved
        _title = State(initialValue: recording.sidecar.title ?? "")
        _topic = State(initialValue: recording.sidecar.topic ?? "")
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if editingTitle {
                TextField("Title", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .font(.headline)
                    .frame(maxWidth: 340)
                    .onSubmit { Task { await commitTitle() } }
                    .onExitCommand {
                        title = recording.sidecar.title ?? ""
                        editingTitle = false
                    }
            } else {
                Text(recording.displayTitle)
                    .font(.headline)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    // Static text that is secretly clickable is the weak point
                    // of inline editing. The hover background IS the
                    // affordance — without it the control is invisible.
                    .background(hoveringTitle ? Color.secondary.opacity(0.18) : .clear,
                                in: RoundedRectangle(cornerRadius: 5))
                    .onHover { hoveringTitle = $0 }
                    .onTapGesture {
                        // Seed from the live sidecar, not just on Esc:
                        // `RecordingEditor` keeps its identity for as long as
                        // the same `recording.id` stays selected, so a
                        // sweep-driven title (or topic) rewrite that lands
                        // while this pane is open never reaches this `@State`
                        // on its own.
                        //
                        // ONLY the field being opened. The sibling is left
                        // exactly as it is, because nothing reads it any more:
                        // a commit sends the sibling straight from
                        // `recording.sidecar` (see `titleCommit(typed:
                        // topicOnDisk:)`), and the sibling's own tap seeds it
                        // from disk the same way this line does. Resyncing it
                        // here as well was the previous shape of this fix, and
                        // it did not work -- a sweep landing BETWEEN the tap
                        // and Return still committed the tap-time value.
                        title = recording.sidecar.title ?? ""
                        editingTitle = true
                    }
            }

            if editingTopic {
                HStack(spacing: 0) {
                    TextField("Topic", text: $topic)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await commitTopic() } }
                        .onExitCommand {
                            topic = recording.sidecar.topic ?? ""
                            editingTopic = false
                        }
                    // The chevron is not optional: a dropdown that does not
                    // advertise itself will never be found, and discovering
                    // existing topics is the whole reason this is a combo box
                    // rather than a plain text field. `.borderlessButton`
                    // draws nothing but its label -- unlike the automatic
                    // pull-down style, it does not bake in a disclosure glyph
                    // of its own -- so `EmptyView()` here would be an
                    // invisible hit region with no affordance at all.
                    Menu {
                        ForEach(knownTopics, id: \.self) { choice in
                            Button(choice) { topic = choice }
                        }
                        Divider()
                        Button(Self.unfileLabel) { topic = "" }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 16)
                    .accessibilityLabel("Choose an existing topic")
                }
                .frame(maxWidth: 240)
            } else {
                Text(recording.sidecar.topic ?? LibrarySidebar.unfiled)
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(hoveringTopic ? Color.secondary.opacity(0.18) : .clear,
                                in: RoundedRectangle(cornerRadius: 5))
                    .onHover { hoveringTopic = $0 }
                    .onTapGesture {
                        // Same seed-from-disk reasoning as the title's
                        // `.onTapGesture` above, and the same restraint: this
                        // touches only the field it opens. Leaving `title`
                        // alone is also what keeps a half-typed title visible
                        // in a title field that is still open -- overwriting
                        // it here would discard keystrokes the moment the user
                        // tapped over to the topic.
                        topic = recording.sidecar.topic ?? ""
                        editingTopic = true
                    }
            }

            if let lastOutcome, let message = Self.message(for: lastOutcome) {
                // Same `Color` type on both arms: `.secondary` resolves to
                // `HierarchicalShapeStyle`, which does not unify with `Color`.
                Text(message).font(.caption)
                    .foregroundStyle(Self.isBusyMessage(lastOutcome) ? Color.orange : Color.red)
            }
        }
    }

    @State private var editingTitle = false
    @State private var hoveringTitle = false
    @State private var editingTopic = false
    @State private var hoveringTopic = false

    /// Commits the title, and leaves edit mode only if the save landed.
    ///
    /// The topic it sends comes from the sidecar as it stands RIGHT NOW, not
    /// from the `topic` `@State` — see `titleCommit(typed:topicOnDisk:)` for
    /// why that distinction is the whole fix.
    ///
    /// Uses `!Self.shouldNotifySaved(for:)` directly rather than a dedicated
    /// "stays editing" predicate — that would be byte-for-byte the inverse of
    /// an already-tested decision, one discriminator duplicated for no new
    /// information.
    private func commitTitle() async {
        await save(Self.titleCommit(typed: title, topicOnDisk: recording.sidecar.topic))
        if let lastOutcome { editingTitle = !Self.shouldNotifySaved(for: lastOutcome) }
    }

    /// Commits the topic, and leaves edit mode only if the save landed.
    ///
    /// A refusal — `TopicName` rejects a bad folder name rather than repairing
    /// it — keeps the field open with what was typed, so the reason rendered
    /// below has something to point at. Same `!Self.shouldNotifySaved(for:)`
    /// discriminator as `commitTitle()`, for the same reason: a dedicated
    /// "stays editing" predicate would just be its inverse.
    ///
    /// Same sibling rule as `commitTitle()`, pointed the other way: the title
    /// it sends is the sidecar's, not the `title` `@State`.
    private func commitTopic() async {
        await save(Self.topicCommit(typed: topic, titleOnDisk: recording.sidecar.title))
        if let lastOutcome { editingTopic = !Self.shouldNotifySaved(for: lastOutcome) }
    }

    private func save(_ edit: Edit) async {
        isSaving = true
        defer { isSaving = false }

        let outcome = await model.updateRecording(
            recording.sidecar, title: edit.title, topic: edit.topic)

        lastOutcome = outcome
        if Self.shouldNotifySaved(for: outcome) {
            // This closes the gap between "the write landed" and "the pane
            // behind the field shows it" only when the reload can actually
            // start. `LibraryWindow.reload()` (the closure every real caller
            // hands in here) begins a load when none is in flight, and
            // awaiting THAT does close the gap: the pane is already correct
            // by the time this call returns.
            //
            // When a load IS in flight -- a sweep-driven reload mid-scan,
            // which is the exact case `reloadQueued` was added for -- that
            // call records the request and returns at once, so this `await`
            // completes while the in-flight load still has work to do and
            // the pane briefly shows stale content. Measured with a
            // standalone probe: the save-driven `reload()` returned after 0ms
            // against an in-flight load that still needed ~50ms.
            //
            // Left that way rather than made to await the queued drain. The
            // effect is benign -- the queued reload lands a moment later and
            // the pane corrects itself -- and the alternative is a
            // per-waiter continuation threaded through the one function
            // whose MainActor serial-executor argument this window's whole
            // no-overlapping-loads guarantee rests on. Not worth risking
            // that reasoning to shave an invisible ~50ms.
            await onSaved()
        }
    }

    /// The exact pair a commit hands to `AppModel.updateRecording`.
    ///
    /// Both fields go over on every write — `updateRecording` takes a whole
    /// edit, not a patch — so "which value does the field I did NOT touch
    /// send" is a real decision with a real answer, and this is the type that
    /// carries it.
    struct Edit: Equatable, Sendable {
        let title: String
        /// nil unfiles. `updateRecording` clears the topic rather than filing
        /// under a topic literally named "".
        let topic: String?
    }

    /// What committing the TITLE writes.
    ///
    /// PURE, and the Critical fix in one line: the topic comes from the
    /// sidecar as it stands at COMMIT time, never from the `topic` `@State`.
    ///
    /// That `@State` cannot be trusted, and resyncing it when the title field
    /// was opened was not enough. `RecordingEditor` keeps its identity while
    /// the same `recording.id` stays selected, so `init` does not re-run when
    /// `LibraryWindow.reload()` hands it a fresher `recording`. Everything the
    /// user does in between takes real time: tap the auto-generated title of a
    /// just-synced recording, spend fifteen seconds typing a real one, and the
    /// transcription sweep can land in that gap — `TranscriptionQueue` writes
    /// `topic` into the sidecar and `Filer.write` creates the note in that
    /// topic's folder. Return then sent the tap-time topic (nil, because the
    /// recording was unfiled when the field opened), `writeEdit` cleared the
    /// topic, and `updateRecording` removed the note without rewriting it. The
    /// AI-assigned topic reverted to Unfiled and the note was orphaned. The
    /// disk re-read inside `updateRecording` does not protect against this:
    /// the caller's argument is what wins.
    ///
    /// Sourcing the sibling here makes the stale value not an input at all,
    /// which is the only version of this fix that a later gap between tap and
    /// commit cannot reopen.
    nonisolated static func titleCommit(typed: String, topicOnDisk: String?) -> Edit {
        Edit(title: typed, topic: topicOnDisk)
    }

    /// What committing the TOPIC writes.
    ///
    /// PURE, the mirror of `titleCommit(typed:topicOnDisk:)`, and the fix for
    /// the review's second Important: a draft abandoned in the title field is
    /// not evidence of anything. Typing "Weekl" into the title, tapping over
    /// to the topic without pressing Return, and committing the topic used to
    /// write "Weekl" as well — and then Esc on the still-open title field
    /// restored `recording.sidecar.title`, which by then WAS "Weekl", so the
    /// undo was gone too. Taking the title from disk leaves the real title on
    /// disk, which is what makes Esc mean something again.
    nonisolated static func topicCommit(typed: String, titleOnDisk: String?) -> Edit {
        Edit(title: titleOnDisk ?? "", topic: typed.isEmpty ? nil : typed)
    }

    /// The combo box's escape hatch. Selecting it sets the topic to empty,
    /// which `updateRecording` turns into nil — it does not set a topic named
    /// "None".
    nonisolated static let unfileLabel = "None — unfile this"

    /// Every topic already in use, alphabetically.
    ///
    /// PURE. Unfiled recordings contribute nothing — "Unfiled" is a display
    /// name for the absence of a topic, not a topic anyone can pick.
    nonisolated static func topicChoices(from recordings: [LoadedRecording]) -> [String] {
        Set(recordings.compactMap(\.sidecar.topic))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// What to tell the user, or nil when there is nothing to say.
    ///
    /// PURE. A refused folder name has to explain itself or the field simply
    /// appears not to work, and "busy" is not a failure — something else is
    /// legitimately writing this recording for a moment.
    nonisolated static func message(for outcome: RecordingEditOutcome) -> String? {
        switch outcome {
        case .updated:
            return nil
        case .busy:
            return "This recording is being transcribed right now. Try again in a moment."
        case .rejectedTopic(let name):
            return "\"\(name)\" can't be a folder name. Avoid slashes, colons and leading dots."
        case .failed(let reason):
            return reason
        }
    }

    /// Whether a save outcome is worth telling the caller about.
    ///
    /// PURE, same rationale as `message(for:)` above. Only `.updated`
    /// actually changed the sidecar on disk — `.busy`, `.rejectedTopic`, and
    /// `.failed` all leave it exactly as it was, so there is nothing for
    /// `LibraryWindow` to reload, and the field has to stay open so the user
    /// can see the message and try again rather than closing on a no-op.
    nonisolated static func shouldNotifySaved(for outcome: RecordingEditOutcome) -> Bool {
        if case .updated = outcome { return true }
        return false
    }

    /// Whether a message is advisory rather than an error.
    ///
    /// PURE, same rationale as `message(for:)` above. `.busy` reads as
    /// "something else is legitimately writing this recording, try again" —
    /// rendering it in the same red as a refused topic or a write failure
    /// would say the opposite of what the copy itself says.
    nonisolated static func isBusyMessage(_ outcome: RecordingEditOutcome) -> Bool {
        if case .busy = outcome { return true }
        return false
    }
}
