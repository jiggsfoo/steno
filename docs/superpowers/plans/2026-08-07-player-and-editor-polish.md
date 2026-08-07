# Player Transport and Inline Editing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the library window a real transport — speed, ±10s, remaining/total on a full-width scrubber — and replace the editor sheet with inline editing in the transcript header.

**Architecture:** Three existing files change. `AudioPlayer` gains a chosen-`rate` property and owns the play/pause reconciliation `AVPlayer.rate` forces. `TranscriptPane` grows a two-row transport and hosts the header editor. `RecordingEditor` becomes that inline editor instead of a sheet's content, keeping its save path untouched. Every decision worth testing is extracted as a `nonisolated static` pure function, matching the existing precedent in both files.

**Tech Stack:** Swift 6 strict concurrency, SwiftUI, AVFoundation, Observation, Swift Testing. No third-party dependencies.

## Global Constraints

- Swift 6 strict concurrency. **Zero warnings in debug AND release**, verified from a fresh `--scratch-path` — the in-repo `.build` is warm and reports success with zero compilation, hiding every warning.
- **No `nonisolated(unsafe)`.** The codebase has none. Plain `nonisolated` is a different thing and is what the pure statics require.
- **Swift Testing only, never XCTest. No third-party dependencies.**
- **No test may** write to `~/Recordings/Steno/`, `~/Library/Logs/Steno/`, or `~/Library/Application Support/Steno/`; read or write the real `deepgram-api-key` Keychain item; or require a P1 device, network, Apple Intelligence, or a downloaded model.
- **No test may write to `UserDefaults.standard`.** Task 1 adds an injectable defaults seam for exactly this reason.
- **`Sources/JensenKit/` must not be modified.** Never send a Bluetooth command to any device.
- **`AppModel.updateRecording`, `sidecarsInFlight`, `AppModel.writeEdit`, `Library`, `Filer`, `LibraryStore`, `LibraryIndex`, `TranscriptionQueue`, `SyncEngine`, `DeviceMonitor`, `LibrarySidebar`, `MomentsPane` and `TranscriptSearch` must not be modified.** The edit write path was fixed under review for a data-integrity Critical; this plan changes what you click, not what happens when you commit.
- **Do not launch or install the app.** The user's production Steno runs against a real library with 11 real recordings.
- **Two existing guards must keep discriminating.** After any change to `TranscriptPane`'s body or `LibraryWindow.detailContent`, re-run the mutation check for `theTransportRowIsMountedBelowARuleAtTheBottomOfThePane` and `selectingARecordingGivesTheDetailPaneAFreshIdentity`: the build must still succeed under the mutation and the test must fail.
- **Layout assertions use `LibraryLayoutTests.hostedInkBands`, never `inkBands`** — `ImageRenderer` draws nothing inside a `ScrollView`. `hostedInkBands` carries a documented one-sided ~0.5pt bias and is not a drop-in replacement.
- Baseline: **339 tests pass** at `main` (`df51780`).

---

### Task 1: `AudioPlayer.rate` — the speed, and who owns it

**Files:**
- Modify: `Sources/StenoUI/AudioPlayer.swift`
- Test: `Tests/StenoUITests/AudioPlayerTests.swift`

**Interfaces:**
- Consumes: nothing from this plan.
- Produces:
  - `AudioPlayer.init(defaults: UserDefaults = .standard)`
  - `public private(set) var rate: Double` — the *chosen* speed, never 0
  - `public func setRate(_ newRate: Double)`
  - `AudioPlayer.clampedRate(_:) -> Double` (nonisolated static, pure)
  - `AudioPlayer.appliedRate(chosen:isPlaying:) -> Float` (nonisolated static, pure)

- [ ] **Step 1: Write the failing tests**

Append to `Tests/StenoUITests/AudioPlayerTests.swift`:

