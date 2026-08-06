# Library Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A resizable window that lists every recording, reads its transcript, searches across all of them for playable moments, and lets a wrong title or topic be corrected.

**Architecture:** A third `Window(_:id:)` scene beside Settings and Reclaim. `LibraryStore` loads sidecars and transcripts into memory once; `TranscriptSearch` is a pure function over them; `AudioPlayer` wraps `AVPlayer` for seek-and-follow. The only write path goes through one new `AppModel` method that takes the same in-flight guard the transcription sweep uses.

**Tech Stack:** Swift 6.3, SwiftUI, `AVFoundation` (`AVPlayer`), SQLite3 via the existing `LibraryIndex`. Swift Testing.

**Spec:** `docs/superpowers/specs/2026-08-06-library-window-design.md`

## Global Constraints

Every task's requirements implicitly include all of these.

- **Swift 6 strict concurrency. Zero warnings in debug and release.**
- **Swift Testing only. Never XCTest.**
- **No third-party dependencies.** Apple frameworks are not third-party.
- **No test may require an attached P1, a network, Apple Intelligence, a downloaded model, the real library at `~/Recordings/Steno/`, or the real `deepgram-api-key` Keychain item.** No test may write to `~/Library/Logs/Steno/`.
- **`Sources/JensenKit/` must not be modified.** This spec sends no device command.
- **Do not restructure `SyncEngine`, `LibraryIndex`, `DeviceMonitor`, `TranscriptionQueue`, or `AppModel`'s sync guards.** `AppModel` gains new members only.
- **Sidecar is the source of truth. The transcript is canonical. The note is derived.** Nothing here rewrites a transcript.
- **`Library.destinationURL` must stay unchanged** — `SyncEngine`'s diff recomputes it.
- **Long-lived UI belongs in a `Window` scene, never a `.sheet` inside `MenuBarExtra`.**
- **`ImageRenderer` measures the IDEAL layout.** Every layout test renders **both** unconstrained and inside a deliberately short container, and asserts on the **spacing** of what is still drawn — never on how many ink bands appear, because clipping and collapsing both reduce a count. A count-based test during the spec-2 menu fix survived its own mutation check and proved nothing.
- **Mutation-check anything load-bearing:** apply the mutation, confirm the **build still succeeds**, confirm the named test goes RED, restore, confirm GREEN. A compile error does not discharge the check.
- **Every commit message ends with** `Claude-Session: https://claude.ai/code/session_016VkgCyG9HS1vHfn1fC2kzf`
- **Branch:** all work lands on `feat/library-window` cut from `main`.
- Baseline at the start: **262 tests passing, zero warnings in debug and release.**

## File Structure

**Created (all in `Sources/StenoUI/`)**

| File | Responsibility |
|---|---|
| `LoadedRecording.swift` | One recording plus its optional transcript. Value type. |
| `TranscriptSearch.swift` | PURE. query + recordings → moments. No I/O, no model. |
| `LibraryStore.swift` | `@Observable`. Loads the library off the main actor, owns query and selection. |
| `AudioPlayer.swift` | `@Observable` `AVPlayer` wrapper, plus the pure current-segment lookup. |
| `LibraryWindow.swift` | The scene's root: sidebar + detail split. |
| `LibrarySidebar.swift` | Recordings grouped by topic, filtered by the query. |
| `TranscriptPane.swift` | The reader and the follow-and-detach behaviour. |
| `MomentsPane.swift` | Search results grouped by recording. |
| `RecordingEditor.swift` | Title and topic editing UI. |

**Modified**

| File | Change |
|---|---|
| `Sources/StenoUI/AppModel.swift` | `librarySidecars()`, `updateRecording(_:title:topic:)`, `RecordingEditOutcome`. |
| `Sources/StenoUI/MenuBarView.swift` | `libraryWindowID` and a "Library…" row. |
| `Sources/StenoApp/StenoApp.swift` | The third `Window(_:id:)` scene. |

### One deliberate deviation from the spec

The spec proposes exposing a scoped guard, `AppModel.withRecordingHeld(_:perform:)`,
and having the editor assemble the write itself. **This plan puts the whole
write inside `AppModel.updateRecording` instead.**

The reason is that `AppModel.index` is *also* private, so the editor would need
two new exposures rather than one — and `retranscribe` already demonstrates the
shape where `AppModel` owns a guarded multi-step write end to end. One method
that cannot be called half-way is a smaller surface than a guard plus an index
accessor that a caller has to combine correctly.

---

## Task 1: TranscriptSearch and LoadedRecording

Pure, no I/O, and it carries the bulk of this spec's testing. Sequenced first for that reason.

**Files:**
- Create: `Sources/StenoUI/LoadedRecording.swift`
- Create: `Sources/StenoUI/TranscriptSearch.swift`
- Test: `Tests/StenoUITests/TranscriptSearchTests.swift`

**Interfaces:**
- Consumes: `Sidecar`, `Transcript`, `Segment` (all existing, public in `StenoUI`).
- Produces:
  - `struct LoadedRecording: Identifiable, Sendable, Equatable` with `sidecar: Sidecar`, `transcript: Transcript?`, `id: String`, `displayTitle: String`
  - `struct Moment: Identifiable, Sendable, Equatable` with `signature`, `recordingTitle`, `segment`, `highlight: Range<String.Index>`, `id: String`
  - `enum TranscriptSearch` with `static let resultCap = 500`, `static let minimumQueryLength = 2`, and
    `static func moments(matching:in:limit:) -> (moments: [Moment], capped: Bool)`

- [ ] **Step 1: Write the failing tests**

Create `Tests/StenoUITests/TranscriptSearchTests.swift`:

