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
        VStack(spacing: 0) {
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
            Divider()
            transport
        }
    }

    /// The spec's "playhead along the bottom": play/pause, a draggable
    /// position bar, and an elapsed/duration readout.
    ///
    /// Outside `reader(_:)` rather than inside it, so it is there for a
    /// recording that has no transcript yet too. Before this,
    /// `AudioPlayer.pause()`, `stop()`, `isPlaying` and `duration` had no
    /// caller anywhere outside `AudioPlayer` itself: once you clicked a
    /// transcript line the only ways to stop the audio were selecting a
    /// different recording or closing the window, and an untranscribed
    /// recording could not be played at all.
    ///
    /// The `Slider`'s setter runs on every step of a drag, not only on
    /// release. That is deliberate and not chattiness: the thumb's position IS
    /// `player.currentTime`, so a setter that waited for release would leave
    /// the thumb pinned under the pointer, unmoving, for the whole gesture.
    private var transport: some View {
        let scrubber = Self.scrubber(currentTime: player.currentTime, duration: player.duration)
        return HStack(spacing: 10) {
            Button {
                if player.isPlaying { player.pause() } else { player.play() }
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 12)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            Slider(value: Binding(get: { scrubber.position }, set: { scrub(to: $0) }),
                   in: 0...scrubber.upperBound)
                .disabled(!scrubber.isEnabled)
                .accessibilityLabel("Playback position")

            Text(Self.elapsed(currentTime: player.currentTime, duration: player.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Moves the playhead, and re-attaches following.
    ///
    /// Calls `followsAfterPlayheadMove()` rather than assigning `true` inline:
    /// the ruling lives in that one function, and `line(_:index:isCurrent:)`
    /// below calls the same one. A pure function the view bypasses would be
    /// worse than no pure function at all.
    private func scrub(to seconds: Double) {
        player.seek(to: seconds)
        isFollowing = Self.followsAfterPlayheadMove()
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
            isFollowing = Self.followsAfterPlayheadMove()
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

    /// Whether following is attached after the playhead is moved deliberately
    /// — a tap on a transcript line, or a drag of the transport scrubber.
    ///
    /// PURE, and the counterpart to `remainsFollowing` above. It takes no
    /// argument because the ruling takes none: moving the playhead re-attaches
    /// following from EITHER state. That asymmetry with a hand scroll is the
    /// design, not an oversight. A hand scroll of the transcript means "let me
    /// read somewhere else while the audio keeps going", so it detaches; a
    /// scrub means "take me there", which is the same kind of navigation as
    /// clicking a line, so it re-attaches. Scrubbing is also how you get
    /// following back without hunting for the Resume banner.
    ///
    /// Extracted rather than written as a bare `isFollowing = true` at each of
    /// the two call sites so the ruling has one home and one test; both call
    /// sites call THIS.
    nonisolated static func followsAfterPlayheadMove() -> Bool { true }

    /// What the transport row's position bar shows, as a pure function of the
    /// player's state.
    ///
    /// PURE, and the testable half of the scrubber — the `Slider` itself needs
    /// a display. `upperBound` is never zero: a `Slider` maps its value across
    /// its range by dividing by the range's length, so `0...0` is a
    /// divide-by-zero and a NaN thumb position. A recording whose asset has
    /// not finished loading (`AudioPlayer.duration` starts at 0 and is only
    /// filled in by the periodic observer once the item reports a finite one)
    /// and a recording with no usable audio at all are indistinguishable from
    /// here, and both get the same answer: a control parked at zero and
    /// disabled, rather than a live one scrubbing a length nobody knows.
    ///
    /// `position` is clamped rather than trusted. `AVPlayer` can report a
    /// `currentTime` a hair past the item's duration at the end of playback,
    /// and a `Slider` value outside its own range is not a defined state.
    nonisolated static func scrubber(currentTime: Double, duration: Double) -> Scrubber {
        guard duration.isFinite, duration > 0 else {
            return Scrubber(position: 0, upperBound: 1, isEnabled: false)
        }
        guard currentTime.isFinite else {
            return Scrubber(position: 0, upperBound: duration, isEnabled: true)
        }
        return Scrubber(position: min(max(currentTime, 0), duration),
                        upperBound: duration, isEnabled: true)
    }

    struct Scrubber: Equatable, Sendable {
        let position: Double
        /// Never zero. See `scrubber(currentTime:duration:)`.
        let upperBound: Double
        /// False when there is no known duration to scrub within.
        let isEnabled: Bool
    }

    /// The transport's readout: `0:41 / 66:25`, or `0:41 / --:--` while the
    /// duration is still unknown.
    ///
    /// PURE. Reuses `timestamp(_:)` rather than growing a second formatter —
    /// two would drift, and this readout sits directly under the per-line
    /// stamps it has to agree with.
    nonisolated static func elapsed(currentTime: Double, duration: Double) -> String {
        let now = timestamp(currentTime.isFinite && currentTime > 0 ? currentTime : 0)
        guard duration.isFinite, duration > 0 else { return "\(now) / --:--" }
        return "\(now) / \(timestamp(duration))"
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
