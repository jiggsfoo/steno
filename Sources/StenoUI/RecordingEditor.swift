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
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var topic: String
    @State private var message: String?
    @State private var isSaving = false

    public init(recording: LoadedRecording, knownTopics: [String], model: AppModel) {
        self.recording = recording
        self.knownTopics = knownTopics
        self.model = model
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

            if let message {
                Text(message).font(.caption).foregroundStyle(.red)
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

        message = Self.message(for: outcome)
        if case .updated = outcome { dismiss() }
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
}