```swift
import Foundation
import Testing
@testable import StenoUI

private func segment(_ text: String, at start: Double) -> Segment {
    Segment(start: start, end: start + 3, text: text, speaker: nil)
}

private func loaded(
    _ signature: String, title: String?, _ segments: [Segment]
) -> LoadedRecording {
    let sidecar = Sidecar(
        signature: signature, deviceFilename: "\(signature).hda",
        relativePath: "2026-08-05/\(signature).mp3", lengthBytes: 10,
        durationSeconds: 600, recordedAt: Date(timeIntervalSince1970: 1_754_400_000),
        syncedAt: Date(timeIntervalSince1970: 1_754_400_000),
        deviceSerial: "S", deviceModel: "hidock-p1",
        timeZoneIdentifier: "Asia/Manila", title: title)
    let transcript = Transcript(
        signature: signature, text: segments.map(\.text).joined(separator: " "),
        segments: segments, locale: "en_US", backend: "speechanalyzer",
        modelID: "m", transcribedAt: Date(timeIntervalSince1970: 1),
        audioDurationSeconds: 600)
    return LoadedRecording(sidecar: sidecar, transcript: transcript)
}

private let library = [
    loaded("aaa", title: "Distribution Networking Explained", [
        segment("but you know what consignment is versus like", at: 87),
        segment("the consignment model means he never fronts cash", at: 842),
        segment("nothing relevant in this line at all", at: 900),
    ]),
    loaded("bbb", title: "Meeting Prep and Messaging Plan", [
        segment("we could do consignment for the first batch", at: 527),
    ]),
]

@Test func aMatchBecomesAMomentCarryingItsOwnStartTime() {
    let (moments, capped) = TranscriptSearch.moments(matching: "consignment", in: library)

    #expect(moments.count == 3)
    #expect(capped == false)
    #expect(moments.first?.segment.start == 87)
    #expect(moments.first?.recordingTitle == "Distribution Networking Explained")
    #expect(moments.first?.signature == "aaa")
}

/// The highlight indexes into the SEGMENT's text, so the pane can mark the
/// matched word without searching the string a second time.
@Test func theHighlightPointsAtTheMatchWithinItsSegment() throws {
    let (moments, _) = TranscriptSearch.moments(matching: "consignment", in: library)
    let first = try #require(moments.first)

    #expect(String(first.segment.text[first.highlight]).lowercased() == "consignment")
}

@Test func matchingIgnoresCase() {
    #expect(TranscriptSearch.moments(matching: "CONSIGNMENT", in: library).moments.count == 3)
}

@Test func matchingIgnoresDiacritics() {
    let accented = [loaded("ccc", title: "Café notes", [segment("we met at the cafe", at: 5)])]

    #expect(TranscriptSearch.moments(matching: "café", in: accented).moments.count == 1)
}

/// A one-character query would match nearly every segment in the library and
/// produce a result list nobody can use.
@Test func aQueryShorterThanTwoCharactersReturnsNothing() {
    #expect(TranscriptSearch.moments(matching: "c", in: library).moments.isEmpty)
    #expect(TranscriptSearch.moments(matching: "", in: library).moments.isEmpty)
    #expect(TranscriptSearch.moments(matching: "  ", in: library).moments.isEmpty)
}

@Test func noMatchesIsAnEmptyResultNotAnError() {
    #expect(TranscriptSearch.moments(matching: "zzzznothing", in: library).moments.isEmpty)
}

@Test func aQueryLongerThanAnySegmentMatchesNothing() {
    let long = String(repeating: "consignment ", count: 40)

    #expect(TranscriptSearch.moments(matching: long, in: library).moments.isEmpty)
}

/// The cap must actually cap, and must SAY it capped — silently truncating
/// would make the pane claim it had shown everything.
@Test func theResultCapBitesAndIsReported() {
    let many = (0..<50).map { i in
        loaded("sig\(i)", title: "R\(i)",
               (0..<10).map { j in segment("consignment line", at: Double(j)) })
    }

    let (moments, capped) = TranscriptSearch.moments(matching: "consignment", in: many, limit: 25)

    #expect(moments.count == 25)
    #expect(capped == true)
}

/// A recording the sweep has not reached yet has no transcript and simply
/// contributes no moments — it is not an error and must not crash the search.
@Test func aRecordingWithNoTranscriptContributesNothing() {
    let sidecar = Sidecar(
        signature: "ddd", deviceFilename: "d.hda", relativePath: "2026-08-05/d.mp3",
        lengthBytes: 10, durationSeconds: 60, recordedAt: nil,
        syncedAt: Date(timeIntervalSince1970: 1), deviceSerial: "S",
        deviceModel: "hidock-p1", timeZoneIdentifier: "Asia/Manila")
    let untranscribed = LoadedRecording(sidecar: sidecar, transcript: nil)

    #expect(TranscriptSearch.moments(matching: "consignment", in: [untranscribed]).moments.isEmpty)
}

/// Titles are model output and can be absent. A moment still has to name its
/// recording, so an untitled one falls back to something a human can read.
@Test func anUntitledRecordingStillNamesItselfInAMoment() throws {
    let untitled = [loaded("eee", title: nil, [segment("consignment terms", at: 4)])]
    let moment = try #require(TranscriptSearch.moments(matching: "consignment", in: untitled).moments.first)

    #expect(!moment.recordingTitle.isEmpty)
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `swift test --filter TranscriptSearch`
Expected: FAIL to compile — no `LoadedRecording`, `Moment`, or `TranscriptSearch`.

- [ ] **Step 3: Create `LoadedRecording.swift`**

```swift
import Foundation

/// One recording with its transcript, held in memory for the library window's
/// lifetime.
///
/// `transcript` is nil until the transcription queue has been through this
/// recording. That is not an error state: the sweep is asynchronous, so a
/// freshly synced recording legitimately has none yet, and everything that
/// consumes this type has to cope with that rather than treating it as broken.
public struct LoadedRecording: Identifiable, Sendable, Equatable {
    public let sidecar: Sidecar
    public let transcript: Transcript?

    public init(sidecar: Sidecar, transcript: Transcript?) {
        self.sidecar = sidecar
        self.transcript = transcript
    }

    public var id: String { sidecar.signature }

    /// What to call this recording on screen.
    ///
    /// The title is model output and is absent until transcription runs, so
    /// there has to be something readable to fall back to. The device filename
    /// is the one string every recording is guaranteed to have.
    public var displayTitle: String {
        if let title = sidecar.title, !title.isEmpty { return title }
        return sidecar.deviceFilename
    }
}
```

- [ ] **Step 4: Create `TranscriptSearch.swift`**

```swift
import Foundation

/// A single matching line — the unit a search returns, rather than a recording.
///
/// Carrying the whole `Segment` is what makes a result playable: `start` is the
/// second to seek to. That is the reason segment timings were persisted in
/// spec 2 rather than discarded after rendering the transcript.
public struct Moment: Identifiable, Sendable, Equatable {
    public let signature: String
    public let recordingTitle: String
    public let segment: Segment
    /// Where the query matched WITHIN `segment.text`, so the pane can mark it
    /// without searching the string a second time.
    public let highlight: Range<String.Index>

    public var id: String { "\(signature)-\(segment.start)" }
}

/// Finds playable moments across the whole library.
///
/// PURE — no I/O, no model, no stored state. The library is held in memory by
/// `LibraryStore`, so this is a function over an array, which is what makes the
/// part most likely to be wrong the part cheapest to test.
public enum TranscriptSearch {
    /// Above this, a result list stops being something a person can scan.
    public static let resultCap = 500

    /// One character matches nearly every segment in a library of prose.
    public static let minimumQueryLength = 2

    /// Returns matching moments and whether the cap bit.
    ///
    /// `capped` is reported rather than inferred from `moments.count == limit`,
    /// because a search that genuinely has exactly `limit` results is not the
    /// same as one that was truncated — and the pane says which.
    public static func moments(
        matching query: String,
        in recordings: [LoadedRecording],
        limit: Int = resultCap
    ) -> (moments: [Moment], capped: Bool) {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.count >= minimumQueryLength else { return ([], false) }

        var found: [Moment] = []
        for recording in recordings {
            guard let transcript = recording.transcript else { continue }
            for segment in transcript.segments {
                guard let range = segment.text.range(
                    of: needle, options: [.caseInsensitive, .diacriticInsensitive])
                else { continue }

                if found.count == limit { return (found, true) }
                found.append(Moment(signature: recording.sidecar.signature,
                                    recordingTitle: recording.displayTitle,
                                    segment: segment,
                                    highlight: range))
            }
        }
        return (found, false)
    }
}
```

- [ ] **Step 5: Run the tests**

Run: `swift build 2>&1 | grep -i warning; swift test --filter TranscriptSearch`
Expected: zero warnings, all ten PASS.

- [ ] **Step 6: MUTATION-CHECK the cap**

Change `if found.count == limit { return (found, true) }` to `if false { return (found, true) }`. Run `swift test --filter theResultCapBitesAndIsReported`. The build must succeed and the test must FAIL. Restore. Confirm PASS.

- [ ] **Step 7: Commit**

```bash
git checkout -b feat/library-window
git add Sources/StenoUI/LoadedRecording.swift Sources/StenoUI/TranscriptSearch.swift \
        Tests/StenoUITests/TranscriptSearchTests.swift
git commit -m "feat(library): pure search returning playable moments

A result is a moment, not a file — it carries the segment, so its start
time is the second to seek to. Case- and diacritic-insensitive, capped at
500 with the cap reported rather than inferred."
```

---

## Task 2: LibraryStore

**Files:**
- Create: `Sources/StenoUI/LibraryStore.swift`
- Modify: `Sources/StenoUI/AppModel.swift` (add `librarySidecars()`)
- Test: `Tests/StenoUITests/LibraryStoreTests.swift`

**Interfaces:**
- Consumes: `LoadedRecording` (Task 1), `TranscriptStore` (existing), `Sidecar`.
- Produces:
  - `@MainActor @Observable public final class LibraryStore` with `init()`, `recordings: [LoadedRecording]` (private(set)), `isLoading: Bool` (private(set)), `query: String`, `selection: String?`, and `func load(root: URL, sidecars: [Sidecar]) async`
  - `AppModel.librarySidecars() -> [Sidecar]`

- [ ] **Step 1: Write the failing tests**

Create `Tests/StenoUITests/LibraryStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import StenoUI

private func tempRoot() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

