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
        // `?? 0` rather than a second unknown-duration branch: `scrubber`,
        // `remaining`, and `total` already treat zero as "not known", so
        // resolving to one number here keeps the bar and both labels unable
        // to disagree.
        let duration = Self.transportDuration(
            observed: player.duration, sidecar: recording.sidecar.durationSeconds) ?? 0
        let scrubber = Self.scrubber(currentTime: player.currentTime, duration: duration)
        return HStack(spacing: 10) {
            Button {
                if player.isPlaying { player.pause() } else { player.play() }
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 12)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            // The getter recomputes from `player.currentTime` rather than
            // reading the `scrubber` snapshot above. `transport` is evaluated
            // once per body pass and the closure would capture that one
            // value, so a `get` landing between a `set` and the next body pass
            // returns the PRE-scrub position — the thumb snaps back to where
            // it was and then forward again, which is exactly the stutter
            // mechanism a drag would show. `upperBound` is safe to take from
            // the snapshot: `player.duration` is read in this same body pass,
            // so any change to it schedules another one.
            Slider(value: Binding(
                get: { Self.scrubber(currentTime: player.currentTime,
                                     duration: duration).position },
                set: { scrub(to: $0) }),
                   in: 0...scrubber.upperBound)
                .disabled(!scrubber.isEnabled)
                .accessibilityLabel("Playback position")

            Text(Self.elapsedLabel(currentTime: player.currentTime))
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
    /// Which duration the transport should be driven from, or nil when neither
    /// source has a usable one.
    ///
    /// PURE. `AudioPlayer.duration` starts at 0 and is only ever written from
    /// inside the periodic time observer — which does not fire again until
    /// playback begins, and at registration the item's duration is still
    /// indefinite, so the `isFinite` check there leaves it 0. Driving the
    /// transport off that alone meant selecting a recording produced a dead
    /// grey bar reading `0:00 / --:--` until you pressed play: the control the
    /// spec asked for looked broken on first contact.
    ///
    /// `Sidecar.durationSeconds` is measured at `Library.commit` time and
    /// already rendered by `LibrarySidebar.subtitle`, so the length is known
    /// long before any audio loads. It is the FALLBACK, not the answer: the
    /// observed value wins the moment it arrives, because the sidecar's is
    /// measured from the staged file at sync time while the observer's is what
    /// this `AVPlayer` will actually play. They should agree; where they do
    /// not, the thing doing the playing is right.
    nonisolated static func transportDuration(observed: Double, sidecar: Double?) -> Double? {
        if observed.isFinite, observed > 0 { return observed }
        if let sidecar, sidecar.isFinite, sidecar > 0 { return sidecar }
        return nil
    }

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

    /// The transport's left-hand label: elapsed time alone.
    ///
    /// PURE. Reuses `timestamp(_:)` rather than growing a second formatter —
    /// two would drift, and this sits directly under the per-line stamps it
    /// has to agree with.
    nonisolated static func elapsedLabel(currentTime: Double) -> String {
        timestamp(currentTime.isFinite && currentTime > 0 ? currentTime : 0)
    }

    /// The transport's right-hand label in its counting-down state.
    ///
    /// PURE. Clamped at zero: `AVPlayer` can report a `currentTime` a hair
    /// past the item's duration at the end of playback, and "-0:01 remaining"
    /// is nonsense a reader would notice.
    nonisolated static func remaining(currentTime: Double, duration: Double) -> String {
        guard duration.isFinite, duration > 0 else { return "--:--" }
        let now = currentTime.isFinite ? min(max(currentTime, 0), duration) : 0
        return "-\(timestamp(duration - now))"
    }

    /// The transport's right-hand label in its total state. Clicking the label
    /// swaps between this and `remaining`.
    ///
    /// PURE. A zero duration means "not known yet" here exactly as it does in
    /// `scrubber` and `transportDuration`, so the bar and both labels can
    /// never disagree about whether the length is known.
    nonisolated static func total(duration: Double) -> String {
        guard duration.isFinite, duration > 0 else { return "--:--" }
        return timestamp(duration)
    }

    /// Where a ±10s skip lands, clamped to the recording.
    ///
    /// PURE. Both ends matter: a negative result becomes a negative `CMTime`
    /// in `AudioPlayer.seek`, and overshooting the end leaves the scrubber
    /// outside its own range, which is not a defined `Slider` state.
    nonisolated static func skipTarget(from currentTime: Double,
                                       by delta: Double,
                                       duration: Double) -> Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        let now = currentTime.isFinite ? currentTime : 0
        return min(max(now + delta, 0), duration)
    }

    /// The speed menu's choices, slowest first.
    ///
    /// PURE. Which one is current is `AudioPlayer.rate`, not a return value
    /// here — one source of truth for the speed.
    nonisolated static func speedChoices() -> [Double] {
        [0.75, 1, 1.25, 1.5, 1.75, 2]
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
