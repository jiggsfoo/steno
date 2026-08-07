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
                        // Resync from the live sidecar before opening the
                        // field, not just on Esc: `RecordingEditor` keeps its
                        // identity for as long as the same `recording.id`
                        // stays selected, so a sweep-driven title (or topic)
                        // rewrite that lands while this pane is open never
                        // reaches this `@State` on its own. Skipping this
                        // would let a title-only edit silently overwrite a
                        // fresher topic with whatever `topic` was last set
                        // to -- the same stale-snapshot shape as the
                        // `AppModel` Critical, one layer up.
                        title = recording.sidecar.title ?? ""
                        topic = recording.sidecar.topic ?? ""
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
                    // rather than a plain text field.
                    Menu {
                        ForEach(knownTopics, id: \.self) { choice in
                            Button(choice) { topic = choice }
                        }
                        Divider()
                        Button(Self.unfileLabel) { topic = "" }
                    } label: { EmptyView() }
                    .menuStyle(.borderlessButton)
                    .frame(width: 16)
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
                        // Same resync-before-edit reasoning as the title's
                        // `.onTapGesture` above: `@State` survives `recording`
                        // being replaced by a sweep-driven rewrite, so this
                        // control has to pull both fields fresh from the live
                        // sidecar too, or it inherits the exact bug that tap
                        // handler exists to fix.
                        title = recording.sidecar.title ?? ""
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
    /// `save()` is unchanged — it still sends both `title` and `topic` to
    /// `AppModel.updateRecording`, and `topic` still holds what the sidecar
    /// had, so a title-only edit writes the topic back unchanged.
    ///
    /// Uses `!Self.shouldNotifySaved(for:)` directly rather than a dedicated
    /// "stays editing" predicate — that would be byte-for-byte the inverse of
    /// an already-tested decision, one discriminator duplicated for no new
    /// information.
    private func commitTitle() async {
        await save()
        if let lastOutcome { editingTitle = !Self.shouldNotifySaved(for: lastOutcome) }
    }

    /// Commits the topic, and leaves edit mode only if the save landed.
    ///
    /// A refusal — `TopicName` rejects a bad folder name rather than repairing
    /// it — keeps the field open with what was typed, so the reason rendered
    /// below has something to point at. Same `!Self.shouldNotifySaved(for:)`
    /// discriminator as `commitTitle()`, for the same reason: a dedicated
    /// "stays editing" predicate would just be its inverse.
    private func commitTopic() async {
        await save()
        if let lastOutcome { editingTopic = !Self.shouldNotifySaved(for: lastOutcome) }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }

        let outcome = await model.updateRecording(
            recording.sidecar, title: title,
            topic: topic.isEmpty ? nil : topic)

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