private func storeSidecar(_ signature: String, title: String? = nil) -> Sidecar {
    Sidecar(signature: signature, deviceFilename: "\(signature).hda",
            relativePath: "2026-08-05/\(signature).mp3", lengthBytes: 10,
            durationSeconds: 60, recordedAt: Date(timeIntervalSince1970: 1_754_400_000),
            syncedAt: Date(timeIntervalSince1970: 1_754_400_000),
            deviceSerial: "S", deviceModel: "hidock-p1",
            timeZoneIdentifier: "Asia/Manila", title: title)
}

@MainActor
@Test func loadPairsEachSidecarWithItsTranscript() async throws {
    let root = tempRoot()
    let store = TranscriptStore(root: root)
    let withText = storeSidecar("aaa", title: "Has a transcript")
    let without = storeSidecar("bbb")

    try store.write(TranscriptBody(text: "hello there", segments: [],
                                   locale: "en_US", backend: "speechanalyzer", modelID: "m"),
                    for: withText, at: Date(timeIntervalSince1970: 1))

    let library = LibraryStore()
    await library.load(root: root, sidecars: [withText, without])

    #expect(library.recordings.count == 2)
    #expect(library.recordings.first(where: { $0.id == "aaa" })?.transcript?.text == "hello there")
    #expect(library.recordings.first(where: { $0.id == "bbb" })?.transcript == nil)
}

/// A transcript whose stored signature belongs to a different recording is
/// refused by `TranscriptStore`, and the store must surface that as "not
/// transcribed" rather than showing someone else's words.
@MainActor
@Test func aMismatchedTranscriptIsTreatedAsAbsent() async throws {
    let root = tempRoot()
    let store = TranscriptStore(root: root)
    let mine = storeSidecar("mine")
    let theirs = Sidecar(signature: "theirs", deviceFilename: "t.hda",
                         relativePath: mine.relativePath, lengthBytes: 10,
                         durationSeconds: 60, recordedAt: nil,
                         syncedAt: Date(timeIntervalSince1970: 1), deviceSerial: "S",
                         deviceModel: "hidock-p1", timeZoneIdentifier: "Asia/Manila")

    try store.write(TranscriptBody(text: "a different meeting", segments: [],
                                   locale: "en_US", backend: "speechanalyzer", modelID: "m"),
                    for: theirs, at: Date(timeIntervalSince1970: 1))

    let library = LibraryStore()
    await library.load(root: root, sidecars: [mine])

    #expect(library.recordings.first?.transcript == nil)
}

@MainActor
@Test func loadingClearsWhenItFinishes() async {
    let library = LibraryStore()
    await library.load(root: tempRoot(), sidecars: [])

    #expect(library.isLoading == false)
    #expect(library.recordings.isEmpty)
}

@MainActor
@Test func aSecondLoadReplacesRatherThanAppends() async {
    let root = tempRoot()
    let library = LibraryStore()

    await library.load(root: root, sidecars: [storeSidecar("aaa")])
    await library.load(root: root, sidecars: [storeSidecar("bbb")])

    #expect(library.recordings.map(\.id) == ["bbb"])
}
```

- [ ] **Step 2: Run and watch them fail**

Run: `swift test --filter LibraryStore`
Expected: FAIL to compile — no `LibraryStore`.

- [ ] **Step 3: Create `LibraryStore.swift`**

```swift
import Foundation
import Observation

/// The library window's model: every recording, paired with its transcript,
/// held in memory for the window's lifetime.
///
/// Loading is deliberately eager and one-shot rather than lazy per row. The
/// whole point of this window is search, and search needs every transcript in
/// hand — a lazy loader would fetch them all on the first keystroke anyway,
/// just less predictably.
@MainActor
@Observable
public final class LibraryStore {
    public private(set) var recordings: [LoadedRecording] = []
    public private(set) var isLoading = false

    /// Live search text. Empty means "not searching", which is a different
    /// state from "searched and found nothing".
    public var query: String = ""

    /// Selected recording's signature, or nil before anything is chosen.
    public var selection: String?

    public init() {}

    /// Reads every transcript off the main actor and assigns the result in one
    /// go.
    ///
    /// `TranscriptStore.transcript(for:)` decodes JSON and verifies a signature
    /// per recording, so this is N decodes — the same work spec 2 had to move
    /// off the main actor for the transcription sweep. Doing it inline would
    /// hitch the window open on a large library.
    public func load(root: URL, sidecars: [Sidecar]) async {
        isLoading = true
        defer { isLoading = false }

        let loaded = await Task.detached {
            let store = TranscriptStore(root: root)
            return sidecars.map {
                LoadedRecording(sidecar: $0, transcript: store.transcript(for: $0))
            }
        }.value

        recordings = loaded
    }
}
```

- [ ] **Step 4: Add `librarySidecars()` to `AppModel`**

`AppModel.index` is private, so the window cannot read the library itself. Add this beside `rebuildIndex()`:

```swift
    /// Every recording the index knows about, for the library window.
    ///
    /// Ordered by `recorded_at DESC` by `LibraryIndex.all()`, which is the
    /// order the window wants anyway. Returns empty rather than throwing: an
    /// unreadable index is already surfaced through `lastError` by `openIndex`,
    /// and a window that shows nothing is better than one that cannot open.
    public func librarySidecars() -> [Sidecar] {
        (try? index?.all()) ?? []
    }
```

- [ ] **Step 5: Run the tests**

Run: `swift build 2>&1 | grep -i warning; swift test --filter LibraryStore`
Expected: zero warnings, all four PASS.

- [ ] **Step 6: MUTATION-CHECK the signature refusal**

In `TranscriptStore.transcript(for:)`, delete the `transcript.signature == sidecar.signature` comparison. Run `swift test --filter aMismatchedTranscriptIsTreatedAsAbsent`. The build must succeed and the test must FAIL. Restore. Confirm PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/StenoUI/LibraryStore.swift Sources/StenoUI/AppModel.swift \
        Tests/StenoUITests/LibraryStoreTests.swift
git commit -m "feat(library): load sidecars and transcripts off the main actor

N JSON decodes with a signature check each — the same work the sweep had
to move off main in spec 2. A mismatched transcript reads as absent, not
as someone else's words."
```

---

## Task 3: AudioPlayer

**Files:**
- Create: `Sources/StenoUI/AudioPlayer.swift`
- Test: `Tests/StenoUITests/AudioPlayerTests.swift`

**Interfaces:**
- Consumes: `Segment` (existing).
- Produces:
  - `@MainActor @Observable public final class AudioPlayer` with `init()`, `currentTime: Double` (private(set)), `isPlaying: Bool` (private(set)), `duration: Double` (private(set)), `func load(_ url: URL)`, `func play()`, `func pause()`, `func seek(to: Double)`, `func stop()`
  - `nonisolated static func currentSegmentIndex(at: Double, in: [Segment]) -> Int?`

- [ ] **Step 1: Write the failing tests**

Only the pure lookup is testable without audio hardware. Create `Tests/StenoUITests/AudioPlayerTests.swift`:

```swift
import Foundation
import Testing
@testable import StenoUI

private let segments = [
    Segment(start: 0, end: 10, text: "first", speaker: nil),
    Segment(start: 10, end: 20, text: "second", speaker: nil),
    Segment(start: 25, end: 30, text: "third after a gap", speaker: nil),
]

@Test func theSegmentContainingTheCurrentTimeIsTheCurrentOne() {
    #expect(AudioPlayer.currentSegmentIndex(at: 5, in: segments) == 0)
    #expect(AudioPlayer.currentSegmentIndex(at: 15, in: segments) == 1)
    #expect(AudioPlayer.currentSegmentIndex(at: 27, in: segments) == 2)
}

/// A segment owns its start instant. Without this, seeking to a line's own
/// start would highlight the line before it.
@Test func aSegmentsOwnStartBelongsToIt() {
    #expect(AudioPlayer.currentSegmentIndex(at: 10, in: segments) == 1)
    #expect(AudioPlayer.currentSegmentIndex(at: 25, in: segments) == 2)
}

/// Silence between segments must not highlight anything, or the highlight
/// lingers on a line nobody is speaking.
@Test func timeInAGapHighlightsNothing() {
    #expect(AudioPlayer.currentSegmentIndex(at: 22, in: segments) == nil)
}

@Test func timeBeforeOrAfterEverythingHighlightsNothing() {
    #expect(AudioPlayer.currentSegmentIndex(at: -1, in: segments) == nil)
    #expect(AudioPlayer.currentSegmentIndex(at: 999, in: segments) == nil)
}

@Test func anEmptyTranscriptHasNoCurrentSegment() {
    #expect(AudioPlayer.currentSegmentIndex(at: 5, in: []) == nil)
}
```