```swift
/// `AVPlayer.rate` is the speed while playing and 0 while paused — one
/// property with two meanings. `AudioPlayer.rate` is the CHOSEN speed and
/// must survive a pause, or resuming would silently drop back to 1x.
@MainActor
@Test func pausingDoesNotForgetTheChosenSpeed() {
    let player = AudioPlayer(defaults: throwawayDefaults())
    player.setRate(1.5)
    player.pause()

    #expect(player.rate == 1.5)
}

@MainActor
@Test func theChosenSpeedIsWhatGetsAppliedOnPlay() {
    #expect(AudioPlayer.appliedRate(chosen: 1.5, isPlaying: true) == 1.5)
    #expect(AudioPlayer.appliedRate(chosen: 1.5, isPlaying: false) == 0)
}

/// A zero or negative rate is a stopped player, not a speed. Accepting one
/// would make `setRate(0)` indistinguishable from pausing, and the transport
/// would have no way back.
@Test func aRateThatIsNotASpeedIsRefused() {
    #expect(AudioPlayer.clampedRate(0) == 1)
    #expect(AudioPlayer.clampedRate(-2) == 1)
    #expect(AudioPlayer.clampedRate(.nan) == 1)
    #expect(AudioPlayer.clampedRate(.infinity) == 1)
}

@Test func aRealSpeedSurvivesClamping() {
    #expect(AudioPlayer.clampedRate(0.75) == 0.75)
    #expect(AudioPlayer.clampedRate(2) == 2)
}

/// The preference is about how Angelo listens, not about one file, so it
/// outlives the process.
@MainActor
@Test func theChosenSpeedIsRestoredFromDefaults() {
    let defaults = throwawayDefaults()
    AudioPlayer(defaults: defaults).setRate(1.75)

    #expect(AudioPlayer(defaults: defaults).rate == 1.75)
}

@MainActor
@Test func aFreshInstallStartsAtNormalSpeed() {
    #expect(AudioPlayer(defaults: throwawayDefaults()).rate == 1)
}
```

Add this helper once, at the top of the file below the imports:

```swift
/// A `UserDefaults` suite nobody else owns.
///
/// Tests MUST NOT touch `UserDefaults.standard` — it is the user's real
/// preference domain, and `AudioPlayer` persists the playback rate there.
private func throwawayDefaults() -> UserDefaults {
    UserDefaults(suiteName: "steno.tests.\(UUID().uuidString)")!
}
```

- [ ] **Step 2: Run and watch them fail**

Run: `swift test --filter AudioPlayer`
Expected: FAIL to compile — no `rate`, no `setRate`, no `init(defaults:)`.

- [ ] **Step 3: Add the stored state and the injectable seam**

In `AudioPlayer.swift`, replace `public init() {}` with:

```swift
    /// The playback speed the user chose, never zero.
    ///
    /// Distinct from `AVPlayer.rate`, which is this value while playing and 0
    /// while paused — one property carrying two meanings. Keeping the choice
    /// here is what lets `pause()` stop playback without forgetting the
    /// speed, and `play()` resume at it rather than at 1x.
    public private(set) var rate: Double

    @ObservationIgnored private let defaults: UserDefaults
    private static let rateKey = "playbackRate"

    /// - Parameter defaults: injectable so tests never write the user's real
    ///   preference domain. `AppModel` has no equivalent seam, which is why
    ///   no test can drive its write paths; this one is cheap, so it exists.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.double(forKey: Self.rateKey)
        // `double(forKey:)` returns 0 for a missing key, which `clampedRate`
        // already maps to 1 — so a fresh install and a corrupt value take the
        // same safe path without a separate existence check.
        self.rate = Self.clampedRate(stored)
    }

    /// Sets the speed, applies it if playback is under way, and remembers it.
    public func setRate(_ newRate: Double) {
        rate = Self.clampedRate(newRate)
        defaults.set(rate, forKey: Self.rateKey)
        if isPlaying { player?.rate = Float(rate) }
    }

    /// A speed, or 1 for anything that is not one.
    ///
    /// PURE. Zero and negatives are stopped/reversed players rather than
    /// speeds, and a NaN reaching `AVPlayer.rate` is undefined.
    nonisolated static func clampedRate(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 1 }
        return value
    }

    /// What `AVPlayer.rate` should be, given the chosen speed and whether
    /// playback is under way.
    ///
    /// PURE, and the whole two-meanings reconciliation in one line.
    nonisolated static func appliedRate(chosen: Double, isPlaying: Bool) -> Float {
        isPlaying ? Float(clampedRate(chosen)) : 0
    }
```

- [ ] **Step 4: Make `play()` honour the chosen speed**

`AVPlayer.play()` sets rate to exactly 1.0, which would discard the choice. Replace the body of `play()`:

```swift
    public func play() {
        guard let player else { return }
        player.rate = Self.appliedRate(chosen: rate, isPlaying: true)
        isPlaying = true
    }
```

Leave `pause()` exactly as it is. `player?.pause()` sets `AVPlayer.rate` to 0, which is correct, and it must not touch `self.rate`.

- [ ] **Step 5: Run the tests**

Run: `swift build 2>&1 | grep -i warning; swift test --filter AudioPlayer`
Expected: zero warnings, all pass.

