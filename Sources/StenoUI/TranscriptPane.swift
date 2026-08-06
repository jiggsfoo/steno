import SwiftUI

/// The library window's reader: one transcript, with playback following along.
public struct TranscriptPane: View {
    let recording: LoadedRecording
    // Plain `let`, not `@Bindable`: `AudioPlayer` is `@Observable`, and this
    // pane never writes through `$player` — a plain `let` gets identical
    // observation tracking on `player.currentTime` etc. with less ceremony.
    let player: AudioPlayer
    let knownTopics: [String]
    @Bindable var model: AppModel
    /// Forwarded to `RecordingEditor` unchanged — see its own doc comment.
    let onSaved: () async -> Void

    @State private var isFollowing = true
    @State private var isEditing = false

    public init(recording: LoadedRecording, player: AudioPlayer,
                knownTopics: [String], model: AppModel,
                onSaved: @escaping () async -> Void) {
        self.recording = recording
        self.player = player
        self.knownTopics = knownTopics
        self.model = model
        self.onSaved = onSaved
    }

    public var body: some View {
        Group {
            if let transcript = recording.transcript {
                reader(transcript)
            } else {
                ContentUnavailableView(
                    "Not transcribed yet",
                    systemImage: "waveform",
                    description: Text("This recording is still in the queue."))
            }
        }
    }

    private func reader(_ transcript: Transcript) -> some View {
        let current = AudioPlayer.currentSegmentIndex(at: player.currentTime,
                                                      in: transcript.segments)
        return ScrollViewReader { proxy in
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(recording.displayTitle).font(.headline)
                        Text(recording.sidecar.topic ?? LibrarySidebar.unfiled)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Edit…") { isEditing = true }
                }
                .padding(.horizontal, 12).padding(.top, 10)
                .sheet(isPresented: $isEditing) {
                    RecordingEditor(recording: recording, knownTopics: knownTopics,
                                     model: model, onSaved: onSaved)
                }

                if !isFollowing {
                    HStack {
                        Text("Following paused").font(.caption)
                        Button("Resume") {
                            isFollowing = true
                            if let current { proxy.scrollTo(current, anchor: .center) }
                        }
                        .buttonStyle(.link)
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.quaternary)
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(transcript.segments.enumerated()), id: \.offset) { index, segment in
                            line(segment, index: index, isCurrent: index == current)
                                .id(index)
                        }
                    }
                    .padding(12)
                }
                // Any hand scroll detaches. Without this the view fights the
                // reader the moment they look back at something.
                .onScrollPhaseChange { _, phase in
                    if phase == .interacting {
                        isFollowing = Self.remainsFollowing(isFollowing: isFollowing,
                                                            userScrolled: true)
                    }
                }
                .onChange(of: current) { _, index in
                    guard isFollowing, let index else { return }
                    withAnimation { proxy.scrollTo(index, anchor: .center) }
                }
            }
        }
    }

    private func line(_ segment: Segment, index: Int, isCurrent: Bool) -> some View {
        Button {
            player.seek(to: segment.start)
            player.play()
            isFollowing = true
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Self.timestamp(segment.start))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                VStack(alignment: .leading, spacing: 1) {
                    if let speaker = Self.speakerLabel(for: segment) {
                        Text(speaker).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(segment.text).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3).padding(.horizontal, 6)
            .background(isCurrent ? Color.accentColor.opacity(0.18) : .clear,
                        in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }

    /// Whether following survives this event.
    ///
    /// PURE, and the whole detach rule in one line — extracted for the same
    /// reason as `AppModel.shouldClearTranscriptionState`: the rendering is
    /// untestable here, the decision is not.
    nonisolated static func remainsFollowing(isFollowing: Bool, userScrolled: Bool) -> Bool {
        isFollowing && !userScrolled
    }

    /// A speaker label, or nil when the recording was never diarized.
    ///
    /// `Segment.speaker` is populated only by Deepgram; `SpeechAnalyzer` leaves
    /// it nil. A recording transcribed on-device must not sprout a fake
    /// "Speaker 1" it has no evidence for.
    nonisolated static func speakerLabel(for segment: Segment) -> String? {
        segment.speaker.map { "Speaker \($0 + 1)" }
    }

    nonisolated static func timestamp(_ seconds: Double) -> String {
        String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}