- [ ] **Step 2: Run and watch them fail**

Run: `swift test --filter AudioPlayer`
Expected: FAIL to compile — no `AudioPlayer`.

- [ ] **Step 3: Create `AudioPlayer.swift`**

```swift
import AVFoundation
import Foundation
import Observation

/// Playback for one recording at a time, with a time signal fine enough to
/// follow a transcript.
///
/// `AVPlayer`, not `AVAudioPlayer`: only `AVPlayer` offers
/// `addPeriodicTimeObserver`, and following playback needs the player to tell
/// us where it is rather than being polled on a timer.
@MainActor
@Observable
public final class AudioPlayer {
    public private(set) var currentTime: Double = 0
    public private(set) var isPlaying = false
    public private(set) var duration: Double = 0

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var observer: Any?

    public init() {}

    deinit {
        // The observer holds the player; without this the pair outlives the
        // window and keeps ticking.
        if let observer, let player { player.removeTimeObserver(observer) }
    }

    public func load(_ url: URL) {
        stop()
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.player = player
        currentTime = 0
        duration = 0

        // Four times a second: fine enough that a highlight lands on the right
        // line, coarse enough not to churn the view for a text list.
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        observer = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) {
            [weak self] time in
            MainActor.assumeIsolated {
                self?.currentTime = time.seconds
                if let seconds = self?.player?.currentItem?.duration.seconds,
                   seconds.isFinite { self?.duration = seconds }
            }
        }
    }

    public func play() {
        player?.play()
        isPlaying = true
    }

    public func pause() {
        player?.pause()
        isPlaying = false
    }

    public func seek(to seconds: Double) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        currentTime = seconds
    }

    public func stop() {
        pause()
        if let observer, let player { player.removeTimeObserver(observer) }
        observer = nil
        player = nil
        currentTime = 0
        duration = 0
    }

    /// Which segment is being spoken at `time`, or nil in a gap.
    ///
    /// PURE, and therefore the testable part — the `AVPlayer` above cannot be
    /// exercised without audio hardware. A segment owns its own start instant:
    /// seeking to a line's start must highlight that line, not the one before.
    nonisolated static func currentSegmentIndex(at time: Double, in segments: [Segment]) -> Int? {
        segments.firstIndex { time >= $0.start && time < $0.end }
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift build 2>&1 | grep -i warning; swift test --filter AudioPlayer`
Expected: zero warnings, all five PASS.

- [ ] **Step 5: MUTATION-CHECK the start-inclusive boundary**

Change `time >= $0.start` to `time > $0.start`. Run `swift test --filter aSegmentsOwnStartBelongsToIt`. The build must succeed and the test must FAIL. Restore. Confirm PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/StenoUI/AudioPlayer.swift Tests/StenoUITests/AudioPlayerTests.swift
git commit -m "feat(library): AVPlayer wrapper with a pure current-segment lookup

AVPlayer rather than AVAudioPlayer because only it offers a periodic time
observer, and following a transcript needs the player to report position
rather than be polled."
```

---

## Task 4: The edit write path

**The highest-risk task in this plan.** This makes the window the **third** writer to a sidecar, after the automatic sweep and manual re-transcription. Built and reviewed before any UI touches it.

**Files:**
- Modify: `Sources/StenoUI/AppModel.swift`
- Test: `Tests/StenoUITests/RecordingEditTests.swift`

**Interfaces:**
- Consumes: `Library.updateSidecar(_:)`, `LibraryIndex.upsert(_:)`, `Filer.write(for:transcript:)`, `Filer.removeNote(for:topic:)`, `TopicName.sanitised(_:)`, `AppModel.mayStartTranscribing(signature:inFlight:)` — all existing.
- Produces:
  - `enum RecordingEditOutcome: Sendable, Equatable` with cases `updated(Sidecar)`, `busy`, `rejectedTopic(String)`, `failed(String)`
  - `AppModel.updateRecording(_:title:topic:) async -> RecordingEditOutcome`
  - `AppModel.editedSidecar(from:title:topic:) -> Sidecar` (nonisolated static, pure)

- [ ] **Step 1: Write the failing tests**

The orchestration touches a live `AppModel`, which drives USB. Test the **pure** part directly, exactly as `mayStartTranscribing` and `shouldClearTranscriptionState` already are. Create `Tests/StenoUITests/RecordingEditTests.swift`:

```swift
import Foundation
import Testing
@testable import StenoUI

private func editable(title: String? = "Old title", topic: String? = "Old Topic") -> Sidecar {
    Sidecar(signature: "sig", deviceFilename: "a.hda",
            relativePath: "2026-08-05/a.mp3", lengthBytes: 10,
            durationSeconds: 60, recordedAt: Date(timeIntervalSince1970: 1_754_400_000),
            syncedAt: Date(timeIntervalSince1970: 1_754_400_000),
            deviceSerial: "S", deviceModel: "hidock-p1",
            timeZoneIdentifier: "Asia/Manila", title: title, topic: topic,
            transcribedAt: Date(timeIntervalSince1970: 2),
            transcriptBackend: "speechanalyzer")
}

@Test func editingRewritesOnlyTitleAndTopic() {
    let before = editable()
    let after = AppModel.editedSidecar(from: before, title: "New title", topic: "New Topic")

    #expect(after.title == "New title")
    #expect(after.topic == "New Topic")

    // Everything identifying or provenance-bearing must survive untouched.
    #expect(after.signature == before.signature)
    #expect(after.relativePath == before.relativePath)
    #expect(after.deviceModel == "hidock-p1")
    #expect(after.transcribedAt == before.transcribedAt)
    #expect(after.transcriptBackend == before.transcriptBackend)
    #expect(after.lengthBytes == before.lengthBytes)
    #expect(after.recordedAt == before.recordedAt)
}

/// Clearing the topic unfiles the recording. It must become nil rather than an
/// empty string, because `TopicName` rejects empty and a `""` topic would make
/// `Filer` build a path at the library root itself.
@Test func clearingTheTopicUnfilesRatherThanFilingUnderNothing() {
    let after = AppModel.editedSidecar(from: editable(), title: "T", topic: nil)

    #expect(after.topic == nil)
}

/// A blank title means "no title", the same state a recording has before
/// transcription — not a recording literally called "".
@Test func aBlankTitleBecomesNoTitle() {
    #expect(AppModel.editedSidecar(from: editable(), title: "   ", topic: "T").title == nil)
}

@Test func titleAndTopicAreTrimmed() {
    let after = AppModel.editedSidecar(from: editable(), title: "  New  ", topic: "  Topic  ")

    #expect(after.title == "New")
    #expect(after.topic == "Topic")
}

/// The guard the sweep uses, reused here. A recording already being written by
/// the transcription queue must not be editable at the same instant.
@Test func aRecordingTheSweepIsWritingIsNotEditable() {
    #expect(!AppModel.mayStartTranscribing(signature: "sig", inFlight: ["sig"]))
    #expect(AppModel.mayStartTranscribing(signature: "sig", inFlight: ["other"]))
}
```

- [ ] **Step 2: Run and watch them fail**

Run: `swift test --filter RecordingEdit`
Expected: FAIL to compile — `editedSidecar` is not a member of `AppModel`.

- [ ] **Step 3: Add the outcome type and the pure builder**

In `AppModel.swift`, above the class:

```swift
/// What happened when the library window tried to save an edit.
public enum RecordingEditOutcome: Sendable, Equatable {
    case updated(Sidecar)
    /// Something else — the sweep, or a manual re-transcription — is writing
    /// this recording right now. The editor says so and leaves the field alone.
    case busy
    /// `TopicName` refused the folder name. Carries the name that was refused.
    case rejectedTopic(String)
    case failed(String)
}
```

Inside `AppModel`, beside `mayStartTranscribing`:

```swift
    /// The edited sidecar, as a pure function of the old one.
    ///
    /// Extracted so the part that decides WHAT changes is testable without a
    /// live `AppModel` — the same split as `mayStartTranscribing` and
    /// `shouldClearTranscriptionState`. Only `title` and `topic` may move;
    /// everything identifying or provenance-bearing is copied through.
    ///
    /// Blank becomes nil rather than "": an empty title is the state a
    /// recording has before transcription, and an empty topic would make
    /// `Filer` build a path at the library root itself.
    nonisolated static func editedSidecar(
        from sidecar: Sidecar, title: String, topic: String?
    ) -> Sidecar {
        func trimmedOrNil(_ value: String?) -> String? {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else { return nil }
            return trimmed
        }

        var edited = sidecar
        edited.title = trimmedOrNil(title)
        edited.topic = trimmedOrNil(topic)
        return edited
    }
