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
    @Environment(\.dismiss) private var dismiss

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
        Form {
            TextField("Title", text: $title)
            TextField("Topic", text: $topic)
                .accessibilityLabel("Topic folder")
            Text("Leave the topic empty to unfile this recording.")
                .font(.caption).foregroundStyle(.secondary)

            if !knownTopics.isEmpty {
                Picker("Existing topics", selection: $topic) {
                    Text("—").tag("")
                    ForEach(knownTopics, id: \.self) { Text($0).tag($0) }
                }
            }

            if let lastOutcome, let message = Self.message(for: lastOutcome) {
                // Same `Color` type on both arms of the ternary -- `.secondary`
                // resolves to `HierarchicalShapeStyle`, which does not unify
                // with `Color`, so busy gets its own color rather than the
                // semantic style token.
                Text(message).font(.caption)
                    .foregroundStyle(Self.isBusyMessage(lastOutcome) ? Color.orange : Color.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving)
            }
        }
        .padding()
        .frame(width: 380)
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }

        let outcome = await model.updateRecording(
            recording.sidecar, title: title,
            topic: topic.isEmpty ? nil : topic)

        lastOutcome = outcome
        if Self.shouldNotifySaved(for: outcome) {
            // Reload before dismissing, not after: this is what closes the
            // gap between "the write landed" and "the window shows it" --
            // dismissing first would drop the sheet while the pane behind it
            // could, for a moment, still be showing the stale title.
            await onSaved()
            dismiss()
        }
    }

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
    /// `LibraryWindow` to reload, and the sheet has to stay open so the user
    /// can see the message and try again rather than being dismissed on a
    /// no-op.
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