- [ ] **Step 6: MUTATION-CHECK the reconciliation**

Change `appliedRate` to `Float(clampedRate(chosen))`, dropping the `isPlaying` branch. Run `swift test --filter theChosenSpeedIsWhatGetsAppliedOnPlay`. The build must succeed and the test must FAIL. Restore. Confirm PASS.

Then change `setRate`'s first line to `rate = newRate`, dropping the clamp. Run `swift test --filter aRateThatIsNotASpeedIsRefused`. Build must succeed, test must FAIL. Restore.

- [ ] **Step 7: Commit**

```bash
git add Sources/StenoUI/AudioPlayer.swift Tests/StenoUITests/AudioPlayerTests.swift
git commit -m "feat(player): the chosen speed, and who owns it

AVPlayer.rate is the speed while playing and 0 while paused. Keeping the
choice on AudioPlayer is what lets pause stop playback without forgetting
it. Defaults are injectable so tests never write the real domain."
```

---

### Task 2: The transport's pure functions

**Files:**
- Modify: `Sources/StenoUI/TranscriptPane.swift`
- Test: `Tests/StenoUITests/TranscriptPaneTests.swift`

**Interfaces:**
- Consumes: `TranscriptPane.timestamp(_:)` (existing, `nonisolated static`).
- Produces:
  - `TranscriptPane.elapsedLabel(currentTime:) -> String`
  - `TranscriptPane.remaining(currentTime:duration:) -> String`
  - `TranscriptPane.total(duration:) -> String`
  - `TranscriptPane.skipTarget(from:by:duration:) -> Double`
  - `TranscriptPane.speedChoices() -> [Double]`
  - All five `nonisolated static`.

**`elapsed(currentTime:duration:)` is DELETED in this task**, along with its tests. It returns the combined `0:41 / 66:25`, and layout B splits that across two labels at opposite ends of the scrubber. Nothing will call it. This is a deliberate deletion, not a regression — expect the test count to drop before the new tests raise it.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/StenoUITests/TranscriptPaneTests.swift`:

```swift
@Test func theElapsedLabelIsJustTheElapsedTime() {
    #expect(TranscriptPane.elapsedLabel(currentTime: 41) == "0:41")
    #expect(TranscriptPane.elapsedLabel(currentTime: 3985) == "66:25")
}

/// A player that has not loaded reports 0, and one at the very end can report
/// a hair past. Neither should render as a negative or a NaN.
@Test func theElapsedLabelSurvivesNonsense() {
    #expect(TranscriptPane.elapsedLabel(currentTime: -5) == "0:00")
    #expect(TranscriptPane.elapsedLabel(currentTime: .nan) == "0:00")
    #expect(TranscriptPane.elapsedLabel(currentTime: .infinity) == "0:00")
}

@Test func remainingCountsDownWithALeadingMinus() {
    #expect(TranscriptPane.remaining(currentTime: 41, duration: 3985) == "-65:44")
}

@Test func remainingIsZeroAtTheEndRatherThanNegative() {
    #expect(TranscriptPane.remaining(currentTime: 3985, duration: 3985) == "-0:00")
    #expect(TranscriptPane.remaining(currentTime: 4000, duration: 3985) == "-0:00")
}

/// Zero duration means "not known yet", exactly as it does in `scrubber` and
/// `transportDuration` — the bar and both labels resolve from one number.
@Test func remainingSaysSoWhenTheLengthIsUnknown() {
    #expect(TranscriptPane.remaining(currentTime: 41, duration: 0) == "--:--")
}

@Test func totalIsTheWholeLength() {
    #expect(TranscriptPane.total(duration: 3985) == "66:25")
    #expect(TranscriptPane.total(duration: 0) == "--:--")
}

/// Skipping back near the start must land at 0, not at a negative time that
/// `AudioPlayer.seek` would hand to `AVPlayer` as a `CMTime`.
@Test func skippingBackNearTheStartLandsAtZero() {
    #expect(TranscriptPane.skipTarget(from: 3, by: -10, duration: 3985) == 0)
    #expect(TranscriptPane.skipTarget(from: 0, by: -10, duration: 3985) == 0)
}

@Test func skippingForwardNearTheEndLandsAtTheEnd() {
    #expect(TranscriptPane.skipTarget(from: 3980, by: 10, duration: 3985) == 3985)
}

@Test func skippingInTheMiddleMovesByExactlyTheIncrement() {
    #expect(TranscriptPane.skipTarget(from: 100, by: -10, duration: 3985) == 90)
    #expect(TranscriptPane.skipTarget(from: 100, by: 10, duration: 3985) == 110)
}