```

- [ ] **Step 4: Add the orchestration**

Beside `retranscribe`:

```swift
    /// Saves a title and topic edit from the library window.
    ///
    /// This is the THIRD writer to a sidecar, after the automatic sweep and
    /// manual re-transcription, and it takes the same `sidecarsInFlight` guard
    /// they do. Skipping it reopens the race spec 2 closed, and the failure
    /// would be silent: last writer wins, so a title just typed could be
    /// replaced by the sweep finishing a moment later.
    ///
    /// Order matches `TranscriptionQueue.run`: sidecar, then index, then the
    /// note. The note is derived and regenerable, so a failure there is worth
    /// reporting but not worth failing the edit over.
    public func updateRecording(
        _ sidecar: Sidecar, title: String, topic: String?
    ) async -> RecordingEditOutcome {
        let requested = topic?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let requested, !requested.isEmpty, TopicName.sanitised(requested) == nil {
            return .rejectedTopic(requested)
        }

        guard Self.mayStartTranscribing(signature: sidecar.signature,
                                        inFlight: sidecarsInFlight) else { return .busy }
        sidecarsInFlight.insert(sidecar.signature)
        defer { sidecarsInFlight.remove(sidecar.signature) }

        let edited = Self.editedSidecar(from: sidecar, title: title, topic: topic)
        let root = libraryRoot
        let library = Library(root: root)

        do {
            try await Task.detached { try library.updateSidecar(edited) }.value
        } catch {
            return .failed(error.localizedDescription)
        }

        try? index?.upsert(edited)

        let filer = Filer(root: root)
        if let previous = sidecar.topic, previous != edited.topic {
            filer.removeNote(for: sidecar, topic: previous)
        }
        if edited.topic != nil,
           let transcript = TranscriptStore(root: root).transcript(for: edited) {
            try? filer.write(for: edited, transcript: transcript)
        }

        reloadRecent()
        return .updated(edited)
    }
```

- [ ] **Step 5: Run the tests**

Run: `swift build 2>&1 | grep -i warning; swift build -c release 2>&1 | grep -i warning; swift test`
Expected: zero warnings in both, everything PASS.

- [ ] **Step 6: MUTATION-CHECK the in-flight guard**

Replace the `guard Self.mayStartTranscribing(...) else { return .busy }` line with `_ = sidecarsInFlight`. Confirm the build still succeeds. Then confirm by inspection that `updateRecording` no longer refuses a busy recording, and restore. **Also** mutate `editedSidecar` so it writes `edited.signature = "changed"`, run `swift test --filter editingRewritesOnlyTitleAndTopic`, confirm RED, restore, confirm GREEN.

- [ ] **Step 7: Commit**

```bash
git add Sources/StenoUI/AppModel.swift Tests/StenoUITests/RecordingEditTests.swift
git commit -m "feat(library): the edit write path, guarded like the sweep

The window is the third writer to a sidecar. It takes the same
sidecarsInFlight guard the automatic sweep and manual re-transcription
take, because the failure without it is silent — last writer wins, so a
title just typed could be replaced by the sweep finishing.

The decision about WHAT changes is a pure function, testable without a
live AppModel, matching mayStartTranscribing and friends."
```

---

## Task 5: The window scene and sidebar

**Files:**
- Create: `Sources/StenoUI/LibraryWindow.swift`
- Create: `Sources/StenoUI/LibrarySidebar.swift`
- Modify: `Sources/StenoUI/MenuBarView.swift`
- Modify: `Sources/StenoApp/StenoApp.swift`
- Test: `Tests/StenoUITests/LibrarySidebarTests.swift`

**Interfaces:**
- Consumes: `LibraryStore` (Task 2), `AppModel.librarySidecars()` (Task 2), `LoadedRecording` (Task 1).
- Produces:
  - `MenuBarView.libraryWindowID = "library"`
  - `public struct LibraryWindow: View` with `init(model: AppModel)`
  - `public struct LibrarySidebar: View`
  - `LibrarySidebar.grouped(_:) -> [(topic: String, recordings: [LoadedRecording])]` (nonisolated static, pure)

- [ ] **Step 1: Write the failing tests**

Create `Tests/StenoUITests/LibrarySidebarTests.swift`:

```swift
import Foundation
import Testing
@testable import StenoUI

private func grouped(_ topic: String?, _ signature: String) -> LoadedRecording {
    LoadedRecording(
        sidecar: Sidecar(signature: signature, deviceFilename: "\(signature).hda",
                         relativePath: "2026-08-05/\(signature).mp3", lengthBytes: 10,
                         durationSeconds: 60,
                         recordedAt: Date(timeIntervalSince1970: 1_754_400_000),
                         syncedAt: Date(timeIntervalSince1970: 1),
                         deviceSerial: "S", deviceModel: "hidock-p1",
                         timeZoneIdentifier: "Asia/Manila", title: "T", topic: topic),
        transcript: nil)
}

@Test func recordingsAreGroupedByTopic() {
    let groups = LibrarySidebar.grouped([
        grouped("Client Calls", "a"), grouped("Receipts", "b"), grouped("Client Calls", "c"),
    ])

    #expect(groups.count == 2)
    #expect(groups.first(where: { $0.topic == "Client Calls" })?.recordings.count == 2)
}

/// Filing has never run on the real library, so every recording is unfiled
/// today. That has to be a named group, not a blank heading.
@Test func unfiledRecordingsGetTheirOwnNamedGroup() {
    let groups = LibrarySidebar.grouped([grouped(nil, "a"), grouped(nil, "b")])

    #expect(groups.count == 1)
    #expect(groups.first?.topic == "Unfiled")
    #expect(groups.first?.recordings.count == 2)
}

/// Unfiled sorts last, so a library that is entirely unfiled today does not
/// bury its real topics under a growing pile tomorrow.
@Test func unfiledSortsAfterNamedTopics() {
    let groups = LibrarySidebar.grouped([grouped(nil, "a"), grouped("Receipts", "b")])

    #expect(groups.map(\.topic) == ["Receipts", "Unfiled"])
}

@Test func namedTopicsSortAlphabetically() {
    let groups = LibrarySidebar.grouped([
        grouped("Receipts", "a"), grouped("Admin", "b"), grouped("Client Calls", "c"),
    ])

    #expect(groups.map(\.topic) == ["Admin", "Client Calls", "Receipts"])
}

@Test func anEmptyLibraryProducesNoGroups() {
    #expect(LibrarySidebar.grouped([]).isEmpty)
}
```

- [ ] **Step 2: Run and watch them fail**

Run: `swift test --filter LibrarySidebar`
Expected: FAIL to compile — no `LibrarySidebar`.

- [ ] **Step 3: Create `LibrarySidebar.swift`**

```swift
import SwiftUI

/// The library window's left pane: recordings grouped by topic.
public struct LibrarySidebar: View {
    @Bindable var store: LibraryStore

    public init(store: LibraryStore) { self.store = store }

    /// The name a recording with no topic is filed under on screen.
    ///
    /// Filing has never run on the real library, so today every recording lands
    /// here — which makes this a real heading rather than an edge case.
    static let unfiled = "Unfiled"

    public var body: some View {
        List(selection: $store.selection) {
            ForEach(Self.grouped(store.recordings), id: \.topic) { group in
                Section(group.topic) {
                    ForEach(group.recordings) { recording in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(recording.displayTitle).lineLimit(1)
                            Text(Self.subtitle(for: recording))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(recording.id)
                    }
                }
            }
        }
    }

    /// Groups recordings by topic, named topics alphabetically then Unfiled.
    ///
    /// PURE, and therefore the testable part. Unfiled sorts last so a library
    /// that is entirely unfiled today does not bury real topics under a growing
    /// pile tomorrow.
    nonisolated static func grouped(
        _ recordings: [LoadedRecording]
    ) -> [(topic: String, recordings: [LoadedRecording])] {
        let buckets = Dictionary(grouping: recordings) { $0.sidecar.topic ?? unfiled }
        return buckets
            .map { (topic: $0.key, recordings: $0.value) }
            .sorted {
                if $0.topic == unfiled { return false }
                if $1.topic == unfiled { return true }
                return $0.topic.localizedCaseInsensitiveCompare($1.topic) == .orderedAscending
            }
    }

    nonisolated static func subtitle(for recording: LoadedRecording) -> String {
        let duration = recording.sidecar.durationSeconds.map {
            String(format: "%d:%02d", Int($0) / 60, Int($0) % 60)
        } ?? "—"
        guard let recorded = recording.sidecar.recordedAt else { return duration }
        return "\(Self.dayFormatter.string(from: recorded)) · \(duration)"
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "MMM d"
        return f
    }()
}
```

- [ ] **Step 4: Create `LibraryWindow.swift`**

```swift
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
            // The real empty state, not scaffolding: Tasks 6 and 7 add branches
            // above this one, and this stays as the nothing-selected case.
            ContentUnavailableView("No recording selected", systemImage: "waveform")
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

    private func reload() async {
        await store.load(root: model.libraryRoot, sidecars: model.librarySidecars())
    }
}
```

- [ ] **Step 5: Add the window ID and the menu row**

In `MenuBarView.swift`, beside `reclaimWindowID`:

```swift
    /// The third `Window(_:id:)` scene `StenoApp` declares. Unlike the other
    /// two it is resizable — it is the first surface in this app anyone would
    /// want to make bigger.
    public static let libraryWindowID = "library"
```

In `actionsSection`, above `"Free Up Space on P1…"`:

```swift
        MenuRow("Library…") { open(Self.libraryWindowID) }
```

- [ ] **Step 6: Declare the scene**

In `StenoApp.swift`, after the Reclaim window:

```swift
        // Resizable, unlike Settings and Reclaim: those are fixed-size forms,
        // this is a library you will want to make bigger. `.contentMinSize`
        // keeps the split view from being dragged narrower than it can draw.
        Window("Steno Library", id: MenuBarView.libraryWindowID) {
            LibraryWindow(model: appDelegate.model)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 900, height: 600)
```

- [ ] **Step 7: Run the tests and build the app**

Run: `swift build 2>&1 | grep -i warning; swift test --filter LibrarySidebar; ./Scripts/make-app.sh release`
Expected: zero warnings, five tests PASS, the app builds.

- [ ] **Step 8: Commit**

```bash
git add Sources/StenoUI/LibraryWindow.swift Sources/StenoUI/LibrarySidebar.swift \
        Sources/StenoUI/MenuBarView.swift Sources/StenoApp/StenoApp.swift \
        Tests/StenoUITests/LibrarySidebarTests.swift
git commit -m "feat(library): the window scene and its topic-grouped sidebar

Resizable, unlike Settings and Reclaim. Unfiled is a real named group and
sorts last, because filing has never run and today every recording is in
it."
```

---

## Task 6: TranscriptPane, follow and detach

**Files:**
- Create: `Sources/StenoUI/TranscriptPane.swift`
- Modify: `Sources/StenoUI/LibraryWindow.swift` (replace the detail placeholder)
- Test: `Tests/StenoUITests/TranscriptPaneTests.swift`

**Interfaces:**
- Consumes: `LoadedRecording`, `AudioPlayer.currentSegmentIndex(at:in:)`.
- Produces:
  - `public struct TranscriptPane: View`
  - `TranscriptPane.remainsFollowing(isFollowing:userScrolled:) -> Bool` (nonisolated static, pure)
  - `TranscriptPane.speakerLabel(for:) -> String?` (nonisolated static, pure)

- [ ] **Step 1: Write the failing tests**

Create `Tests/StenoUITests/TranscriptPaneTests.swift`:

```swift
import Foundation
import SwiftUI
import Testing
@testable import StenoUI

/// The detach rule IS the feature. Auto-scroll that keeps yanking the view
/// while you are re-reading something is worse than no auto-scroll at all.
@Test func scrollingByHandStopsTheTranscriptFollowing() {
    #expect(!TranscriptPane.remainsFollowing(isFollowing: true, userScrolled: true))
}

@Test func followingContinuesWhenTheUserHasNotScrolled() {
    #expect(TranscriptPane.remainsFollowing(isFollowing: true, userScrolled: false))
}

/// Scrolling while already detached must not silently re-attach.
@Test func scrollingWhileDetachedLeavesItDetached() {
    #expect(!TranscriptPane.remainsFollowing(isFollowing: false, userScrolled: true))
    #expect(!TranscriptPane.remainsFollowing(isFollowing: false, userScrolled: false))
}

/// Deepgram populates `speaker`; on-device leaves it nil. A recording that was
/// never diarized must not sprout a fake "Speaker 1".
@Test func onlyDiarizedSegmentsGetASpeakerLabel() {
    let diarized = Segment(start: 0, end: 1, text: "hello", speaker: 0)
    let plain = Segment(start: 0, end: 1, text: "hello", speaker: nil)

    #expect(TranscriptPane.speakerLabel(for: diarized) != nil)
    #expect(TranscriptPane.speakerLabel(for: plain) == nil)
}

@Test func speakerLabelsAreOneBasedForReading() {
    #expect(TranscriptPane.speakerLabel(for: Segment(start: 0, end: 1, text: "x", speaker: 0)) == "Speaker 1")
    #expect(TranscriptPane.speakerLabel(for: Segment(start: 0, end: 1, text: "x", speaker: 1)) == "Speaker 2")
}
```

- [ ] **Step 2: Run and watch them fail**

Run: `swift test --filter TranscriptPane`
Expected: FAIL to compile — no `TranscriptPane`.

- [ ] **Step 3: Create `TranscriptPane.swift`**

```swift
import SwiftUI

/// The library window's reader: one transcript, with playback following along.
public struct TranscriptPane: View {
    let recording: LoadedRecording
    @Bindable var player: AudioPlayer

    @State private var isFollowing = true