/// With no known duration there is nothing to skip within.
@Test func skippingWithNoKnownDurationStaysPut() {
    #expect(TranscriptPane.skipTarget(from: 0, by: 10, duration: 0) == 0)
}

@Test func theSpeedChoicesRunSlowestFirstAndIncludeNormal() {
    let choices = TranscriptPane.speedChoices()

    #expect(choices == [0.75, 1, 1.25, 1.5, 1.75, 2])
    #expect(choices == choices.sorted())
}
```

- [ ] **Step 2: Run and watch them fail**

Run: `swift test --filter TranscriptPane`
Expected: FAIL to compile — none of the five functions exist.

- [ ] **Step 3: Delete `elapsed` and its tests**

Remove `elapsed(currentTime:duration:)` from `Sources/StenoUI/TranscriptPane.swift` entirely, including its doc comment. Remove every test that calls it from `Tests/StenoUITests/TranscriptPaneTests.swift`.

Run `grep -rn 'elapsed(' Sources/ Tests/` and confirm the only remaining hits are `elapsedLabel`. `transport` still references it at this point and will not compile — that is expected and Step 4 fixes it.

- [ ] **Step 4: Add the five functions**

In `TranscriptPane.swift`, beside the other `nonisolated static` functions:

```swift
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
```

- [ ] **Step 5: Point `transport` at the new labels**

`transport` currently ends with a single `Text(Self.elapsed(...))`. Replace that one line with the left label only, so the file compiles; Task 3 rebuilds the row properly.

```swift
            Text(Self.elapsedLabel(currentTime: player.currentTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
```

- [ ] **Step 6: Run the tests**

Run: `swift build 2>&1 | grep -i warning; swift build -c release 2>&1 | grep -i warning; swift test`
Expected: zero warnings in both, everything passes.

- [ ] **Step 7: MUTATION-CHECK both clamps**

Change `skipTarget`'s return to `now + delta`, dropping the clamp. Run `swift test --filter skippingBackNearTheStartLandsAtZero`. Build must succeed, test must FAIL. Restore.

Change `remaining`'s `min(max(currentTime, 0), duration)` to `currentTime`. Run `swift test --filter remainingIsZeroAtTheEndRatherThanNegative`. Build must succeed, test must FAIL. Restore.

- [ ] **Step 8: Commit**

```bash
git add Sources/StenoUI/TranscriptPane.swift Tests/StenoUITests/TranscriptPaneTests.swift
git commit -m "feat(player): the transport's pure functions

Splits the combined readout in two — layout B puts elapsed and remaining at
opposite ends of a full-width scrubber, so the old elapsed() is deleted
rather than deprecated. Both skip and remaining clamp at both ends."
```

---

### Task 3: The two-row transport

**Files:**
- Modify: `Sources/StenoUI/TranscriptPane.swift`
- Test: `Tests/StenoUITests/LibraryLayoutTests.swift`

**Interfaces:**
- Consumes: `AudioPlayer.rate`, `setRate(_:)`, `play()`, `pause()`, `seek(to:)`, `isPlaying`, `currentTime`, `duration` (Task 1); `elapsedLabel`, `remaining`, `total`, `skipTarget`, `speedChoices` (Task 2); `scrubber`, `transportDuration`, `followsAfterPlayheadMove` (existing).
- Produces: a `transport` with the layout below, and `@State private var showingRemaining = true` on `TranscriptPane`.

- [ ] **Step 1: Replace `transport` entirely**

```swift
    private var transport: some View {
        // `?? 0` rather than a second unknown-duration branch: `scrubber`,
        // `remaining` and `total` all treat zero as "not known", so resolving
        // to one number here keeps the bar and both labels unable to disagree.
        let duration = Self.transportDuration(
            observed: player.duration, sidecar: recording.sidecar.durationSeconds) ?? 0
        let scrubber = Self.scrubber(currentTime: player.currentTime, duration: duration)
        return VStack(spacing: 4) {
            // The getter recomputes from `player.currentTime` rather than
            // reading the `scrubber` snapshot above. `transport` is evaluated
            // once per body pass and the closure would capture that one value,
            // so a `get` landing between a `set` and the next body pass
            // returns the PRE-scrub position — the thumb snaps back and then
            // forward, which is the stutter a drag would show.
            Slider(value: Binding(
                get: { Self.scrubber(currentTime: player.currentTime,
                                     duration: duration).position },
                set: { scrub(to: $0) }),
                   in: 0...scrubber.upperBound)
                .disabled(!scrubber.isEnabled)
                .accessibilityLabel("Playback position")

            HStack {
                Text(Self.elapsedLabel(currentTime: player.currentTime))
                    .accessibilityLabel("Elapsed")
                Spacer()
                Button {
                    showingRemaining.toggle()
                } label: {
                    Text(showingRemaining
                         ? Self.remaining(currentTime: player.currentTime, duration: duration)
                         : Self.total(duration: duration))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showingRemaining ? "Time remaining" : "Total time")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            HStack(spacing: 18) {
                Spacer()
                Button { skip(by: -10) } label: {
                    Image(systemName: "gobackward.10")
                }
                .buttonStyle(.plain)
                .disabled(!scrubber.isEnabled)
                .accessibilityLabel("Back 10 seconds")

                Button {
                    if player.isPlaying { player.pause() } else { player.play() }
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 16)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

                Button { skip(by: 10) } label: {
                    Image(systemName: "goforward.10")
                }
                .buttonStyle(.plain)
                .disabled(!scrubber.isEnabled)
                .accessibilityLabel("Forward 10 seconds")
                Spacer()
            }
            .overlay(alignment: .trailing) {
                Menu {
                    ForEach(Self.speedChoices(), id: \.self) { choice in
                        Button {
                            player.setRate(choice)
                        } label: {
                            // A checkmark rather than a separate "current"
                            // return value from `speedChoices` — the player
                            // stays the one source of truth for the speed.
                            if player.rate == choice { Image(systemName: "checkmark") }
                            Text(Self.speedLabel(choice))
                        }
                    }
                } label: {
                    Text(Self.speedLabel(player.rate))
                        .font(.caption.monospacedDigit())
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Playback speed")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Moves the playhead by `delta` seconds and re-attaches following.
    ///
    /// A skip MOVES the playhead, so it re-attaches for the same reason a
    /// scrub and a line tap do — see `followsAfterPlayheadMove`.
    private func skip(by delta: Double) {
        let duration = Self.transportDuration(
            observed: player.duration, sidecar: recording.sidecar.durationSeconds) ?? 0
        player.seek(to: Self.skipTarget(from: player.currentTime,
                                        by: delta, duration: duration))
        isFollowing = Self.followsAfterPlayheadMove()
    }
```

Add the state and the label formatter:

```swift
    /// Whether the right-hand label counts down or shows the whole length.
    ///
    /// Not persisted: it is a glance, not a preference, and it resets with the
    /// rest of the pane's state when `.id(recording.id)` changes.
    @State private var showingRemaining = true
```

```swift
    /// `1x`, `1.5x` — trailing zeros dropped so the menu reads as speeds
    /// rather than as measurements.
    nonisolated static func speedLabel(_ rate: Double) -> String {
        rate == rate.rounded()
            ? "\(Int(rate))x"
            : String(format: "%gx", rate)
    }
```

- [ ] **Step 2: Add the speed-label test**

Append to `Tests/StenoUITests/TranscriptPaneTests.swift`:

```swift
@Test func speedLabelsReadAsSpeedsNotMeasurements() {
    #expect(TranscriptPane.speedLabel(1) == "1x")
    #expect(TranscriptPane.speedLabel(2) == "2x")
    #expect(TranscriptPane.speedLabel(0.75) == "0.75x")
    #expect(TranscriptPane.speedLabel(1.5) == "1.5x")
}
```

- [ ] **Step 3: Update the transport-mount layout test**

`theTransportRowIsMountedBelowARuleAtTheBottomOfThePane` asserts the transport draws as a band below a rule. The row is now three stacked rows rather than one, so its band is taller. Open `Tests/StenoUITests/LibraryLayoutTests.swift`, read what the existing assertion measures, and widen only what the extra height requires — do not weaken what it asserts. If it still passes unchanged, leave it alone and say so.

- [ ] **Step 4: Run everything**

Run: `swift build 2>&1 | grep -i warning; swift build -c release 2>&1 | grep -i warning; swift test`
Expected: zero warnings in both, everything passes.

- [ ] **Step 5: MUTATION-CHECK the mount guard and the skip rule**

Delete `Divider()` and `transport` from `TranscriptPane.body`. Run `swift test --filter theTransportRowIsMountedBelowARuleAtTheBottomOfThePane`. Build must succeed, test must FAIL. Restore.

Then change `skip(by:)`'s last line to `isFollowing = false`. Run the full suite. **If nothing fails, that is a finding, not a pass** — report it rather than moving on: the skip-re-attaches ruling has no regression guard, and the only honest options are a test that discriminates or a recorded gap.

- [ ] **Step 6: Commit**

```bash
git add Sources/StenoUI/TranscriptPane.swift Tests/StenoUITests/TranscriptPaneTests.swift \
        Tests/StenoUITests/LibraryLayoutTests.swift
git commit -m "feat(player): the two-row transport

Full-width scrubber with elapsed and remaining under its ends, controls
centred below, speed pinned right. At 66 minutes seek precision is what
matters, and a one-row layout gives the bar a fifth of the pixels."
```

---

### Task 4: The title, edited in place

**Files:**
- Modify: `Sources/StenoUI/RecordingEditor.swift`, `Sources/StenoUI/TranscriptPane.swift`
- Test: `Tests/StenoUITests/RecordingEditorTests.swift`

**Interfaces:**
- Consumes: `AppModel.updateRecording(_:title:topic:)`, `RecordingEditOutcome`, `RecordingEditor.save()`, `message(for:)`, `shouldNotifySaved(for:)`, `isBusyMessage(_:)` (all existing, unmodified).
- Produces:
  - `RecordingEditor.staysEditing(after:) -> Bool` (nonisolated static, pure)
  - `RecordingEditor` presented inline rather than via `.sheet`.

**Do not modify `AppModel`.** `updateRecording` re-reads the sidecar from disk inside the `sidecarsInFlight` guard; that was added for a data-integrity Critical and this task must not touch it.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/StenoUITests/RecordingEditorTests.swift`:

```swift
/// The sheet could close on any outcome and show its message on the way out.
/// Inline editing cannot: a refusal has nowhere to go once the field is gone,
/// so a refused edit must KEEP the field open with what was typed intact.
@Test func aRefusedTopicKeepsTheFieldOpen() {
    #expect(RecordingEditor.staysEditing(after: .rejectedTopic("../etc")))
}

@Test func aBusyRecordingKeepsTheFieldOpen() {
    #expect(RecordingEditor.staysEditing(after: .busy))
}

@Test func aFailedSaveKeepsTheFieldOpen() {
    #expect(RecordingEditor.staysEditing(after: .failed("disk full")))
}

@Test func aSuccessfulSaveLeavesEditMode() {
    let sidecar = withTopic("Admin", "a").sidecar

    #expect(!RecordingEditor.staysEditing(after: .updated(sidecar)))
}
```

- [ ] **Step 2: Run and watch them fail**

Run: `swift test --filter RecordingEditor`
Expected: FAIL to compile — no `staysEditing`.

- [ ] **Step 3: Add the decision**

In `RecordingEditor.swift`, beside `shouldNotifySaved` and `isBusyMessage`:

```swift
    /// Whether the field stays in edit mode after this outcome.
    ///
    /// PURE, and the exact inverse of `shouldNotifySaved` today — but they
    /// answer different questions and will not stay inverses if a future
    /// outcome saves without dismissing, so they are separate. A sheet could
    /// close on anything and show its message on the way out; an inline field
    /// that closes on a refusal loses both the message and what was typed.
    nonisolated static func staysEditing(after outcome: RecordingEditOutcome) -> Bool {
        if case .updated = outcome { return false }
        return true
    }
```

- [ ] **Step 4: Turn `RecordingEditor` into the header editor**

All editing state stays inside `RecordingEditor` — `title`, `topic`, `lastOutcome` and `isSaving` are already its `@State` and must not migrate into `TranscriptPane`. What changes is that its `body` becomes the header layout instead of a `Form`, and `TranscriptPane` renders it inline instead of presenting it.

Replace `RecordingEditor`'s `body` with:

```swift
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
                    .onTapGesture { editingTitle = true }
            }

            // Static for now; Task 5 makes this the combo box.
            Text(recording.sidecar.topic ?? LibrarySidebar.unfiled)
                .font(.caption).foregroundStyle(.secondary)

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

    /// Commits the title, and leaves edit mode only if the save landed.
    ///
    /// `save()` is unchanged — it still sends both `title` and `topic` to
    /// `AppModel.updateRecording`, and `topic` still holds what the sidecar
    /// had, so a title-only edit writes the topic back unchanged.
    private func commitTitle() async {
        await save()
        if let lastOutcome { editingTitle = Self.staysEditing(after: lastOutcome) }
    }
```

Delete the `Cancel`/`Save` `HStack`, `.padding()` and `.frame(width: 380)` from the old `Form` body — the footer buttons go with the sheet.

- [ ] **Step 5: Cut `dismiss` out of `save()` — this one bites**

`save()` currently ends with `dismiss()` (`RecordingEditor.swift:105`), and `@Environment(\.dismiss)` at `:18` resolves against whatever presented the view. Inside a sheet that closed the sheet. Inside a `Window` scene it **closes the window** — so saving a title would make the whole library disappear.

Three edits, all required:

1. Delete `dismiss()` from `save()`, keeping `await onSaved()`.
2. Delete `@Environment(\.dismiss) private var dismiss` (its only other user, the `Cancel` button, went with the `Form`).
3. Rewrite the long comment above `await onSaved()`. Its reasoning about `reloadQueued` is still correct and worth keeping — a save-driven `reload()` returns immediately when a load is in flight, measured at 0ms against an in-flight load needing ~50ms, and the queued reload lands a moment later. What is no longer true is the framing: there is no dismissal to race any more. It now describes the gap between the write landing and the pane behind the field showing it.

Then confirm:

```bash
grep -n 'dismiss' Sources/StenoUI/RecordingEditor.swift
```

Expected: no hits outside comments.

- [ ] **Step 6: Render it inline and delete the sheet**

In `TranscriptPane.swift`'s header, replace the `VStack` holding the title and topic `Text`s, the `Edit…` `Button`, and `.sheet(isPresented: $isEditing)` with a single call:

```swift
                    RecordingEditor(recording: recording, knownTopics: knownTopics,
                                    model: model, onSaved: onSaved)
```

Delete `@State private var isEditing`. Then run:

```bash
grep -n 'isEditing\|Edit…\|\.sheet' Sources/StenoUI/TranscriptPane.swift
```

and confirm nothing remains.

- [ ] **Step 7: Run everything**

Run: `swift build 2>&1 | grep -i warning; swift build -c release 2>&1 | grep -i warning; swift test`
Expected: zero warnings in both, everything passes.

- [ ] **Step 8: MUTATION-CHECK the refusal rule**

Change `staysEditing` to `if case .rejectedTopic = outcome { return true }; return false`. Run `swift test --filter aBusyRecordingKeepsTheFieldOpen`. Build must succeed, test must FAIL. Restore.

- [ ] **Step 9: Re-run the identity guard's mutation check**

`TranscriptPane`'s body changed. Delete `.id(recording.id)` from `LibraryWindow.detailContent`. Run `swift test --filter selectingARecordingGivesTheDetailPaneAFreshIdentity`. Build must succeed, test must FAIL. Restore. Report the message verbatim.

- [ ] **Step 10: Commit**

```bash
git add Sources/StenoUI/RecordingEditor.swift Sources/StenoUI/TranscriptPane.swift \
        Tests/StenoUITests/RecordingEditorTests.swift
git commit -m "feat(library): the title edits in place

Finder-style: click to rename, Return commits, Esc restores. A refusal keeps
the field open with what was typed — a sheet could close and show its message
on the way out, an inline field cannot."
```

---

### Task 5: The topic combo box, and where a refusal goes

**Files:**
- Modify: `Sources/StenoUI/TranscriptPane.swift`, `Sources/StenoUI/RecordingEditor.swift`
- Test: `Tests/StenoUITests/RecordingEditorTests.swift`

**Interfaces:**
- Consumes: `RecordingEditor.topicChoices(from:)`, `message(for:)`, `isBusyMessage(_:)`, `staysEditing(after:)` (Task 4).
- Produces: the header's topic control, and the removal of `.sheet(isPresented:)` and the `Edit…` button.

- [ ] **Step 1: Write the failing test**

Append to `Tests/StenoUITests/RecordingEditorTests.swift`:

```swift
/// The combo box offers what exists plus an explicit way out. "None" must be
/// distinguishable from a topic literally named that — `TopicName` reserves
/// the sidebar's Unfiled sentinel, so the menu's own escape hatch carries no
/// topic string at all.
@Test func theTopicMenuOffersExistingTopicsAndAWayToUnfile() {
    let choices = RecordingEditor.topicChoices(from: [
        withTopic("Receipts", "a"), withTopic("Admin", "b"),
    ])

    #expect(choices == ["Admin", "Receipts"])
    #expect(RecordingEditor.unfileLabel == "None — unfile this")
}
```

- [ ] **Step 2: Run and watch it fail**

Run: `swift test --filter theTopicMenuOffersExistingTopicsAndAWayToUnfile`
Expected: FAIL to compile — no `unfileLabel`.

- [ ] **Step 3: Add the label**

In `RecordingEditor.swift`:

```swift
    /// The combo box's escape hatch. Selecting it sets the topic to empty,
    /// which `updateRecording` turns into nil — it does not set a topic named
    /// "None".
    nonisolated static let unfileLabel = "None — unfile this"
```

- [ ] **Step 4: Build the topic control**

Everything here is inside `RecordingEditor`, not `TranscriptPane` — the editing state stays where `save()` can see it. Replace the static topic `Text` that Task 4 left in `RecordingEditor.body` with the same hover-then-edit shape the title uses:

```swift
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
                    .onTapGesture { editingTopic = true }
            }
```

Add the state and the commit, beside Task 4's:

```swift
    @State private var editingTopic = false
    @State private var hoveringTopic = false

    /// Commits the topic, and leaves edit mode only if the save landed.
    ///
    /// A refusal — `TopicName` rejects a bad folder name rather than repairing
    /// it — keeps the field open with what was typed, so the reason rendered
    /// below has something to point at.
    private func commitTopic() async {
        await save()
        if let lastOutcome { editingTopic = Self.staysEditing(after: lastOutcome) }
    }
```

The message row Task 4 added to `body` already renders refusals below both fields. Nothing to add for that here.

- [ ] **Step 5: Run everything**

Run: `swift build 2>&1 | grep -i warning; swift build -c release 2>&1 | grep -i warning; swift test`
Expected: zero warnings in both, everything passes.

- [ ] **Step 6: Re-run BOTH existing guards' mutation checks**

`TranscriptPane`'s body changed again.

Delete `Divider()` and `transport` from the body. Run `swift test --filter theTransportRowIsMountedBelowARuleAtTheBottomOfThePane`. Build must succeed, test must FAIL. Restore.

Delete `.id(recording.id)` from `LibraryWindow.detailContent`. Run `swift test --filter selectingARecordingGivesTheDetailPaneAFreshIdentity`. Build must succeed, test must FAIL. Restore.

Report both messages verbatim.

- [ ] **Step 7: Commit**

```bash
git add Sources/StenoUI/TranscriptPane.swift Sources/StenoUI/RecordingEditor.swift \
        Tests/StenoUITests/RecordingEditorTests.swift
git commit -m "feat(library): the topic is a combo box in the header

The sheet is gone. Topic and 'Existing topics' were two controls setting one
value, which is why it read as a debug panel; now it is one field with a
chevron. A refusal sits under it rather than vanishing with the sheet."
```

---

### Task 6: Verification and follow-ups

**Files:**
- Modify: `docs/superpowers/follow-ups.md`

- [ ] **Step 1: Full cold verification**

The in-repo `.build` is warm and will report success with zero compilation, hiding every warning. Build from a fresh scratch path:

```bash
SP=$(mktemp -d)
swift build --scratch-path "$SP" 2>&1 | grep -c 'warning:'
swift build -c release --scratch-path "$SP" 2>&1 | grep -c 'warning:'
swift test --scratch-path "$SP" 2>&1 | tail -3
git diff main...HEAD --stat -- Sources/JensenKit/    # must be empty
git diff main...HEAD --stat -- Sources/StenoUI/AppModel.swift   # must be empty
rm -rf "$SP"
```

Report the real numbers. Both `git diff` guards must come back empty; if either does not, that is a finding — report it rather than working around it.

- [ ] **Step 2: Build the bundle, do NOT launch it**

```bash
./Scripts/make-app.sh release
```

The script builds and prints an `open` command. **Do not run it, do not copy anything into `/Applications`, and do not start Steno.** The user's production app runs against a real library. Confirm the bundle built and stop.

- [ ] **Step 3: Record what only a human can check**

Append to `docs/superpowers/follow-ups.md` under a new `## Spec 5 deferred human checks` heading. That file already has content from specs 2 and 4 — append, do not overwrite.

Record: that a speed change is audible and holds across recordings and across a relaunch; that ±10s lands ten seconds away and re-attaches following when it was detached; that changing speed does *not* move the transcript; that the remaining/total label toggles on click; that hovering the title and the topic reveals the affordance before you click; that Return commits and Esc restores for both fields; that a refused topic name keeps the field open with what was typed and shows the reason underneath; and that the combo box's chevron opens a list containing the existing topics plus "None — unfile this".

Also record that the transport's disabled state — no known duration — is only reachable on a recording whose audio is missing, and has never been seen.

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/follow-ups.md
git commit -m "docs(follow-ups): spec 5's deferred human checks"
```

Then use `superpowers:requesting-code-review` for a whole-branch review before merging, and `superpowers:finishing-a-development-branch` to integrate.

---