    public init(recording: LoadedRecording, player: AudioPlayer) {
        self.recording = recording
        self.player = player
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
```

- [ ] **Step 4: Wire it into the window**

In `LibraryWindow.swift`, replace the `detail:` placeholder:

```swift
        } detail: {
            if let selected = store.recordings.first(where: { $0.id == store.selection }) {
                TranscriptPane(recording: selected, player: player)
            } else {
                ContentUnavailableView("No recording selected", systemImage: "waveform")
            }
        }
```

Audio loading stays on the `.onChange(of: store.selection)` added to the
`NavigationSplitView` in Task 5 — it must not move into this branch, because a
closure built inside a branch captures the selection that was current when the
branch was built and would load the previous recording's audio.

- [ ] **Step 5: Run the tests**

Run: `swift build 2>&1 | grep -i warning; swift test --filter TranscriptPane`
Expected: zero warnings, all six PASS.

- [ ] **Step 6: MUTATION-CHECK the detach rule**

Change `remainsFollowing` to `isFollowing` (dropping `&& !userScrolled`). Run `swift test --filter scrollingByHandStopsTheTranscriptFollowing`. The build must succeed and the test must FAIL. Restore. Confirm PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/StenoUI/TranscriptPane.swift Sources/StenoUI/LibraryWindow.swift \
        Tests/StenoUITests/TranscriptPaneTests.swift
git commit -m "feat(library): the transcript reader, following and detaching

Scrolling by hand detaches following and offers to resume. That rule is
the feature — auto-scroll that yanks the view while you re-read is worse
than none. Speaker labels appear only where Deepgram put one."
```

---

## Task 7: MomentsPane

**Files:**
- Create: `Sources/StenoUI/MomentsPane.swift`
- Modify: `Sources/StenoUI/LibraryWindow.swift`
- Test: `Tests/StenoUITests/MomentsPaneTests.swift`

**Interfaces:**
- Consumes: `Moment`, `TranscriptSearch` (Task 1), `AudioPlayer` (Task 3).
- Produces:
  - `public struct MomentsPane: View`
  - `MomentsPane.grouped(_:) -> [(title: String, moments: [Moment])]` (nonisolated static, pure)
  - `MomentsPane.summary(count:capped:) -> String` (nonisolated static, pure)

- [ ] **Step 1: Write the failing tests**

Create `Tests/StenoUITests/MomentsPaneTests.swift`:

```swift
import Foundation
import Testing
@testable import StenoUI

private func moment(_ signature: String, _ title: String, at start: Double) -> Moment {
    let text = "a line about consignment"
    return Moment(signature: signature, recordingTitle: title,
                  segment: Segment(start: start, end: start + 2, text: text, speaker: nil),
                  highlight: text.range(of: "consignment")!)
}

@Test func momentsAreGroupedByRecordingInFirstAppearanceOrder() {
    let groups = MomentsPane.grouped([
        moment("a", "First", at: 1), moment("b", "Second", at: 2), moment("a", "First", at: 3),
    ])

    #expect(groups.map(\.title) == ["First", "Second"])
    #expect(groups.first?.moments.count == 2)
}

/// The count is what tells you whether it is worth reading the list, so it has
/// to say when it was truncated rather than implying it showed everything.
@Test func theSummarySaysWhenTheCapBit() {
    #expect(MomentsPane.summary(count: 4, capped: false) == "4 moments")
    #expect(MomentsPane.summary(count: 500, capped: true) == "First 500 moments")
}

@Test func theSummaryIsSingularForOne() {
    #expect(MomentsPane.summary(count: 1, capped: false) == "1 moment")
}

@Test func noMatchesSaysSoRatherThanShowingZero() {
    #expect(MomentsPane.summary(count: 0, capped: false) == "No matches")
}

@Test func anEmptyResultProducesNoGroups() {
    #expect(MomentsPane.grouped([]).isEmpty)
}
```

- [ ] **Step 2: Run and watch them fail**

Run: `swift test --filter MomentsPane`
Expected: FAIL to compile — no `MomentsPane`.

- [ ] **Step 3: Create `MomentsPane.swift`**

```swift
import SwiftUI

/// The library window's right pane while a search is active: matching lines
/// from anywhere in the library, each one playable where it sits.
public struct MomentsPane: View {
    let moments: [Moment]
    let capped: Bool
    let onPlay: (Moment) -> Void

    public init(moments: [Moment], capped: Bool, onPlay: @escaping (Moment) -> Void) {
        self.moments = moments
        self.capped = capped
        self.onPlay = onPlay
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Self.summary(count: moments.count, capped: capped))
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 6)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Self.grouped(moments), id: \.title) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.title).font(.caption).foregroundStyle(.secondary)
                            ForEach(group.moments) { moment in
                                Button { onPlay(moment) } label: {
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Image(systemName: "play.fill").font(.caption2)
                                        Text(TranscriptPane.timestamp(moment.segment.start))
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.tertiary)
                                        Text(highlighted(moment))
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.vertical, 3).padding(.horizontal, 6)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(12)
            }
        }
    }

    /// The matched word marked, using the range the search already computed
    /// rather than searching the string a second time.
    private func highlighted(_ moment: Moment) -> AttributedString {
        var text = AttributedString(moment.segment.text)
        if let lower = AttributedString.Index(moment.highlight.lowerBound, within: text),
           let upper = AttributedString.Index(moment.highlight.upperBound, within: text) {
            text[lower..<upper].backgroundColor = .yellow.opacity(0.35)
        }
        return text
    }

    /// Groups moments by recording, in first-appearance order.
    ///
    /// PURE. First-appearance rather than alphabetical, so the order matches
    /// the order the search walked the library — which is recency.
    nonisolated static func grouped(
        _ moments: [Moment]
    ) -> [(title: String, moments: [Moment])] {
        var order: [String] = []
        var buckets: [String: [Moment]] = [:]
        for moment in moments {
            if buckets[moment.recordingTitle] == nil { order.append(moment.recordingTitle) }
            buckets[moment.recordingTitle, default: []].append(moment)
        }
        return order.map { (title: $0, moments: buckets[$0] ?? []) }
    }

    /// What the header says above the results.
    ///
    /// PURE. Says when the cap bit, because a list that silently stopped at 500
    /// would otherwise read as "that is everything".
    nonisolated static func summary(count: Int, capped: Bool) -> String {
        if count == 0 { return "No matches" }
        if capped { return "First \(count) moments" }
        return count == 1 ? "1 moment" : "\(count) moments"
    }
}
```

- [ ] **Step 4: Wire search into the window**

In `LibraryWindow.swift`, replace the `detail:` block:

```swift
        } detail: {
            let search = TranscriptSearch.moments(matching: store.query, in: store.recordings)
            if !search.moments.isEmpty || store.query.count >= TranscriptSearch.minimumQueryLength {
                MomentsPane(moments: search.moments, capped: search.capped) { moment in
                    // A moment lands you somewhere: select its recording, load
                    // its audio, and seek. Clearing the query then leaves you in
                    // that transcript at that position.
                    store.selection = moment.signature
                    if let recording = store.recordings.first(where: { $0.id == moment.signature }) {
                        player.load(model.libraryRoot
                            .appendingPathComponent(recording.sidecar.relativePath))
                        player.seek(to: moment.segment.start)
                        player.play()
                    }
                }
            } else if let selected = store.recordings.first(where: { $0.id == store.selection }) {
                TranscriptPane(recording: selected, player: player)
            } else {
                ContentUnavailableView("No recording selected", systemImage: "waveform")
            }
        }
```

- [ ] **Step 5: Run the tests**

Run: `swift build 2>&1 | grep -i warning; swift test --filter MomentsPane`
Expected: zero warnings, all five PASS.

- [ ] **Step 6: MUTATION-CHECK the cap message**

Change `if capped { return "First \(count) moments" }` to `if false { … }`. Run `swift test --filter theSummarySaysWhenTheCapBit`. The build must succeed and the test must FAIL. Restore. Confirm PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/StenoUI/MomentsPane.swift Sources/StenoUI/LibraryWindow.swift \
        Tests/StenoUITests/MomentsPaneTests.swift
git commit -m "feat(library): search results as playable moments

Grouped by recording in first-appearance order, each line playable where
it sits. The header says when the cap bit, because a list that silently
stopped at 500 would read as 'that is everything'."
```

---

## Task 8: RecordingEditor

**Files:**
- Create: `Sources/StenoUI/RecordingEditor.swift`
- Modify: `Sources/StenoUI/TranscriptPane.swift` (header with an Edit affordance)
- Test: `Tests/StenoUITests/RecordingEditorTests.swift`

**Interfaces:**
- Consumes: `AppModel.updateRecording(_:title:topic:)`, `RecordingEditOutcome` (Task 4), `TopicName.sanitised(_:)`.
- Produces:
  - `public struct RecordingEditor: View`
  - `RecordingEditor.topicChoices(from:) -> [String]` (nonisolated static, pure)
  - `RecordingEditor.message(for:) -> String?` (nonisolated static, pure)

- [ ] **Step 1: Write the failing tests**

Create `Tests/StenoUITests/RecordingEditorTests.swift`:

```swift
import Foundation
import Testing
@testable import StenoUI

private func withTopic(_ topic: String?, _ signature: String) -> LoadedRecording {
    LoadedRecording(
        sidecar: Sidecar(signature: signature, deviceFilename: "a.hda",
                         relativePath: "2026-08-05/\(signature).mp3", lengthBytes: 10,
                         durationSeconds: 60, recordedAt: nil,
                         syncedAt: Date(timeIntervalSince1970: 1), deviceSerial: "S",
                         deviceModel: "hidock-p1", timeZoneIdentifier: "Asia/Manila",
                         topic: topic),
        transcript: nil)
}

@Test func topicChoicesAreTheOnesAlreadyInUse() {
    let choices = RecordingEditor.topicChoices(from: [
        withTopic("Receipts", "a"), withTopic("Admin", "b"), withTopic("Receipts", "c"),
    ])

    #expect(choices == ["Admin", "Receipts"])
}

@Test func unfiledRecordingsContributeNoTopicChoice() {
    #expect(RecordingEditor.topicChoices(from: [withTopic(nil, "a")]).isEmpty)
}

/// A refused folder name has to say WHY, or the field just appears not to work.
@Test func aRefusedTopicIsExplained() throws {
    let message = try #require(RecordingEditor.message(for: .rejectedTopic("../etc")))

    #expect(message.contains("../etc"))
}

/// Busy is not an error — something else is legitimately writing this
/// recording — so it reads as "try again", not as a failure.
@Test func busySaysWhatToDoAboutIt() throws {
    let message = try #require(RecordingEditor.message(for: .busy))

    #expect(!message.isEmpty)
}

@Test func aSuccessfulSaveHasNothingToSay() {
    let sidecar = withTopic("Admin", "a").sidecar

    #expect(RecordingEditor.message(for: .updated(sidecar)) == nil)
}
```

- [ ] **Step 2: Run and watch them fail**

Run: `swift test --filter RecordingEditor`
Expected: FAIL to compile — no `RecordingEditor`.

- [ ] **Step 3: Create `RecordingEditor.swift`**

```swift
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
```

- [ ] **Step 4: Add the Edit affordance to `TranscriptPane`**

Add to `TranscriptPane`'s properties and reader header:

```swift
    let knownTopics: [String]
    @Bindable var model: AppModel
    @State private var isEditing = false
```

and above the `ScrollView` in `reader(_:)`:

```swift
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
                    RecordingEditor(recording: recording, knownTopics: knownTopics, model: model)
                }
```

A `.sheet` is correct here: this is a `Window` scene, not the `MenuBarExtra` popover whose teardown made sheets undismissable in spec 1.5.

`TranscriptPane`'s initialiser gains two parameters, so update its **one** call
site in `LibraryWindow.swift` — the `else if let selected` branch Task 7 left —
to pass `knownTopics: RecordingEditor.topicChoices(from: store.recordings)` and
`model: model`.

- [ ] **Step 5: Run the tests and the full suite**

Run: `swift build 2>&1 | grep -i warning; swift build -c release 2>&1 | grep -i warning; swift test`
Expected: zero warnings in both, everything PASS.

- [ ] **Step 6: MUTATION-CHECK the refusal message**

Change `.rejectedTopic` in `message(for:)` to return `nil`. Run `swift test --filter aRefusedTopicIsExplained`. The build must succeed and the test must FAIL. Restore. Confirm PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/StenoUI/RecordingEditor.swift Sources/StenoUI/TranscriptPane.swift \
        Sources/StenoUI/LibraryWindow.swift Tests/StenoUITests/RecordingEditorTests.swift
git commit -m "feat(library): correct a title or topic the model got wrong

Spec 2 assumed this existed. A refused folder name explains itself, and
'busy' reads as try-again rather than as a failure, because something else
writing the recording is normal."
```

---

## Task 9: Layout verification and follow-ups

**Files:**
- Test: `Tests/StenoUITests/LibraryLayoutTests.swift`
- Modify: `docs/superpowers/follow-ups.md`

- [ ] **Step 1: Write the constrained-layout tests**

The lesson from spec 2's menu bug, applied here before it can bite. Create `Tests/StenoUITests/LibraryLayoutTests.swift`:

```swift
import AppKit
import SwiftUI
import Testing
@testable import StenoUI

/// `ImageRenderer` measures a view's IDEAL layout. The spec-2 menu bug was
/// invisible at ideal size and only appeared when the container offered less
/// height than the content wanted — the rows collapsed into each other while
/// three separate measurements said the layout was fine.
///
/// So: render both, and assert on the SPACING of what is still drawn. Never on
/// how many ink bands appear — clipping and collapsing both reduce a count, and
/// a count-based test written during that fix survived its own mutation check.
@MainActor
@Test func transcriptLinesDoNotCollapseWhenTheWindowIsShort() {
    let segments = (0..<6).map {
        Segment(start: Double($0) * 10, end: Double($0) * 10 + 8,
                text: "A line of transcript number \($0)", speaker: nil)
    }
    let recording = LoadedRecording(
        sidecar: Sidecar(signature: "sig", deviceFilename: "a.hda",
                         relativePath: "2026-08-05/a.mp3", lengthBytes: 10,
                         durationSeconds: 60, recordedAt: nil,
                         syncedAt: Date(timeIntervalSince1970: 1), deviceSerial: "S",
                         deviceModel: "hidock-p1", timeZoneIdentifier: "Asia/Manila",
                         title: "Layout probe"),
        transcript: Transcript(signature: "sig", text: "x", segments: segments,
                               locale: "en_US", backend: "speechanalyzer", modelID: "m",
                               transcribedAt: Date(timeIntervalSince1970: 1),
                               audioDurationSeconds: 60))

    let pane = TranscriptPane(recording: recording, player: AudioPlayer(),
                              knownTopics: [], model: AppModel())
        .frame(width: 500)

    func minimumGap(_ view: some View) -> Double {
        let bands = inkBands(of: view)
        guard bands.count > 1 else { return 0 }
        return (1..<bands.count).map { bands[$0].top - bands[$0 - 1].bottom }.min() ?? 0
    }

    let relaxed = minimumGap(pane)
    let squeezed = minimumGap(pane.frame(height: 120))

    #expect(relaxed > 0, "the unconstrained pane should draw separated lines")
    #expect(squeezed >= relaxed - 0.5,
            Comment(rawValue: "lines sit \(squeezed)pt apart in a short window versus \(relaxed)pt relaxed — they are being squeezed together"))
}
```

- [ ] **Step 2: Run it**

Run: `swift test --filter transcriptLinesDoNotCollapseWhenTheWindowIsShort`
Expected: PASS. **If it fails, that is a real finding** — the pane compresses the same way the menu did, and the fix is `.fixedSize(horizontal: false, vertical: true)` on the line, exactly as `MenuRow` needed. Apply it, re-run, and say so in the report.

- [ ] **Step 3: Full verification**

```bash
swift build 2>&1 | grep -iE 'warning|error'
swift build -c release 2>&1 | grep -iE 'warning|error'
swift test 2>&1 | tail -3
git diff main...HEAD --stat -- Sources/JensenKit/    # must be empty
git diff main...HEAD -- Sources/StenoUI/Library.swift | grep destinationURL  # must be empty
```

- [ ] **Step 4: Build and run the real app**

```bash
./Scripts/make-app.sh release
```

Do not claim any visual behaviour. No agent here has a display — `screencapture` returns black frames. Confirm it builds and launches, then hand the visual checks to Angelo.

- [ ] **Step 5: Record what only a human can check**

Append to `docs/superpowers/follow-ups.md` under a new `## Spec 4 deferred human checks` heading: the window opening at a sensible size and the split being draggable; search returning moments and clicking one seeking correctly; following highlighting the right line and detaching on scroll; the Resume banner; editing a title and topic and seeing the note move in Finder; speaker labels appearing only on a Deepgram transcript; and a recording with no transcript showing the not-yet state.

Also record that **filing has still never run on the real library** — the sidebar's topic grouping is exercised only by fixtures until a directive is spoken or a topic is set by hand in this window.

- [ ] **Step 6: Commit**

```bash
git add Tests/StenoUITests/LibraryLayoutTests.swift docs/superpowers/follow-ups.md
git commit -m "test(library): pin transcript spacing under a short window

Renders both unconstrained and constrained, asserting on spacing rather
than band count — the shape of test that would have caught spec 2's menu
collapse, which three ideal-size measurements missed."
```

Then use `superpowers:requesting-code-review` for a whole-branch review before merging, and `superpowers:finishing-a-development-branch` to integrate.
