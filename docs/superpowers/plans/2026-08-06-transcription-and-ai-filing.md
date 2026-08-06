# Transcription and AI Filing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every synced recording gets an automatic on-device transcript, and a spoken directive inside a recording files a note into a folder of that name.

**Architecture:** A `Transcriber` protocol with two conformances — Apple's on-device `SpeechAnalyzer` (automatic default) and Deepgram Nova-3 (manual, per-recording). The canonical transcript is a `.transcript` file beside the audio; the note in a topic folder is derived and regenerable. Audio never moves, so `Library.destinationURL` stays pure and `SyncEngine`'s diff is untouched. A derived (not persisted) queue drives the work.

**Tech Stack:** Swift 6.3, SwiftUI, `Speech` (SpeechAnalyzer), `FoundationModels`, `Security` (Keychain), `URLSession`, SQLite3. Swift Testing.

**Spec:** `docs/superpowers/specs/2026-08-06-transcription-and-ai-filing-design.md`

## Global Constraints

Every task's requirements implicitly include all of these.

- **Swift 6 strict concurrency. Zero warnings in debug and release.**
- **Swift Testing only. Never XCTest.**
- **No third-party dependencies.** This has held for two specs and holds here.
- **No test may require an attached P1.** No test may write to `~/Library/Logs/Steno/`.
- **Never send `DELETE_FILE`, `SET_DEVICE_TIME`, or any Bluetooth command.** This spec touches no device code at all; `JensenKit` is not modified in any task.
- **`Sidecar.deviceModel` stays the literal string `"hidock-p1"`.** It is persisted in every sidecar on disk; changing it desyncs the library.
- **Do not restructure `SyncEngine`, `AppModel`, `Library`, `LibraryIndex`, or `DeviceMonitor`.** They shipped and they work. Extend them at existing seams.
- **Long-lived UI belongs in a `Window` scene, never inside `MenuBarExtra`.** Two defects on this project came from that.
- **No agent here has a display.** `screencapture` returns black frames. Anything visual is either measured with `ImageRenderer` or handed to the user — never claimed.
- **A test that passes by construction is worse than no test.** Tasks marked **MUTATION-CHECK** must: revert the guard, run the test, confirm it goes red, restore, confirm green.
- **Every commit message ends with the trailer** `Claude-Session: https://claude.ai/code/session_016VkgCyG9HS1vHfn1fC2kzf`. Omitted from the examples below for brevity.
- **Branch:** all work lands on `feat/transcription` cut from `main`.

## File Structure

**Created (all in `Sources/StenoUI/`)**

| File | Responsibility |
|---|---|
| `Transcript.swift` | The canonical Codable artifact + `TranscriptBody` + `Segment`. Foundation only. |
| `TranscriptStore.swift` | Reads/writes `.transcript` beside the audio. Stamps the signature. Refuses mismatches. |
| `Transcriber.swift` | The protocol and its error type. |
| `SpeechAnalyzerTranscriber.swift` | On-device backend. `import Speech`. |
| `DeepgramTranscriber.swift` | Cloud backend. `URLSession` only. |
| `TranscriberRegistry.swift` | Which backends exist, which one is selected. |
| `Keychain.swift` | `Security.framework` wrapper. Deepgram key only. |
| `DirectiveParser.swift` | PURE. Detects a filing directive and captures its tail. |
| `TopicName.swift` | PURE. Sanitises a model string into a safe folder name, or rejects it. |
| `TopicResolver.swift` | `DirectiveParser` + `FoundationModels`, degrading when unavailable. |
| `Filer.swift` | Writes the note, removes stale notes, rebuilds the topic tree. |
| `TranscriptionQueue.swift` | `actor`. Derived work list, serial execution, resumable. |

**Modified**

| File | Change |
|---|---|
| `Package.swift` | `swift-tools-version` 6.0 → 6.2; `.macOS(.v15)` → `.macOS(.v26)`. |
| `Sources/StenoUI/Sidecar.swift` | Five new optional fields. |
| `Sources/StenoUI/LibraryIndex.swift` | Schema v2: four new columns, drop-and-recreate migration. |
| `Sources/StenoUI/AppModel.swift` | WAL cleanup fix; owns the queue; exposes transcription progress. |
| `Sources/StenoUI/MenuBarView.swift` | Recent rows get a second line; progress in the notice row. |
| `Sources/StenoUI/SettingsView.swift` | New `Transcription` section. |
| `Sources/StenoCLI/CLI.swift` | New `steno transcribe <path>` subcommand. |

---

## Task 1: Platform bump and WAL cleanup

Unblocks everything (`SpeechAnalyzer` and `FoundationModels` both need macOS 26) and closes the queue-first follow-up while inside the same code.

**Files:**
- Modify: `Package.swift:1`, `Package.swift:6`
- Modify: `Sources/StenoUI/AppModel.swift:133-144`
- Test: `Tests/StenoUITests/AppModelTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `AppModel.indexSidecarURLs(for:) -> [URL]` (static, internal) — the three files an index reset must remove.

- [ ] **Step 1: Write the failing test**

Append to `Tests/StenoUITests/AppModelTests.swift`:

```swift
/// `openIndex()` deletes index.sqlite on a failed open but historically left
/// `-wal` and `-shm` behind. WAL is enabled, so a stale write-ahead log can be
/// recovered back into the fresh file, reviving the corruption the delete was
/// meant to clear.
@Test func indexResetRemovesWalAndShmAlongsideTheDatabase() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let db = dir.appendingPathComponent("index.sqlite")

    for suffix in ["", "-wal", "-shm"] {
        try Data("stale".utf8).write(to: URL(fileURLWithPath: db.path + suffix))
    }

    let urls = AppModel.indexSidecarURLs(for: db)
    for url in urls { try? FileManager.default.removeItem(at: url) }

    #expect(urls.count == 3)
    for suffix in ["", "-wal", "-shm"] {
        #expect(!FileManager.default.fileExists(atPath: db.path + suffix),
                "index.sqlite\(suffix) survived the reset")
    }
}
```

- [ ] **Step 2: Run the test and watch it fail**

Run: `swift test --filter indexResetRemovesWalAndShmAlongsideTheDatabase`
Expected: FAIL to compile — `indexSidecarURLs` is not a member of `AppModel`.

- [ ] **Step 3: Bump the platform**

`Package.swift` line 1:

```swift
// swift-tools-version: 6.2
```

`Package.swift` line 6:

```swift
    platforms: [.macOS(.v26)],
```

`swift-tools-version: 6.0` has no `.v26` case in `PackageDescription`, so both lines must move together or the manifest will not parse.

- [ ] **Step 4: Add the helper and use it**

Replace `Sources/StenoUI/AppModel.swift:133-144` with:

```swift
    /// Every file SQLite may have created for this database.
    ///
    /// WAL is enabled, so deleting only `index.sqlite` leaves a write-ahead log
    /// that can be recovered back into the fresh file — reviving exactly the
    /// corruption the delete was meant to clear.
    static func indexSidecarURLs(for db: URL) -> [URL] {
        ["", "-wal", "-shm"].map { URL(fileURLWithPath: db.path + $0) }
    }

    private func openIndex() -> LibraryIndex? {
        let url = Self.indexURL()
        if let index = try? LibraryIndex(url: url) { return index }

        for stale in Self.indexSidecarURLs(for: url) {
            try? FileManager.default.removeItem(at: stale)
        }
        do {
            return try LibraryIndex(url: url)
        } catch {
            lastError = "Recordings index is unavailable: \(error.localizedDescription)"
            return nil
        }
    }
```

- [ ] **Step 5: Run the full suite**

Run: `swift build 2>&1 | grep -i warning; swift test`
Expected: build with zero warnings, all 161 existing tests plus the new one PASS.

- [ ] **Step 6: MUTATION-CHECK**

Change `["", "-wal", "-shm"]` back to `[""]`. Run the test. It must FAIL on the `-wal` assertion. Restore it. Run again. It must PASS.

- [ ] **Step 7: Commit**

```bash
git checkout -b feat/transcription
git add Package.swift Sources/StenoUI/AppModel.swift Tests/StenoUITests/AppModelTests.swift
git commit -m "fix(index): clear -wal and -shm when resetting a corrupt index

Also moves the platform floor to macOS 26 for SpeechAnalyzer and
FoundationModels, which forces swift-tools-version to 6.2."
```

---

## Task 2: Transcript and TranscriptStore

The canonical artifact and the one safety property that matters: a transcript can never be shown against the wrong recording.

**Files:**
- Create: `Sources/StenoUI/Transcript.swift`
- Create: `Sources/StenoUI/TranscriptStore.swift`
- Test: `Tests/StenoUITests/TranscriptStoreTests.swift`

**Interfaces:**
- Consumes: `Sidecar` (existing), `Library.install(_:at:)`, `Library.encoder`, `Library.decoder` (all existing, internal to `StenoUI`).
- Produces:
  - `struct Segment: Codable, Sendable, Equatable { var start: Double; var end: Double; var text: String; var speaker: Int? }`
  - `struct TranscriptBody: Sendable, Equatable { var text: String; var segments: [Segment]; var locale: String; var backend: String; var modelID: String }`
  - `struct Transcript: Codable, Sendable, Equatable` with `init(body:sidecar:transcribedAt:)`
  - `struct TranscriptStore: Sendable` with `init(root: URL)`, `url(for: Sidecar) -> URL`, `transcript(for: Sidecar) -> Transcript?`, `has(_: Sidecar) -> Bool`, `write(_: TranscriptBody, for: Sidecar, at: Date) throws -> Transcript`, `remove(for: Sidecar)`

**Design note for the implementer:** a `Transcriber` returns a `TranscriptBody`, which carries no signature. Only `TranscriptStore.write` stamps the signature, taking it from the `Sidecar` it was handed. That makes a wrong-signature transcript structurally impossible rather than a convention someone has to remember.

- [ ] **Step 1: Write the failing tests**

Create `Tests/StenoUITests/TranscriptStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import StenoUI

private func tempRoot() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

private func sampleSidecar(
    signature: String = "c8357e00d535682319c8e19d50685d1a",
    relativePath: String = "2026-08-05/130006-c8357e00.mp3"
) -> Sidecar {
    Sidecar(signature: signature,
            deviceFilename: "2026Aug05-130006-Rec09.hda",
            relativePath: relativePath,
            lengthBytes: 47_814_924,
            durationSeconds: 3984.576,
            recordedAt: Date(timeIntervalSince1970: 1_754_370_006),
            syncedAt: Date(timeIntervalSince1970: 1_754_380_000),
            deviceSerial: "HDP1254506027",
            deviceModel: "hidock-p1",
            timeZoneIdentifier: "Asia/Manila")
}

private func sampleBody(text: String = "buy eggs and milk") -> TranscriptBody {
    TranscriptBody(text: text,
                   segments: [Segment(start: 0, end: 1.5, text: text, speaker: nil)],
                   locale: "en_PH",
                   backend: "speechanalyzer",
                   modelID: "SpeechTranscriber")
}

@Test func writtenTranscriptRoundTrips() throws {
    let root = tempRoot()
    let store = TranscriptStore(root: root)
    let sidecar = sampleSidecar()

    let written = try store.write(sampleBody(), for: sidecar, at: Date(timeIntervalSince1970: 1))
    let read = store.transcript(for: sidecar)

    #expect(read == written)
    #expect(read?.text == "buy eggs and milk")
    #expect(read?.segments.first?.speaker == nil)
}

/// The signature is stamped from the sidecar, never supplied by the backend,
/// so a transcriber cannot mislabel its own output.
@Test func writeStampsTheSidecarsSignature() throws {
    let root = tempRoot()
    let store = TranscriptStore(root: root)
    let sidecar = sampleSidecar(signature: "aaaa1111")

    let written = try store.write(sampleBody(), for: sidecar, at: Date())

    #expect(written.signature == "aaaa1111")
    #expect(written.audioDurationSeconds == 3984.576)
}

/// THE load-bearing test. A transcript sitting at the right path but carrying a
/// different recording's signature must be refused, not displayed. Paying to
/// transcribe twice beats showing someone else's meeting.
@Test func transcriptWithAMismatchedSignatureIsRefused() throws {
    let root = tempRoot()
    let store = TranscriptStore(root: root)
    let mine = sampleSidecar(signature: "mine-1111")
    let theirs = sampleSidecar(signature: "theirs-9999")

    // Write THEIR transcript, then hand the file MY sidecar at the same path.
    try store.write(sampleBody(text: "a different meeting"), for: theirs, at: Date())

    #expect(store.transcript(for: mine) == nil)
    #expect(store.has(mine) == false)
    #expect(store.has(theirs) == true)
}

@Test func transcriptExtensionIsNotJsonSoScanSidecarsIgnoresIt() {
    let audio = URL(fileURLWithPath: "/tmp/x/2026-08-05/130006-c8357e00.mp3")
    let url = TranscriptStore.url(forAudio: audio)

    #expect(url.pathExtension == "transcript")
    #expect(url.lastPathComponent == "130006-c8357e00.transcript")
}

@Test func missingOrCorruptTranscriptReadsAsNil() throws {
    let root = tempRoot()
    let store = TranscriptStore(root: root)
    let sidecar = sampleSidecar()

    #expect(store.transcript(for: sidecar) == nil)

    let url = store.url(for: sidecar)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("not json at all".utf8).write(to: url)

    #expect(store.transcript(for: sidecar) == nil)
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `swift test --filter TranscriptStore`
Expected: FAIL to compile — no `Transcript`, `TranscriptBody`, `Segment`, or `TranscriptStore`.

- [ ] **Step 3: Create `Transcript.swift`**

```swift
import Foundation

/// One span of recognised speech.
public struct Segment: Codable, Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var text: String
    /// Populated only by backends that diarize. `SpeechAnalyzer` leaves it nil.
    public var speaker: Int?

    public init(start: Double, end: Double, text: String, speaker: Int? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.speaker = speaker
    }
}

/// What a `Transcriber` produces. Carries NO signature on purpose — only
/// `TranscriptStore.write` may stamp one, and it takes it from the sidecar it
/// was handed. A backend therefore cannot mislabel its own output.
public struct TranscriptBody: Sendable, Equatable {
    public var text: String
    public var segments: [Segment]
    public var locale: String
    public var backend: String
    public var modelID: String

    public init(text: String, segments: [Segment], locale: String,
                backend: String, modelID: String) {
        self.text = text
        self.segments = segments
        self.locale = locale
        self.backend = backend
        self.modelID = modelID
    }
}

/// The canonical transcript for one recording, stored beside its audio.
///
/// Expensive to recompute in money and minutes, so unlike `index.sqlite` this
/// is NOT disposable derived state. The note in a topic folder is rendered from
/// it; this file is the thing that must survive.
public struct Transcript: Codable, Sendable, Equatable {
    /// Binds this transcript to exactly one recording. Verified on every read.
    public var signature: String
    public var text: String
    public var segments: [Segment]
    public var locale: String
    public var backend: String
    public var modelID: String
    public var transcribedAt: Date
    public var audioDurationSeconds: Double?

    public init(signature: String, text: String, segments: [Segment], locale: String,
                backend: String, modelID: String, transcribedAt: Date,
                audioDurationSeconds: Double?) {
        self.signature = signature
        self.text = text
        self.segments = segments
        self.locale = locale
        self.backend = backend
        self.modelID = modelID
        self.transcribedAt = transcribedAt
        self.audioDurationSeconds = audioDurationSeconds
    }

    init(body: TranscriptBody, sidecar: Sidecar, transcribedAt: Date) {
        self.init(signature: sidecar.signature,
                  text: body.text,
                  segments: body.segments,
                  locale: body.locale,
                  backend: body.backend,
                  modelID: body.modelID,
                  transcribedAt: transcribedAt,
                  audioDurationSeconds: sidecar.durationSeconds)
    }
}
```

- [ ] **Step 4: Create `TranscriptStore.swift`**

```swift
import Foundation

/// Reads and writes the canonical `.transcript` beside each recording.
public struct TranscriptStore: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    /// `<audio stem>.transcript`, beside the audio.
    ///
    /// Deliberately NOT `.transcript.json`. `Library.scanSidecars()` enumerates
    /// the whole root and decode-attempts everything with `pathExtension ==
    /// "json"`. A transcript is not a sidecar and must not enter that path.
    public static func url(forAudio url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("transcript")
    }

    public func url(for sidecar: Sidecar) -> URL {
        Self.url(forAudio: root.appendingPathComponent(sidecar.relativePath))
    }

    /// nil when absent, undecodable, or carrying a DIFFERENT recording's
    /// signature. Refusing beats displaying: a transcript attached to the wrong
    /// recording is worse than no transcript at all.
    public func transcript(for sidecar: Sidecar) -> Transcript? {
        guard let data = try? Data(contentsOf: url(for: sidecar)),
              let transcript = try? Library.decoder.decode(Transcript.self, from: data),
              transcript.signature == sidecar.signature
        else { return nil }
        return transcript
    }

    /// The queue's definition of "already done". Deliberately the presence of a
    /// VALID transcript file rather than `sidecar.transcribedAt`, so a crash
    /// between the transcript write and the sidecar write never re-spends money.
    public func has(_ sidecar: Sidecar) -> Bool {
        transcript(for: sidecar) != nil
    }

    /// Stamps the sidecar's signature onto the body and installs it atomically.
    @discardableResult
    public func write(_ body: TranscriptBody, for sidecar: Sidecar,
                      at transcribedAt: Date) throws -> Transcript {
        let transcript = Transcript(body: body, sidecar: sidecar, transcribedAt: transcribedAt)
        let destination = url(for: sidecar)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        let staged = destination.appendingPathExtension("part")
        try Library.encoder.encode(transcript).write(to: staged)
        do {
            try Library.install(staged, at: destination)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
        return transcript
    }

    public func remove(for sidecar: Sidecar) {
        try? FileManager.default.removeItem(at: url(for: sidecar))
    }
}
```

- [ ] **Step 5: Run the tests**

Run: `swift test --filter TranscriptStore`
Expected: all six PASS.

- [ ] **Step 6: MUTATION-CHECK the signature guard**

In `TranscriptStore.transcript(for:)`, delete the line `transcript.signature == sidecar.signature`. Run `swift test --filter transcriptWithAMismatchedSignatureIsRefused`. It must FAIL. Restore it. Run again. It must PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/StenoUI/Transcript.swift Sources/StenoUI/TranscriptStore.swift \
        Tests/StenoUITests/TranscriptStoreTests.swift
git commit -m "feat(transcript): canonical .transcript artifact, signature-verified

The store stamps the signature from the sidecar, so a backend cannot
mislabel its own output, and a transcript whose signature does not match
is refused on read rather than displayed."
```

---

## Task 3: Transcriber protocol, SpeechAnalyzer backend, and a CLI to prove it

Sequenced third on purpose. The whole spec rests on `SpeechAnalyzer` being good enough on Philippine-accented and Taglish audio, and nothing downstream is worth building until that is checked against real recordings. The CLI subcommand exists to make that check possible.

**Files:**
- Create: `Sources/StenoUI/Transcriber.swift`
- Create: `Sources/StenoUI/SpeechAnalyzerTranscriber.swift`
- Modify: `Sources/StenoCLI/CLI.swift:14`, `Sources/StenoCLI/CLI.swift:148`
- Test: `Tests/StenoUITests/TranscriberTests.swift`

**Interfaces:**
- Consumes: `TranscriptBody`, `Segment` (Task 2).
- Produces:
  - `protocol Transcriber: Sendable` with `id`, `displayName`, `isAvailable() async -> Bool`, `transcribe(audio:locale:) async throws -> TranscriptBody`
  - `enum TranscriberError: Error, Equatable`
  - `struct SpeechAnalyzerTranscriber: Transcriber` with `id == "speechanalyzer"`
  - `SpeechAnalyzerTranscriber.body(fromSegments:locale:) -> TranscriptBody` (static, internal — the pure part, and the only testable part)

- [ ] **Step 1: Read the real SDK interface before writing any `Speech` code**

`SpeechAnalyzer` shipped in macOS 26 and its exact signatures must not be guessed at. Dump the interface and read it:

```bash
ls "$(xcrun --show-sdk-path)/System/Library/Frameworks/Speech.framework/Modules/Speech.swiftmodule/"
cat "$(xcrun --show-sdk-path)/System/Library/Frameworks/Speech.framework/Modules/Speech.swiftmodule/arm64-apple-macos.swiftinterface" \
  | grep -nE "class SpeechAnalyzer|class SpeechTranscriber|func start|var results|AssetInventory|struct SpeechModule|init\(" \
  | head -60
```

Adjust Step 4's code to whatever the interface actually declares. The shape below is the expected one; the interface is the authority.

- [ ] **Step 2: Write the failing tests**

Only the pure mapping is unit-testable — the model itself is not. Create `Tests/StenoUITests/TranscriberTests.swift`:

```swift
import Foundation
import Testing
@testable import StenoUI

@Test func bodyJoinsSegmentsIntoOneTextInOrder() {
    let segments = [
        Segment(start: 0, end: 1, text: "File this under"),
        Segment(start: 1, end: 2, text: "Grocery List."),
    ]
    let body = SpeechAnalyzerTranscriber.body(fromSegments: segments, locale: "en_PH")

    #expect(body.text == "File this under Grocery List.")
    #expect(body.segments.count == 2)
    #expect(body.locale == "en_PH")
    #expect(body.backend == "speechanalyzer")
}

/// On-device does not diarize. Every speaker must be nil, or downstream code
/// will render speaker labels that were never measured.
@Test func onDeviceSegmentsCarryNoSpeaker() {
    let body = SpeechAnalyzerTranscriber.body(
        fromSegments: [Segment(start: 0, end: 1, text: "hello")], locale: "en_US")

    #expect(body.segments.allSatisfy { $0.speaker == nil })
}

@Test func emptySegmentsProduceEmptyTextNotWhitespace() {
    let body = SpeechAnalyzerTranscriber.body(fromSegments: [], locale: "en_US")

    #expect(body.text.isEmpty)
    #expect(body.segments.isEmpty)
}

@Test func transcriberIdIsStableBecauseItIsPersistedInEveryTranscript() {
    #expect(SpeechAnalyzerTranscriber().id == "speechanalyzer")
}
```

- [ ] **Step 3: Run them and watch them fail**

Run: `swift test --filter Transcriber`
Expected: FAIL to compile — no `SpeechAnalyzerTranscriber`.

- [ ] **Step 4: Create `Transcriber.swift`**

```swift
import Foundation

/// The one seam of spec 2. A new backend is a new file and a registry line,
/// never a change to the pipeline.
public protocol Transcriber: Sendable {
    /// Stable and persisted into every transcript's `backend` field. Renaming
    /// one orphans the provenance of every transcript already on disk.
    var id: String { get }
    var displayName: String { get }
    /// May be false for reasons outside the app's control: a model asset not
    /// downloaded, Apple Intelligence disabled, no API key.
    func isAvailable() async -> Bool
    func transcribe(audio: URL, locale: Locale) async throws -> TranscriptBody
}

public enum TranscriberError: Error, Equatable {
    case unavailable(String)
    case audioUnreadable(String)
    case backendFailed(String)
    case missingCredential(String)
}

extension TranscriberError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unavailable(let who):
            return "\(who) isn't available on this Mac right now."
        case .audioUnreadable(let path):
            return "Couldn't read the audio at \(path)."
        case .backendFailed(let detail):
            return "Transcription failed: \(detail)."
        case .missingCredential(let who):
            return "\(who) needs an API key. Add one in Settings."
        }
    }
}
```

- [ ] **Step 5: Create `SpeechAnalyzerTranscriber.swift`**

```swift
import AVFoundation
import Foundation
import Speech

/// On-device transcription. Free, private, no third-party dependency, and with
/// native long-form support — so unlike the cloud backends there is no upload
/// cap and no chunking. This is the ONLY backend that runs automatically.
public struct SpeechAnalyzerTranscriber: Transcriber {
    public let id = "speechanalyzer"
    public let displayName = "On-device (Apple)"

    public init() {}

    public func isAvailable() async -> Bool {
        await SpeechTranscriber.supportedLocales.isEmpty == false
    }

    public func transcribe(audio: URL, locale: Locale) async throws -> TranscriptBody {
        guard let file = try? AVAudioFile(forReading: audio) else {
            throw TranscriberError.audioUnreadable(audio.path)
        }

        let transcriber = SpeechTranscriber(locale: locale,
                                            transcriptionOptions: [],
                                            reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])

        // Model assets are downloaded on demand and are NOT bundled. On a fresh
        // Mac the first transcription blocks here on a network fetch.
        if let request = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])

        var segments: [Segment] = []
        let collector = Task {
            for try await result in transcriber.results {
                let range = result.range
                segments.append(Segment(start: range.start.seconds,
                                        end: range.end.seconds,
                                        text: String(result.text.characters),
                                        speaker: nil))
            }
        }

        do {
            try await analyzer.analyzeSequence(from: file)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            try await collector.value
        } catch {
            collector.cancel()
            throw TranscriberError.backendFailed(error.localizedDescription)
        }

        return Self.body(fromSegments: segments, locale: locale.identifier)
    }

    /// The pure part, and therefore the testable part. Kept separate from the
    /// `Speech` calls above precisely so it can be exercised without a model.
    static func body(fromSegments segments: [Segment], locale: String) -> TranscriptBody {
        TranscriptBody(
            text: segments.map(\.text).joined(separator: " "),
            segments: segments,
            locale: locale,
            backend: "speechanalyzer",
            modelID: "SpeechTranscriber")
    }
}
```

If Step 1's interface dump disagrees with any call above, follow the interface and keep `body(fromSegments:locale:)` exactly as written — the tests bind to it.

- [ ] **Step 6: Add the `transcribe` CLI subcommand**

In `Sources/StenoCLI/CLI.swift`, add before the `default` case around line 148:

```swift
        case "transcribe":
            guard args.count >= 2 else {
                print("usage: steno transcribe <path-to-audio> [locale]")
                exit(2)
            }
            let audio = URL(fileURLWithPath: args[1])
            let locale = Locale(identifier: args.count >= 3 ? args[2] : "en_US")
            let backend = SpeechAnalyzerTranscriber()

            guard await backend.isAvailable() else {
                print("on-device transcription is unavailable on this Mac")
                exit(1)
            }

            let started = Date()
            let body = try await backend.transcribe(audio: audio, locale: locale)
            let elapsed = Date().timeIntervalSince(started)

            print("backend:  \(body.backend) (\(body.modelID))")
            print("locale:   \(body.locale)")
            print("segments: \(body.segments.count)")
            print("elapsed:  \(String(format: "%.1f", elapsed))s")
            print("")
            print(body.text)
```

And extend the usage line at `CLI.swift:148`:

```swift
            print("usage: steno [probe|info|list|pull <name>|watch|transcribe <path>]")
```

- [ ] **Step 7: Run tests and build the CLI**

Run: `swift build 2>&1 | grep -i warning; swift test --filter Transcriber`
Expected: zero warnings, four tests PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/StenoUI/Transcriber.swift Sources/StenoUI/SpeechAnalyzerTranscriber.swift \
        Sources/StenoCLI/CLI.swift Tests/StenoUITests/TranscriberTests.swift
git commit -m "feat(transcribe): Transcriber protocol + on-device SpeechAnalyzer backend

Adds 'steno transcribe <path>' so on-device quality can be judged against
real recordings before anything is built on top of it."
```

---

## Task 4: HUMAN GATE — validate on-device quality

**No code.** Stop here and hand the result to Angelo. This is the single assumption that can invalidate the spec's default, and no test can settle it.

**Files:** none.

**Interfaces:**
- Consumes: `steno transcribe` (Task 3).
- Produces: a go/no-go on `SpeechAnalyzer` as the automatic backend.

- [ ] **Step 1: Transcribe the existing library**

```bash
swift build -c release
for f in ~/Recordings/Steno/*/*.mp3; do
  echo "=== $f"
  .build/release/steno transcribe "$f" en_PH
done 2>&1 | tee /tmp/steno-quality-check.txt
```

- [ ] **Step 2: Hand it over and wait**

Report to Angelo, and do not proceed without an answer:

- How many of the 11 transcribed at all, and how long each took.
- Whether Taglish and code-switched passages survived or turned to noise.
- Whether a spoken directive like *"file this under Grocery List"* comes through cleanly enough for a regex to match it. **If directives are unreliably transcribed, Tasks 7 through 10 are building on sand** and the plan needs revisiting before they start.

- [ ] **Step 3: Record the verdict**

Append the outcome to `docs/superpowers/follow-ups.md` under a new
`## Spec 2 hardware and quality checks` heading, whichever way it goes. A
negative result is more valuable recorded than a positive one.

```bash
git add docs/superpowers/follow-ups.md
git commit -m "docs: record on-device transcription quality against the real library"
```

---

## Task 5: Sidecar gains five optional fields

**Files:**
- Modify: `Sources/StenoUI/Sidecar.swift:5-19`
- Test: `Tests/StenoUITests/SidecarCompatibilityTests.swift`
- Create: `Tests/StenoUITests/Fixtures/spec1-sidecar.json`

**Interfaces:**
- Consumes: nothing.
- Produces: `Sidecar.title`, `.topic`, `.transcribedAt`, `.transcriptBackend`, `.transcriptionAttempts` — all `Optional`.

- [ ] **Step 1: Capture a real spec-1 sidecar as a fixture**

Not a synthesised one. Copy an actual file off the live library:

```bash
mkdir -p Tests/StenoUITests/Fixtures
cp "$(ls ~/Recordings/Steno/*/*.json | head -1)" Tests/StenoUITests/Fixtures/spec1-sidecar.json
cat Tests/StenoUITests/Fixtures/spec1-sidecar.json
```

Confirm by eye that it has exactly the ten spec-1 keys and none of the new ones.

- [ ] **Step 2: Register the fixture with the test target**

In `Package.swift`, change the `StenoUITests` target to carry its resources:

```swift
        .testTarget(
            name: "StenoUITests",
            dependencies: ["StenoUI", "JensenKit"],
            resources: [.copy("Fixtures")]
        ),
```

- [ ] **Step 3: Write the failing test**

Create `Tests/StenoUITests/SidecarCompatibilityTests.swift`:

```swift
import Foundation
import Testing
@testable import StenoUI

/// Every sidecar already on disk predates spec 2. If adding fields breaks their
/// decode, `scanSidecars()` silently returns fewer recordings and a rebuild
/// quietly empties the library's index.
@Test func aRealSpec1SidecarStillDecodesWithNewFieldsNil() throws {
    let url = try #require(Bundle.module.url(
        forResource: "spec1-sidecar", withExtension: "json", subdirectory: "Fixtures"))
    let data = try Data(contentsOf: url)

    let sidecar = try Library.decoder.decode(Sidecar.self, from: data)

    #expect(sidecar.deviceModel == "hidock-p1")
    #expect(!sidecar.signature.isEmpty)
    #expect(sidecar.title == nil)
    #expect(sidecar.topic == nil)
    #expect(sidecar.transcribedAt == nil)
    #expect(sidecar.transcriptBackend == nil)
    #expect(sidecar.transcriptionAttempts == nil)
}

/// Round-tripping a spec-1 sidecar must not invent values for the new fields.
@Test func reEncodingASpec1SidecarKeepsNewFieldsAbsent() throws {
    let url = try #require(Bundle.module.url(
        forResource: "spec1-sidecar", withExtension: "json", subdirectory: "Fixtures"))
    let sidecar = try Library.decoder.decode(Sidecar.self, from: Data(contentsOf: url))

    let json = String(decoding: try Library.encoder.encode(sidecar), as: UTF8.self)

    #expect(!json.contains("\"title\""))
    #expect(!json.contains("\"topic\""))
    #expect(!json.contains("\"transcriptionAttempts\""))
}
```

- [ ] **Step 4: Run and watch it fail**

Run: `swift test --filter SidecarCompatibility`
Expected: FAIL to compile — `Sidecar` has no member `title`.

- [ ] **Step 5: Add the fields**

Append inside `Sources/StenoUI/Sidecar.swift`'s struct, after `timeZoneIdentifier`:

```swift
    // MARK: - Spec 2
    //
    // All optional, so every sidecar written before spec 2 still decodes. They
    // are the DERIVED half of the record: the canonical transcript is its own
    // file, and the note in a topic folder is regenerated from these.

    /// Model-derived short title. Feeds `MenuRow`'s second line.
    public var title: String?
    /// Sanitised folder name, or nil when nothing was filed. Always the output
    /// of `TopicName.sanitised(_:)` — never a raw model string.
    public var topic: String?
    public var transcribedAt: Date?
    /// The `Transcriber.id` that produced the transcript.
    public var transcriptBackend: String?
    /// Bounds automatic retry so a permanently undecodable recording does not
    /// re-attempt on every launch forever. Manual retry ignores it.
    public var transcriptionAttempts: Int?
```

Swift's synthesised memberwise `init` would gain five parameters with no defaults, which breaks the existing call in `Library.commit:109-122`. Declare the init explicitly instead, with `nil` defaults on the new five, so every existing call site compiles untouched:

```swift
    public init(signature: String, deviceFilename: String, relativePath: String,
                lengthBytes: Int, durationSeconds: Double?, recordedAt: Date?,
                syncedAt: Date, deviceSerial: String, deviceModel: String,
                timeZoneIdentifier: String,
                title: String? = nil, topic: String? = nil,
                transcribedAt: Date? = nil, transcriptBackend: String? = nil,
                transcriptionAttempts: Int? = nil) {
        self.signature = signature
        self.deviceFilename = deviceFilename
        self.relativePath = relativePath
        self.lengthBytes = lengthBytes
        self.durationSeconds = durationSeconds
        self.recordedAt = recordedAt
        self.syncedAt = syncedAt
        self.deviceSerial = deviceSerial
        self.deviceModel = deviceModel
        self.timeZoneIdentifier = timeZoneIdentifier
        self.title = title
        self.topic = topic
        self.transcribedAt = transcribedAt
        self.transcriptBackend = transcriptBackend
        self.transcriptionAttempts = transcriptionAttempts
    }
```

- [ ] **Step 6: Run the tests**

Run: `swift build 2>&1 | grep -i warning; swift test`
Expected: zero warnings, everything PASS including all 161 pre-existing tests.

- [ ] **Step 7: MUTATION-CHECK**

Change `public var title: String?` to `public var title: String` (non-optional). Run `swift test --filter aRealSpec1SidecarStillDecodesWithNewFieldsNil`. It must FAIL to decode. Restore. Confirm PASS.

- [ ] **Step 8: Commit**

```bash
git add Package.swift Sources/StenoUI/Sidecar.swift \
        Tests/StenoUITests/SidecarCompatibilityTests.swift \
        Tests/StenoUITests/Fixtures/spec1-sidecar.json
git commit -m "feat(sidecar): add title, topic and transcript provenance

All optional and pinned by a REAL spec-1 sidecar fixture, because a
decode regression here empties the library index rather than erroring."
```

---

## Task 6: LibraryIndex schema v2

**Files:**
- Modify: `Sources/StenoUI/LibraryIndex.swift:9`, `:27-44`, `:63-100`, `:175-194`
- Test: `Tests/StenoUITests/LibraryIndexTests.swift`

**Interfaces:**
- Consumes: `Sidecar`'s new fields (Task 5).
- Produces: `recordings` table at `user_version = 2` with `title`, `topic`, `transcribed_at`, `transcript_backend` appended after `timezone`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/StenoUITests/LibraryIndexTests.swift`:

```swift
/// `migrate()` only ever ran CREATE TABLE IF NOT EXISTS, so it cannot add a
/// column to a table that already exists. A v1 database must be dropped and
/// recreated — which is safe precisely because the index is derived.
@Test func aV1DatabaseIsRecreatedAtV2() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("index.sqlite")

    // Genuine pre-migration schema, built OUTSIDE LibraryIndex so it really
    // lacks the four spec-2 columns.
    //
    // Going through LibraryIndex(url:schemaVersionOverride:) does NOT work
    // here: migrate(to:) has exactly one CREATE TABLE and it already includes
    // the new columns, so that path produces a full v2 table and merely stamps
    // a lower user_version. The migration would then have nothing real to do,
    // the DROP would destroy the row just inserted, and the final assertions
    // would be checking data the test itself had written one line earlier.
    var raw: OpaquePointer?
    #expect(sqlite3_open(url.path, &raw) == SQLITE_OK)
    #expect(sqlite3_exec(raw, """
        CREATE TABLE recordings (
            signature TEXT PRIMARY KEY,
            device_filename TEXT NOT NULL,
            relative_path TEXT NOT NULL,
            length_bytes INTEGER NOT NULL,
            duration_seconds REAL,
            recorded_at REAL,
            synced_at REAL NOT NULL,
            device_serial TEXT NOT NULL,
            device_model TEXT NOT NULL,
            timezone TEXT NOT NULL
        );
        PRAGMA user_version = 1;
        """, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(raw)

    // Reopening at v2 must not throw on the missing columns.
    let v2 = try LibraryIndex(url: url)
    let refilled = indexSampleSidecar(title: "Grocery list", topic: "Grocery List")
    try v2.upsert(refilled)

    #expect(v2.record(signature: refilled.signature)?.title == "Grocery list")
    #expect(v2.record(signature: refilled.signature)?.topic == "Grocery List")
}

@Test func titleAndTopicSurviveARoundTrip() throws {
    let index = try LibraryIndex(url: freshIndexURL())
    let sidecar = indexSampleSidecar(title: "Tuesday supplier call",
                                     topic: "Grocery List",
                                     backend: "speechanalyzer")
    try index.upsert(sidecar)

    let read = try #require(index.record(signature: sidecar.signature))
    #expect(read.title == "Tuesday supplier call")
    #expect(read.topic == "Grocery List")
    #expect(read.transcriptBackend == "speechanalyzer")
    #expect(read.transcriptionAttempts == nil)   // not an indexed column
}

/// `decode(_:)` reads columns BY POSITION from `SELECT *`. A new column
/// inserted rather than appended shifts every field after it, silently. This
/// test is the only thing standing between that mistake and a corrupted menu.
@Test func columnOrderMatchesTheDecoderPositions() throws {
    let index = try LibraryIndex(url: freshIndexURL())
    let sidecar = indexSampleSidecar(title: "T", topic: "P", backend: "B")
    try index.upsert(sidecar)

    let read = try #require(index.record(signature: sidecar.signature))
    #expect(read.signature == sidecar.signature)
    #expect(read.deviceFilename == sidecar.deviceFilename)
    #expect(read.relativePath == sidecar.relativePath)
    #expect(read.lengthBytes == sidecar.lengthBytes)
    #expect(read.deviceSerial == sidecar.deviceSerial)
    #expect(read.deviceModel == "hidock-p1")
    #expect(read.timeZoneIdentifier == sidecar.timeZoneIdentifier)
    #expect(read.title == "T")
    #expect(read.topic == "P")
    #expect(read.transcribedAt == sidecar.transcribedAt)
    #expect(read.transcriptBackend == "B")
}
```

Add these helpers at the top of the same file if they do not already exist. Note `freshIndexURL()` returns a real file in a temp directory — **not** `:memory:`, which as a `fileURLWithPath` becomes the literal path `/:memory:` and creates a file at the filesystem root rather than an in-memory database.

```swift
private func freshIndexURL() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("index.sqlite")
}

private func indexSampleSidecar(
    title: String? = nil, topic: String? = nil, backend: String? = nil
) -> Sidecar {
    Sidecar(signature: "c8357e00d535682319c8e19d50685d1a",
            deviceFilename: "2026Aug05-130006-Rec09.hda",
            relativePath: "2026-08-05/130006-c8357e00.mp3",
            lengthBytes: 47_814_924,
            durationSeconds: 3984.576,
            recordedAt: Date(timeIntervalSince1970: 1_754_370_006),
            syncedAt: Date(timeIntervalSince1970: 1_754_380_000),
            deviceSerial: "HDP1254506027",
            deviceModel: "hidock-p1",
            timeZoneIdentifier: "Asia/Manila",
            title: title,
            topic: topic,
            transcribedAt: title == nil ? nil : Date(timeIntervalSince1970: 1_754_390_000),
            transcriptBackend: backend,
            transcriptionAttempts: nil)
}
```

- [ ] **Step 2: Run and watch them fail**

Run: `swift test --filter LibraryIndex`
Expected: FAIL — no `schemaVersionOverride`, and `title` is not a column.

- [ ] **Step 3: Bump the schema and add the drop-and-recreate migration**

In `Sources/StenoUI/LibraryIndex.swift`, replace line 9 and the `init`/`migrate` pair:

```swift
    private static let schemaVersion = 2

    public convenience init(url: URL) throws {
        try self.init(url: url, schemaVersionOverride: Self.schemaVersion)
    }

    /// `schemaVersionOverride` exists only so tests can build a v1 database and
    /// prove the migration. Production always goes through `init(url:)`.
    init(url: URL, schemaVersionOverride: Int) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            sqlite3_close(db)
            throw LibraryIndexError.cannotOpen(url.path)
        }
        try execute("PRAGMA journal_mode=WAL;")
        try migrate(to: schemaVersionOverride)
    }

    /// The index is a DERIVED cache, so a schema change does not need an ALTER
    /// path. Dropping and recreating is correct and total; `AppModel` calls
    /// `rebuildIndex()` afterwards and the sidecars refill it.
    private func migrate(to version: Int) throws {
        if currentUserVersion() < version {
            try execute("DROP TABLE IF EXISTS recordings;")
        }
        try execute("""
            CREATE TABLE IF NOT EXISTS recordings (
                signature TEXT PRIMARY KEY,
                device_filename TEXT NOT NULL,
                relative_path TEXT NOT NULL,
                length_bytes INTEGER NOT NULL,
                duration_seconds REAL,
                recorded_at REAL,
                synced_at REAL NOT NULL,
                device_serial TEXT NOT NULL,
                device_model TEXT NOT NULL,
                timezone TEXT NOT NULL,
                title TEXT,
                topic TEXT,
                transcribed_at REAL,
                transcript_backend TEXT
            );
            """)
        try execute("CREATE INDEX IF NOT EXISTS idx_recorded_at ON recordings(recorded_at DESC);")
        try execute("PRAGMA user_version = \(version);")
    }

    private func currentUserVersion() -> Int {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK
        else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }
```

**New columns are APPENDED after `timezone`, never inserted.** `decode(_:)` reads by position.

- [ ] **Step 4: Extend `upsertLocked` and `decode`**

In `upsertLocked`, extend the SQL to fourteen columns and fourteen placeholders, add the four `excluded.` clauses, then bind after index 10:

```swift
        if let t = s.title { sqlite3_bind_text(stmt, 11, t, -1, Self.transient) } else { sqlite3_bind_null(stmt, 11) }
        if let t = s.topic { sqlite3_bind_text(stmt, 12, t, -1, Self.transient) } else { sqlite3_bind_null(stmt, 12) }
        if let d = s.transcribedAt { sqlite3_bind_double(stmt, 13, d.timeIntervalSince1970) } else { sqlite3_bind_null(stmt, 13) }
        if let b = s.transcriptBackend { sqlite3_bind_text(stmt, 14, b, -1, Self.transient) } else { sqlite3_bind_null(stmt, 14) }
```

In `decode(_:)`, add an `optionalText` helper beside the existing ones and four trailing arguments:

```swift
        func optionalText(_ i: Int32) -> String? {
            guard sqlite3_column_type(stmt, i) != SQLITE_NULL,
                  let c = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: c)
        }
```

```swift
            timeZoneIdentifier: text(9),
            title: optionalText(10),
            topic: optionalText(11),
            transcribedAt: optionalDouble(12).map(Date.init(timeIntervalSince1970:)),
            transcriptBackend: optionalText(13),
            transcriptionAttempts: nil)
```

`transcriptionAttempts` is deliberately not an indexed column — it is queue bookkeeping and nothing reading the index needs it. It lives in the sidecar only.

- [ ] **Step 5: Run the tests**

Run: `swift build 2>&1 | grep -i warning; swift test --filter LibraryIndex`
Expected: zero warnings, all PASS.

- [ ] **Step 6: MUTATION-CHECK the column-position test**

In the `CREATE TABLE`, move `title TEXT,` so it sits before `timezone TEXT NOT NULL,` instead of after. Run `swift test --filter columnOrderMatchesTheDecoderPositions`. It must FAIL. Restore. Confirm PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/StenoUI/LibraryIndex.swift Tests/StenoUITests/LibraryIndexTests.swift
git commit -m "feat(index): schema v2 with title, topic and transcript provenance

Drop-and-recreate rather than an ALTER path, because the index is derived
and rebuildIndex() refills it from sidecars."
```

---

## Task 7: DirectiveParser

Pure. No I/O, no model. Its job is **not** to extract the topic — it is to decide whether a directive was spoken at all, so a recording that merely mentions groceries is never filed under Grocery List.

**Files:**
- Create: `Sources/StenoUI/DirectiveParser.swift`
- Test: `Tests/StenoUITests/DirectiveParserTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct Directive: Sendable, Equatable { let matchedPhrase: String; let capturedTail: String }`
  - `enum DirectiveParser { static func parse(_ text: String) -> Directive? }`

- [ ] **Step 1: Write the failing tests**

Create `Tests/StenoUITests/DirectiveParserTests.swift`:

```swift
import Foundation
import Testing
@testable import StenoUI

@Test(arguments: [
    "File this under Grocery List.",
    "file this under grocery list",
    "Okay, so, file this under Grocery List. Anyway,",
    "File this in Grocery List.",
    "Save this to Grocery List.",
    "Save this in Grocery List.",
    "Save this under Grocery List!",
])
func recognisedPhrasingsYieldADirective(_ text: String) {
    #expect(DirectiveParser.parse(text) != nil, "no directive found in: \(text)")
}

/// The last four are VERBATIM from Angelo's real recordings, captured during
/// the Task 4 quality gate. Scanning 3 hours of real speech produced 12
/// directive-shaped phrases and zero genuine directives — and the plan's
/// original `put (this|that|it) (under|into)` pattern matched two of them,
/// deep inside client calls. Filing a client call under an invented topic is
/// the exact failure the prefilter exists to prevent, so `put` and `stick`
/// were dropped entirely. Do not re-add them to make a phrasing work.
@Test(arguments: [
    "",
    "I need to buy groceries later.",
    "The grocery list is on the fridge.",
    "We filed the paperwork under the wrong client.",
    "Filing this under Taxes.",
    "Put this in the car when you get home.",
    "take that credit card string, put it into the payment method",
    "I reconstitute it and I put it into a sprayer",
    "we could have it testable by next week and then put it live August 14th",
    "the doctor just sent me a PDF, so I'm going to save this one",
])
func ordinarySpeechYieldsNoDirective(_ text: String) {
    #expect(DirectiveParser.parse(text) == nil, "false positive on: \(text)")
}

@Test func theTailIsCapturedForUseWhenNoModelIsAvailable() {
    let directive = DirectiveParser.parse("File this under Grocery List. Then we talked.")

    #expect(directive?.capturedTail == "Grocery List")
}

/// Directives are spoken, so they arrive without punctuation as often as with.
@Test func anUnpunctuatedDirectiveStillCapturesToEndOfLine() {
    let directive = DirectiveParser.parse("file this under grocery list")

    #expect(directive?.capturedTail == "grocery list")
}

/// The first directive wins. A recording that changes its mind is ambiguous,
/// and filing it twice is worse than filing it once.
@Test func onlyTheFirstDirectiveIsReturned() {
    let directive = DirectiveParser.parse(
        "File this under Groceries. Actually, file this under Receipts.")

    #expect(directive?.capturedTail == "Groceries")
}

@Test func aDirectiveWithNothingAfterItIsNotADirective() {
    #expect(DirectiveParser.parse("File this under.") == nil)
    #expect(DirectiveParser.parse("File this under   ") == nil)
}
```

- [ ] **Step 2: Run and watch them fail**

Run: `swift test --filter DirectiveParser`
Expected: FAIL to compile — no `DirectiveParser`.

- [ ] **Step 3: Implement it**

Create `Sources/StenoUI/DirectiveParser.swift`:

```swift
import Foundation

public struct Directive: Sendable, Equatable {
    /// The phrase that matched, kept for the diagnostic log.
    public let matchedPhrase: String
    /// Everything between the phrase and the next sentence end. Used verbatim
    /// as the topic ONLY when `FoundationModels` is unavailable.
    public let capturedTail: String
}

/// Decides whether a filing directive was spoken. Deliberately NOT the thing
/// that decides the folder name.
///
/// This is the guard that stops a recording which merely mentions groceries
/// from being filed under Grocery List. The model downstream is free to
/// interpret; it is not free to invent an instruction that was never given.
public enum DirectiveParser {
    /// EXPLICIT SPOKEN FILING VERBS ONLY. `put`, `stick`, and `filing` are all
    /// deliberately absent.
    ///
    /// `filing this under X` was dropped for a different reason than the other
    /// two: not because it false-positived, but because nobody narrates it out
    /// loud. It is a written register. An unexercised pattern is a
    /// false-positive surface with no offsetting benefit, so it went.
    ///
    /// They were in this list until the Task 4 quality gate ran it against 3
    /// hours of real recordings, where `put (this|that|it) into` matched
    /// "put it into the payment method" and "put it into a sprayer" — both
    /// buried in real client calls, both of which would have filed that call
    /// under a topic nobody asked for. Twelve directive-shaped phrases turned
    /// up in that corpus and not one was a real directive.
    ///
    /// The prefilter's entire value is in what it REFUSES. Recall is the
    /// cheap side of this trade: an unfiled recording is visible and fixed by
    /// editing one sidecar field, while a misfiled client call is the failure
    /// the whole design was built to avoid. If a phrasing you use is missed,
    /// change the phrasing before widening the grammar.
    private static let patterns = [
        #"\bfile\s+(?:this|that|it)\s+under\s+(.+)"#,
        #"\bfile\s+(?:this|that|it)\s+(?:in|to|into)\s+(.+)"#,
        #"\bsave\s+(?:this|that|it)\s+(?:under|in|to|into)\s+(.+)"#,
    ]

    public static func parse(_ text: String) -> Directive? {
        var best: (range: Range<String.Index>, tail: String, phrase: String)?

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(
                pattern: pattern, options: [.caseInsensitive]) else { continue }
            let full = NSRange(text.startIndex..., in: text)
            guard let match = regex.firstMatch(in: text, options: [], range: full),
                  let matchRange = Range(match.range, in: text),
                  let tailRange = Range(match.range(at: 1), in: text) else { continue }

            let tail = trimToSentence(String(text[tailRange]))
            guard !tail.isEmpty else { continue }

            // Earliest directive in the recording wins.
            if best == nil || matchRange.lowerBound < best!.range.lowerBound {
                best = (matchRange, tail, String(text[matchRange]))
            }
        }

        guard let best else { return nil }
        return Directive(matchedPhrase: best.phrase, capturedTail: best.tail)
    }

    /// Spoken directives arrive with punctuation as often as without, so stop at
    /// the first sentence end if there is one and take the whole tail if not.
    private static func trimToSentence(_ tail: String) -> String {
        let stop = tail.firstIndex { ".!?\n".contains($0) }
        let head = stop.map { String(tail[tail.startIndex..<$0]) } ?? tail
        return head.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter DirectiveParser`
Expected: all PASS.

If a negative case fails, **do not widen or loosen a pattern to make it go away** — the negative set is the point of this type, and four of its entries are verbatim sentences from real recordings that a looser grammar already misfiled once. Fix the pattern that over-matched instead.

- [ ] **Step 5: Commit**

```bash
git add Sources/StenoUI/DirectiveParser.swift Tests/StenoUITests/DirectiveParserTests.swift
git commit -m "feat(filing): DirectiveParser grants permission to file

It detects that a directive was spoken; it does not choose the folder.
That split is what stops a recording mentioning groceries from being
filed under Grocery List."
```

---

## Task 8: TopicName

Pure, and the one real security surface in this spec: a model-generated string becomes a filesystem path. It **rejects rather than repairs**.

**Files:**
- Create: `Sources/StenoUI/TopicName.swift`
- Test: `Tests/StenoUITests/TopicNameTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `enum TopicName { static func sanitised(_ raw: String) -> String? }`

- [ ] **Step 1: Write the failing tests**

Create `Tests/StenoUITests/TopicNameTests.swift`:

```swift
import Foundation
import Testing
@testable import StenoUI

@Test(arguments: [
    "../../etc",
    "..",
    ".",
    "Grocery/List",
    "Grocery\\List",
    "Old:Name",
    "/absolute",
    ".hidden",
    ".incoming",
    "",
    "    ",
    "\n\t",
    "2026-08-05",
    "1999-01-31",
    "undated",
    "UNDATED",
])
func hostileOrCollidingNamesAreRejected(_ raw: String) {
    #expect(TopicName.sanitised(raw) == nil, "should have been rejected: \(raw)")
}

@Test func controlCharactersAreRejectedNotStripped() {
    #expect(TopicName.sanitised("Grocery\u{0}List") == nil)
    #expect(TopicName.sanitised("Grocery\u{7}List") == nil)
}

@Test func overlongNamesAreRejectedNotTruncated() {
    #expect(TopicName.sanitised(String(repeating: "a", count: 61)) == nil)
    #expect(TopicName.sanitised(String(repeating: "a", count: 60)) != nil)
}

@Test(arguments: [
    ("Grocery List", "Grocery List"),
    ("  Grocery List  ", "Grocery List"),
    ("grocery list", "grocery list"),
    ("Client Calls 2026", "Client Calls 2026"),
    ("Q3 Planning", "Q3 Planning"),
])
func ordinaryNamesPassThroughWithOnlyWhitespaceTrimmed(_ pair: (String, String)) {
    #expect(TopicName.sanitised(pair.0) == pair.1)
}

/// A date-shaped name would sit beside the library's own dated folders and be
/// indistinguishable from one. `undated` and `.incoming` are Library's too.
@Test func rejectionProtectsTheLibrarysOwnLayout() {
    #expect(TopicName.sanitised("2026-08-05") == nil)
    #expect(TopicName.sanitised("2026-8-5") != nil)   // not the library's format
}
```

- [ ] **Step 2: Run and watch them fail**

Run: `swift test --filter TopicName`
Expected: FAIL to compile.

- [ ] **Step 3: Implement it**

Create `Sources/StenoUI/TopicName.swift`:

```swift
import Foundation

/// Turns a model-generated string into a folder name, or refuses.
///
/// This is the only place in spec 2 where untrusted text becomes a filesystem
/// path, so it REJECTS rather than repairs. Repairing invites the class of bug
/// where `../../etc` quietly becomes `etc` and lands somewhere surprising;
/// refusing means the recording is simply not filed, which is a failure the
/// user can see and correct.
public enum TopicName {
    private static let maxLength = 60

    /// Names the library already owns. A topic folder sits at the library root
    /// beside these, so a collision is indistinguishable from the real thing.
    private static let reserved: Set<String> = ["undated", ".incoming"]

    public static func sanitised(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty,
              trimmed.count <= maxLength,
              !trimmed.hasPrefix("."),
              !trimmed.contains("/"),
              !trimmed.contains("\\"),
              !trimmed.contains(":"),
              trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              !reserved.contains(trimmed.lowercased()),
              !isDateShaped(trimmed)
        else { return nil }

        return trimmed
    }

    /// `Library.destinationURL` writes `yyyy-MM-dd` folders at the same level.
    private static func isDateShaped(_ name: String) -> Bool {
        name.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter TopicName`
Expected: all PASS.

- [ ] **Step 5: MUTATION-CHECK the traversal guard**

Delete `!trimmed.contains("/")` from the guard. Run `swift test --filter hostileOrCollidingNamesAreRejected`. It must FAIL on `Grocery/List` and `/absolute` — and **not** on `../../etc`, which `hasPrefix(".")` rejects independently, so the slash guard is not what defends it. That two-guard overlap is deliberate: a defect in either one alone still leaves traversal blocked.

Then restore and confirm PASS.

Repeat for the colon guard, which has no second line of defence: delete `!trimmed.contains(":")`, confirm the failure is `Old:Name` and only `Old:Name`, restore, confirm PASS. On macOS a colon is the legacy HFS path separator and Finder still renders it as `/`, so it is a real separator-smuggling route rather than cosmetic validation.

- [ ] **Step 6: Commit**

```bash
git add Sources/StenoUI/TopicName.swift Tests/StenoUITests/TopicNameTests.swift
git commit -m "feat(filing): TopicName rejects unsafe folder names rather than repairing

Model output becomes a filesystem path here, so traversal, hidden names,
control characters, and collisions with the library's own dated folders
are all refused. An unfiled recording beats a wrongly filed one."
```

---

## Task 9: TopicResolver

Produces a title for every transcript and a topic only when `DirectiveParser` granted permission. Degrades to the regex capture when Apple Intelligence is unavailable.

**Files:**
- Create: `Sources/StenoUI/TopicResolver.swift`
- Test: `Tests/StenoUITests/TopicResolverTests.swift`

**Interfaces:**
- Consumes: `DirectiveParser.parse(_:)` (Task 7), `TopicName.sanitised(_:)` (Task 8), `Transcript` (Task 2).
- Produces:
  - `struct Filing: Sendable, Equatable { let title: String; let topic: String? }`
  - `protocol FilingSuggester: Sendable { func suggest(from text: String, directive: Directive?) async -> Filing? }`
  - `struct TopicResolver: Sendable` with `init(suggester: FilingSuggester?)` and `func resolve(_ transcript: Transcript) async -> Filing`
  - `struct OnDeviceSuggester: FilingSuggester` (wraps `FoundationModels`)
  - `TopicResolver.fallbackTitle(from:) -> String` (static, internal)

- [ ] **Step 1: Read the FoundationModels interface before writing against it**

```bash
cat "$(xcrun --show-sdk-path)/System/Library/Frameworks/FoundationModels.framework/Modules/FoundationModels.swiftmodule/arm64-apple-macos.swiftinterface" \
  | grep -nE "LanguageModelSession|SystemLanguageModel|availability|func respond|macro Generable|macro Guide" \
  | head -40
```

Adjust Step 3's `OnDeviceSuggester` to match. The protocol boundary above exists so the rest of the task is testable regardless.

- [ ] **Step 2: Write the failing tests**

Create `Tests/StenoUITests/TopicResolverTests.swift`:

```swift
import Foundation
import Testing
@testable import StenoUI

private struct StubSuggester: FilingSuggester {
    var filing: Filing?
    func suggest(from text: String, directive: Directive?) async -> Filing? { filing }
}

private func transcript(_ text: String) -> Transcript {
    Transcript(signature: "sig", text: text, segments: [], locale: "en_PH",
               backend: "speechanalyzer", modelID: "SpeechTranscriber",
               transcribedAt: Date(timeIntervalSince1970: 0), audioDurationSeconds: 60)
}

/// THE guard. Even when the model returns a confident topic, no directive in
/// the audio means no filing. The model may interpret; it may not invent an
/// instruction that was never given.
@Test func aModelTopicIsDiscardedWhenNoDirectiveWasSpoken() async {
    let suggester = StubSuggester(filing: Filing(title: "Shopping", topic: "Grocery List"))
    let resolver = TopicResolver(suggester: suggester)

    let filing = await resolver.resolve(transcript("I should buy groceries later."))

    #expect(filing.topic == nil)
    #expect(filing.title == "Shopping")
}

@Test func aModelTopicIsKeptWhenADirectiveWasSpoken() async {
    let suggester = StubSuggester(filing: Filing(title: "Shopping", topic: "Grocery List"))
    let resolver = TopicResolver(suggester: suggester)

    let filing = await resolver.resolve(transcript("File this under Grocery List."))

    #expect(filing.topic == "Grocery List")
}

/// Model output is untrusted text on its way to becoming a path.
@Test func anUnsafeModelTopicIsRejectedEvenWithADirective() async {
    let suggester = StubSuggester(filing: Filing(title: "T", topic: "../../etc"))
    let resolver = TopicResolver(suggester: suggester)

    let filing = await resolver.resolve(transcript("File this under whatever."))

    #expect(filing.topic == nil)
}

/// Apple Intelligence off, or unsupported hardware. Filing still works, just
/// more literally.
@Test func withNoSuggesterTheRegexCaptureBecomesTheTopic() async {
    let resolver = TopicResolver(suggester: nil)

    let filing = await resolver.resolve(transcript("File this under Grocery List. Then we talked."))

    #expect(filing.topic == "Grocery List")
}

@Test func withNoSuggesterTheTitleFallsBackToOpeningWords() async {
    let resolver = TopicResolver(suggester: nil)

    let filing = await resolver.resolve(
        transcript("Right so the supplier called about the delayed shipment and we agreed to push"))

    #expect(filing.title == "Right so the supplier called about the delayed shipment")
}

@Test func fallbackTitleIsCappedAtEightWords() {
    let title = TopicResolver.fallbackTitle(from: "one two three four five six seven eight nine ten")

    #expect(title == "one two three four five six seven eight")
}

@Test func anEmptyTranscriptStillProducesAUsableTitle() async {
    let resolver = TopicResolver(suggester: nil)

    let filing = await resolver.resolve(transcript(""))

    #expect(filing.title == "Untitled recording")
    #expect(filing.topic == nil)
}
```

- [ ] **Step 3: Implement it**

Create `Sources/StenoUI/TopicResolver.swift`:

```swift
import Foundation
import FoundationModels

public struct Filing: Sendable, Equatable {
    public let title: String
    public let topic: String?

    public init(title: String, topic: String?) {
        self.title = title
        self.topic = topic
    }
}

/// The model boundary, extracted so `TopicResolver`'s gating logic is testable
/// without Apple Intelligence being available on the machine running the tests.
public protocol FilingSuggester: Sendable {
    /// Takes the `Directive` itself, not a `directiveWasSpoken` flag.
    ///
    /// The flag version had a hole. `directiveWasSpoken` is computed from the
    /// FULL transcript, but the model only receives head+tail — so for a
    /// directive spoken mid-recording the gate opened while the model never saw
    /// the instruction, invented a topic from the surrounding small talk, and
    /// that invented topic then won. Passing the directive lets the suggester
    /// put the real spoken instruction in front of the model.
    func suggest(from text: String, directive: Directive?) async -> Filing?
}

/// Turns a transcript into a title and, only when permitted, a topic.
public struct TopicResolver: Sendable {
    private let suggester: FilingSuggester?

    /// `nil` means no on-device model — Apple Intelligence disabled or
    /// unsupported hardware. Everything still works, just more literally.
    public init(suggester: FilingSuggester?) {
        self.suggester = suggester
    }

    public func resolve(_ transcript: Transcript) async -> Filing {
        let directive = DirectiveParser.parse(transcript.text)
        let suggestion = await suggester?.suggest(from: transcript.text,
                                                  directive: directive)

        let title = suggestion?.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = (title?.isEmpty == false)
            ? title!
            : Self.fallbackTitle(from: transcript.text)

        // The regex GRANTS PERMISSION. Without a directive there is no topic,
        // no matter how confident the model was.
        guard let directive else {
            return Filing(title: resolvedTitle, topic: nil)
        }

        let candidate = suggestion?.topic ?? directive.capturedTail
        return Filing(title: resolvedTitle, topic: TopicName.sanitised(candidate))
    }

    /// Used when there is no model, and when the model returns a blank title.
    static func fallbackTitle(from text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace).prefix(8)
        guard !words.isEmpty else { return "Untitled recording" }
        return words.joined(separator: " ")
    }
}

/// `FoundationModels` wrapper. Returns nil rather than throwing so an
/// unavailable model degrades instead of failing the whole pipeline.
public struct OnDeviceSuggester: FilingSuggester {
    public init?() {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
    }

    @Generable
    struct Suggestion {
        @Guide(description: "A short descriptive title for this recording, at most 8 words. No quotes.")
        var title: String
        @Guide(description: "The exact folder name the speaker asked this to be filed under. Empty string if they did not ask.")
        var topic: String
    }

    public func suggest(from text: String, directive: Directive?) async -> Filing? {
        // Head and tail only — a 66-minute transcript is ~55,000 characters and
        // will not fit the context window. The directive is appended separately
        // so a mid-recording instruction is never invisible to the model.
        let excerpt = Self.excerpt(of: text, directive: directive)
        let session = LanguageModelSession(instructions: """
            You label voice recordings. Produce a short title. If, and only if, \
            the speaker explicitly asked for this to be filed somewhere, put \
            that exact folder name in topic. Otherwise leave topic empty.
            """)

        guard let response = try? await session.respond(
            to: excerpt, generating: Suggestion.self) else { return nil }

        let topic = response.content.topic.trimmingCharacters(in: .whitespacesAndNewlines)
        return Filing(title: response.content.title,
                      topic: (directive != nil && !topic.isEmpty) ? topic : nil)
    }

    /// Head + tail, plus the spoken instruction when there was one.
    ///
    /// Appending the directive is what stops the model choosing a topic while
    /// being denied the only evidence that matters. Without it, a directive at
    /// minute 30 of a 40-minute call falls outside both edges and the model
    /// answers from small talk it happens to be able to see.
    static func excerpt(of text: String, directive: Directive? = nil,
                        edge: Int = 1_500) -> String {
        var body = text
        if text.count > edge * 2 {
            body = String(text.prefix(edge)) + "\n…\n" + String(text.suffix(edge))
        }
        guard let directive else { return body }
        return body + "\n\nSpoken instruction: " + directive.matchedPhrase
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift build 2>&1 | grep -i warning; swift test --filter TopicResolver`
Expected: zero warnings, all PASS.

- [ ] **Step 5: MUTATION-CHECK the permission gate**

Replace `guard let directive else { return Filing(title: resolvedTitle, topic: nil) }` with `let directive = directive ?? Directive(matchedPhrase: "", capturedTail: "")`. Run `swift test --filter aModelTopicIsDiscardedWhenNoDirectiveWasSpoken`. It must FAIL. Restore. Confirm PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/StenoUI/TopicResolver.swift Tests/StenoUITests/TopicResolverTests.swift
git commit -m "feat(filing): TopicResolver titles every transcript, topics only on request

The regex grants permission and the model interprets. A confident model
topic with no spoken directive is discarded, and any topic at all still
has to survive TopicName."
```

---

## Task 10: Filer

Writes the note, keeps it idempotent, and regenerates the whole topic tree from sidecars.

**Files:**
- Create: `Sources/StenoUI/Filer.swift`
- Test: `Tests/StenoUITests/FilerTests.swift`

**Interfaces:**
- Consumes: `Sidecar` (Task 5), `Transcript`/`TranscriptStore` (Task 2), `TopicName` (Task 8).
- Produces: `struct Filer: Sendable` with `init(root: URL)`, `noteURL(for:topic:) -> URL`, `write(for:transcript:) throws -> URL`, `removeNote(for:topic:)`, `rebuild(from:store:) throws`

- [ ] **Step 1: Write the failing tests**

Create `Tests/StenoUITests/FilerTests.swift`:

```swift
import Foundation
import Testing
@testable import StenoUI

private func tempRoot() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

private func filed(
    signature: String = "c8357e00d535682319c8e19d50685d1a",
    title: String = "Grocery list and the supplier call",
    topic: String? = "Grocery List"
) -> Sidecar {
    Sidecar(signature: signature,
            deviceFilename: "2026Aug05-130006-Rec09.hda",
            relativePath: "2026-08-05/130006-c8357e00.mp3",
            lengthBytes: 47_814_924,
            durationSeconds: 3984.576,
            recordedAt: Date(timeIntervalSince1970: 1_754_370_006),
            syncedAt: Date(timeIntervalSince1970: 1_754_380_000),
            deviceSerial: "HDP1254506027",
            deviceModel: "hidock-p1",
            timeZoneIdentifier: "Asia/Manila",
            title: title, topic: topic,
            transcribedAt: Date(timeIntervalSince1970: 1_754_390_000),
            transcriptBackend: "speechanalyzer",
            transcriptionAttempts: nil)
}

private func sampleTranscript(_ signature: String = "c8357e00d535682319c8e19d50685d1a") -> Transcript {
    Transcript(signature: signature, text: "buy eggs and milk", segments: [],
               locale: "en_PH", backend: "speechanalyzer", modelID: "SpeechTranscriber",
               transcribedAt: Date(timeIntervalSince1970: 1_754_390_000),
               audioDurationSeconds: 3984.576)
}

@Test func theNoteLandsInATopicFolderAtTheLibraryRoot() throws {
    let root = tempRoot()
    let filer = Filer(root: root)
    let sidecar = filed()

    let url = try filer.write(for: sidecar, transcript: sampleTranscript())

    #expect(url.deletingLastPathComponent().lastPathComponent == "Grocery List")
    #expect(url.deletingLastPathComponent().deletingLastPathComponent().path == root.path)
    #expect(url.pathExtension == "md")
    #expect(FileManager.default.fileExists(atPath: url.path))
}

@Test func theNoteCarriesFrontMatterBindingItToTheRecording() throws {
    let root = tempRoot()
    let url = try Filer(root: root).write(for: filed(), transcript: sampleTranscript())
    let text = try String(contentsOf: url, encoding: .utf8)

    #expect(text.hasPrefix("---\n"))
    #expect(text.contains("signature: c8357e00d535682319c8e19d50685d1a"))
    #expect(text.contains("audio: ../2026-08-05/130006-c8357e00.mp3"))
    #expect(text.contains("backend: speechanalyzer"))
    #expect(text.contains("buy eggs and milk"))
}

/// Writing twice must not produce two notes. The front-matter signature is what
/// makes the write idempotent.
@Test func rewritingTheSameRecordingOverwritesRatherThanDuplicates() throws {
    let root = tempRoot()
    let filer = Filer(root: root)

    let first = try filer.write(for: filed(), transcript: sampleTranscript())
    let second = try filer.write(for: filed(), transcript: sampleTranscript())

    #expect(first == second)
    let contents = try FileManager.default.contentsOfDirectory(
        atPath: root.appendingPathComponent("Grocery List").path)
    #expect(contents.count == 1)
}

/// Two recordings, same title, same minute. The incumbent must survive — the
/// audio path learned this expensively and the note path inherits it.
@Test func aDifferentRecordingAtTheSamePathGetsASignatureSuffix() throws {
    let root = tempRoot()
    let filer = Filer(root: root)
    let mine = filed(signature: "aaaa1111aaaa")
    let theirs = filed(signature: "bbbb2222bbbb")

    let first = try filer.write(for: mine, transcript: sampleTranscript("aaaa1111aaaa"))
    let second = try filer.write(for: theirs, transcript: sampleTranscript("bbbb2222bbbb"))

    #expect(first != second)
    #expect(second.lastPathComponent.contains("bbbb2222"))
    #expect(FileManager.default.fileExists(atPath: first.path))
}

@Test func changingTopicRemovesTheNoteAtTheOldLocation() throws {
    let root = tempRoot()
    let filer = Filer(root: root)
    let old = filed(topic: "Groceries")
    let new = filed(topic: "Receipts")

    let oldURL = try filer.write(for: old, transcript: sampleTranscript())
    filer.removeNote(for: old, topic: "Groceries")
    _ = try filer.write(for: new, transcript: sampleTranscript())

    #expect(!FileManager.default.fileExists(atPath: oldURL.path))
    #expect(FileManager.default.fileExists(
        atPath: root.appendingPathComponent("Receipts").path))
}

/// The topic tree is DERIVED. Deleting it and rebuilding must give back exactly
/// what was there, which is what makes "Rebuild Topic Folders" a button rather
/// than a recovery operation.
@Test func rebuildFromSidecarsReproducesTheTreeExactly() throws {
    let root = tempRoot()
    let filer = Filer(root: root)
    let store = TranscriptStore(root: root)
    let sidecars = [filed(signature: "aaaa1111", topic: "Groceries"),
                    filed(signature: "bbbb2222", topic: "Receipts"),
                    filed(signature: "cccc3333", topic: nil)]
    for s in sidecars { try store.write(
        TranscriptBody(text: "x", segments: [], locale: "en_PH",
                       backend: "speechanalyzer", modelID: "m"), for: s, at: Date()) }

    try filer.rebuild(from: sidecars, store: store)
    let before = try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted()

    try filer.rebuild(from: sidecars, store: store)
    let after = try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted()

    #expect(before == after)
    #expect(FileManager.default.fileExists(
        atPath: root.appendingPathComponent("Groceries").path))
    #expect(FileManager.default.fileExists(
        atPath: root.appendingPathComponent("Receipts").path))
    // The third sidecar carries no topic, so it must contribute no folder.
    let topLevel = try FileManager.default.contentsOfDirectory(atPath: root.path)
    #expect(Set(topLevel).intersection(["Groceries", "Receipts"]).count == 2)
    #expect(topLevel.filter { !$0.hasPrefix("2026-") }.count == 2)
}

@Test func aSidecarWithNoTopicProducesNoNote() throws {
    let root = tempRoot()
    let unfiled = filed(topic: nil)

    #expect(throws: Never.self) {
        try Filer(root: root).rebuild(from: [unfiled], store: TranscriptStore(root: root))
    }
    let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
    #expect(entries.isEmpty)
}
```

- [ ] **Step 2: Run and watch them fail**

Run: `swift test --filter Filer`
Expected: FAIL to compile — no `Filer`.

- [ ] **Step 3: Implement it**

Create `Sources/StenoUI/Filer.swift`:

```swift
import Foundation

/// Writes and regenerates the notes in topic folders.
///
/// Everything this type produces is DERIVED. Delete the whole tree and
/// `rebuild(from:store:)` puts it back from sidecars plus transcripts, exactly
/// as `rebuildIndex()` does for `index.sqlite`. Nothing here is canonical, which
/// is precisely why an AI-guessed topic is allowed to drive it.
public struct Filer: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    /// `<root>/<Topic>/<YYYY-MM-DD HHmm> <title>.md`
    public func noteURL(for sidecar: Sidecar, topic: String) -> URL {
        root.appendingPathComponent(topic)
            .appendingPathComponent(Self.noteStem(for: sidecar) + ".md")
    }

    @discardableResult
    public func write(for owner: Sidecar, transcript: Transcript) throws -> URL {
        guard let topic = owner.topic.flatMap(TopicName.sanitised) else {
            throw FilerError.noTopic(owner.signature)
        }
        let folder = root.appendingPathComponent(topic)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var destination = noteURL(for: owner, topic: topic)

        // Idempotent by signature. Same recording -> overwrite. DIFFERENT
        // recording at the same path -> the newcomer moves aside rather than
        // destroying the incumbent. `Library` learned this the expensive way:
        // the signature prefix is not decoration.
        if let existing = try? String(contentsOf: destination, encoding: .utf8),
           !existing.contains("signature: \(owner.signature)") {
            let stem = Self.noteStem(for: owner) + " " + String(owner.signature.prefix(8))
            destination = folder.appendingPathComponent(stem + ".md")
        }

        try Self.render(sidecar: owner, transcript: transcript)
            .write(to: destination, atomically: true, encoding: .utf8)
        return destination
    }

    public func removeNote(for sidecar: Sidecar, topic: String) {
        try? FileManager.default.removeItem(at: noteURL(for: sidecar, topic: topic))
        // Leave the folder even if now empty: the user may have put things in it.
    }

    /// Removes every topic folder this type owns and regenerates them.
    ///
    /// A folder is "owned" when its name matches some sidecar's topic. Anything
    /// else at the root is left alone — dated folders, `.incoming`, and whatever
    /// the user put there.
    public func rebuild(from sidecars: [Sidecar], store: TranscriptStore) throws {
        let topics = Set(sidecars.compactMap { $0.topic.flatMap(TopicName.sanitised) })
        for topic in topics {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(topic))
        }
        for sidecar in sidecars {
            guard sidecar.topic.flatMap(TopicName.sanitised) != nil,
                  let transcript = store.transcript(for: sidecar) else { continue }
            try write(for: sidecar, transcript: transcript)
        }
    }

    static func noteStem(for sidecar: Sidecar) -> String {
        let stamp = sidecar.recordedAt.map(Self.stampFormatter.string(from:)) ?? "undated"
        let title = (sidecar.title ?? "Untitled recording")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(stamp) \(title.isEmpty ? "Untitled recording" : title)"
    }

    /// `signature` in the front matter is what makes writing idempotent — it is
    /// how a rewrite tells "this is my note" from "this is someone else's".
    static func render(sidecar: Sidecar, transcript: Transcript) -> String {
        let recorded = sidecar.recordedAt.map(Library.iso8601.string(from:)) ?? ""
        return """
            ---
            signature: \(sidecar.signature)
            recordedAt: \(recorded)
            audio: ../\(sidecar.relativePath)
            backend: \(transcript.backend)
            ---

            # \(sidecar.title ?? "Untitled recording")

            \(transcript.text)

            """
    }

    // en_US_POSIX for the same reason `Library` uses it: under a non-Gregorian
    // Locale.current the folder layout would become locale-dependent.
    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd HHmm"
        return f
    }()
}

public enum FilerError: Error, Equatable {
    case noTopic(String)
}
```

Add to `Library`, beside the existing `encoder` and `decoder` — it already owns the date handling, so the formatter belongs there rather than as a second copy in `Filer`:

```swift
    static let iso8601 = ISO8601DateFormatter()
```

- [ ] **Step 4: Run the tests**

Run: `swift build 2>&1 | grep -i warning; swift test --filter Filer`
Expected: zero warnings, all PASS.

- [ ] **Step 5: MUTATION-CHECK the collision guard**

Delete the `if let existing = ...` block so writes always go to the base path. Run `swift test --filter aDifferentRecordingAtTheSamePathGetsASignatureSuffix`. It must FAIL. Restore. Confirm PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/StenoUI/Filer.swift Sources/StenoUI/Library.swift \
        Tests/StenoUITests/FilerTests.swift
git commit -m "feat(filing): Filer writes regenerable notes into topic folders

Front-matter signature makes rewriting idempotent and stops two
same-minute recordings from overwriting each other, the same lesson the
audio path already paid for."
```

---

## Task 11: TranscriptionQueue

The money-protection task. Serial, derived rather than persisted, and provably never paying twice.

**Files:**
- Create: `Sources/StenoUI/TranscriptionQueue.swift`
- Test: `Tests/StenoUITests/TranscriptionQueueTests.swift`

**Interfaces:**
- Consumes: `Transcriber` (Task 3), `TranscriptStore` (Task 2), `TopicResolver` (Task 9), `Filer` (Task 10), `Sidecar` (Task 5).
- Produces:
  - `actor TranscriptionQueue` with `init(root:store:filer:resolver:transcriber:maxAttempts:)`
  - `func pending(from: [Sidecar]) -> [Sidecar]`
  - `func process(_ sidecar: Sidecar) async -> Sidecar` (returns the updated sidecar; caller persists it)
  - `struct QueueProgress: Sendable, Equatable { let done: Int; let total: Int }`

- [ ] **Step 1: Write the failing tests**

Create `Tests/StenoUITests/TranscriptionQueueTests.swift`:

```swift
import Foundation
import Testing
@testable import StenoUI

private actor CallCounter {
    private(set) var count = 0
    func bump() { count += 1 }
}

private struct CountingTranscriber: Transcriber {
    let id = "counting"
    let displayName = "Counting"
    let counter: CallCounter
    var failing = false

    func isAvailable() async -> Bool { true }

    func transcribe(audio: URL, locale: Locale) async throws -> TranscriptBody {
        await counter.bump()
        if failing { throw TranscriberError.backendFailed("nope") }
        return TranscriptBody(text: "File this under Grocery List. Buy eggs.",
                              segments: [], locale: "en_PH",
                              backend: "counting", modelID: "counting-1")
    }
}

private func tempRoot() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

private func queueSidecar(signature: String = "sig-1") -> Sidecar {
    Sidecar(signature: signature, deviceFilename: "a.hda",
            relativePath: "2026-08-05/130006-\(signature).mp3",
            lengthBytes: 10, durationSeconds: 60,
            recordedAt: Date(timeIntervalSince1970: 1_754_370_006),
            syncedAt: Date(timeIntervalSince1970: 1_754_380_000),
            deviceSerial: "S", deviceModel: "hidock-p1", timeZoneIdentifier: "Asia/Manila")
}

private func makeQueue(root: URL, transcriber: Transcriber) -> TranscriptionQueue {
    TranscriptionQueue(root: root,
                       store: TranscriptStore(root: root),
                       filer: Filer(root: root),
                       resolver: TopicResolver(suggester: nil),
                       transcriber: transcriber,
                       maxAttempts: 3)
}

/// THE money test. Transcription is the expensive step, so the already-done
/// check is the presence of a valid transcript file — NOT sidecar.transcribedAt.
/// A crash after the transcript write must never re-spend.
@Test func aSecondPassNeverRetranscribes() async throws {
    let root = tempRoot()
    let counter = CallCounter()
    let queue = makeQueue(root: root, transcriber: CountingTranscriber(counter: counter))
    let sidecar = queueSidecar()

    _ = await queue.process(sidecar)
    // Simulate the crash window: the transcript landed but the sidecar update
    // never did, so the caller still holds the ORIGINAL sidecar.
    _ = await queue.process(sidecar)

    #expect(await counter.count == 1)
}

@Test func pendingSkipsAnythingThatAlreadyHasAValidTranscript() async throws {
    let root = tempRoot()
    let counter = CallCounter()
    let queue = makeQueue(root: root, transcriber: CountingTranscriber(counter: counter))
    let done = queueSidecar(signature: "done")
    let todo = queueSidecar(signature: "todo")

    _ = await queue.process(done)

    let pending = await queue.pending(from: [done, todo])
    #expect(pending.map(\.signature) == ["todo"])
}

@Test func processingWritesTranscriptSidecarFieldsAndNote() async throws {
    let root = tempRoot()
    let queue = makeQueue(root: root, transcriber: CountingTranscriber(counter: CallCounter()))

    let updated = await queue.process(queueSidecar())

    #expect(updated.transcribedAt != nil)
    #expect(updated.transcriptBackend == "counting")
    #expect(updated.topic == "Grocery List")
    #expect(updated.title?.isEmpty == false)
    #expect(FileManager.default.fileExists(
        atPath: root.appendingPathComponent("Grocery List").path))
}

/// A permanently undecodable recording must stop being retried, or it re-spends
/// on every launch forever.
@Test func repeatedFailuresStopBeingRetriedAtTheCap() async throws {
    let root = tempRoot()
    let counter = CallCounter()
    let queue = makeQueue(root: root,
                          transcriber: CountingTranscriber(counter: counter, failing: true))
    var sidecar = queueSidecar()

    for _ in 0..<5 { sidecar = await queue.process(sidecar) }

    #expect(sidecar.transcriptionAttempts == 3)
    #expect(await counter.count == 3)
    #expect(await queue.pending(from: [sidecar]).isEmpty)
}

@Test func aFailedRecordingKeepsItsAudioAndSidecar() async throws {
    let root = tempRoot()
    let queue = makeQueue(root: root,
                          transcriber: CountingTranscriber(counter: CallCounter(), failing: true))
    let original = queueSidecar()

    let after = await queue.process(original)

    #expect(after.signature == original.signature)
    #expect(after.relativePath == original.relativePath)
    #expect(after.transcribedAt == nil)
}
```

- [ ] **Step 2: Run and watch them fail**

Run: `swift test --filter TranscriptionQueue`
Expected: FAIL to compile — no `TranscriptionQueue`.

- [ ] **Step 3: Implement it**

Create `Sources/StenoUI/TranscriptionQueue.swift`:

```swift
import Foundation

public struct QueueProgress: Sendable, Equatable {
    public let done: Int
    public let total: Int
}

/// Serialised transcription and filing.
///
/// The work list is DERIVED, never persisted. "What needs transcribing" is
/// computed by asking `TranscriptStore` what lacks a valid transcript, so there
/// is no job file to go stale or corrupt — the same reasoning that makes
/// `index.sqlite` disposable.
public actor TranscriptionQueue {
    /// PINNED, not `Locale.current`.
    ///
    /// `en_PH` is not a supported `SpeechTranscriber` locale, and
    /// `supportedLocale(equivalentTo:)` resolved it to a DIFFERENT English
    /// variant on each run during the Task 4 gate — `en_AU`, `en_US`, and
    /// `en_SG` were all observed. That makes both the acoustic model and the
    /// `locale` recorded in every transcript vary run to run, which is not
    /// something a provenance field is allowed to do. Explicit locales resolve
    /// to themselves, so pinning removes the non-determinism outright.
    /// Variants agreed 94–99.7% on real audio, so the pin costs almost nothing.
    public static let locale = Locale(identifier: "en_US")

    private let root: URL
    private let store: TranscriptStore
    private let filer: Filer
    private let resolver: TopicResolver
    private let transcriber: any Transcriber
    private let maxAttempts: Int

    public init(root: URL, store: TranscriptStore, filer: Filer,
                resolver: TopicResolver, transcriber: any Transcriber,
                maxAttempts: Int = 3) {
        self.root = root
        self.store = store
        self.filer = filer
        self.resolver = resolver
        self.transcriber = transcriber
        self.maxAttempts = maxAttempts
    }

    /// Everything still owed work, cheapest check first.
    public func pending(from sidecars: [Sidecar]) -> [Sidecar] {
        sidecars.filter { sidecar in
            guard !store.has(sidecar) else { return false }
            return (sidecar.transcriptionAttempts ?? 0) < maxAttempts
        }
    }

    /// Transcribes, files, and returns the updated sidecar. The CALLER persists
    /// it and updates the index — this actor owns no `Library`.
    ///
    /// Write order is the inverse of `Library.commit`'s. There the expensive
    /// thing is the download, so audio goes first. Here it is transcription, and
    /// the already-done check is the transcript FILE, so a crash between steps
    /// only ever repeats free work.
    public func process(_ sidecar: Sidecar) async -> Sidecar {
        var updated = sidecar

        // 1. Transcript — skipped entirely when one already exists.
        let transcript: Transcript
        if let existing = store.transcript(for: sidecar) {
            transcript = existing
        } else {
            let audio = root.appendingPathComponent(sidecar.relativePath)
            do {
                let body = try await transcriber.transcribe(
                    audio: audio, locale: Self.locale)
                transcript = try store.write(body, for: sidecar, at: Date())
            } catch {
                updated.transcriptionAttempts = (sidecar.transcriptionAttempts ?? 0) + 1
                return updated
            }
        }

        // 2. Sidecar fields.
        let filing = await resolver.resolve(transcript)
        let previousTopic = sidecar.topic
        updated.title = filing.title
        updated.topic = filing.topic
        updated.transcribedAt = transcript.transcribedAt
        updated.transcriptBackend = transcript.backend
        updated.transcriptionAttempts = nil

        // 3. Note. Regenerable, so a failure here is not worth failing the run.
        if let previousTopic, previousTopic != filing.topic {
            filer.removeNote(for: sidecar, topic: previousTopic)
        }
        if filing.topic != nil {
            try? filer.write(for: updated, transcript: transcript)
        }

        return updated
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift build 2>&1 | grep -i warning; swift test --filter TranscriptionQueue`
Expected: zero warnings, all six PASS.

- [ ] **Step 5: MUTATION-CHECK the never-pay-twice guard**

Replace `if let existing = store.transcript(for: sidecar)` with `if false, let existing = store.transcript(for: sidecar)`. Run `swift test --filter aSecondPassNeverRetranscribes`. It must FAIL with a count of 2. Restore. Confirm PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/StenoUI/TranscriptionQueue.swift Tests/StenoUITests/TranscriptionQueueTests.swift
git commit -m "feat(queue): serial, derived transcription queue that never pays twice

The already-done check is the transcript file, not a sidecar field, so a
crash between the transcript write and the sidecar write repeats only
free work. Bounded retry stops a bad recording re-spending forever."
```

---

## Task 12: Keychain and the Deepgram backend

**Files:**
- Create: `Sources/StenoUI/Keychain.swift`
- Create: `Sources/StenoUI/DeepgramTranscriber.swift`
- Create: `Tests/StenoUITests/Fixtures/deepgram-response.json`
- Test: `Tests/StenoUITests/DeepgramTranscriberTests.swift`

**Interfaces:**
- Consumes: `Transcriber`, `TranscriptBody`, `Segment`.
- Produces:
  - `enum Keychain { static func string(for: String) -> String?; static func set(_:for:) throws; static func remove(_:) }`
  - `struct DeepgramTranscriber: Transcriber` with `id == "deepgram"`
  - `DeepgramTranscriber.request(for:apiKey:) throws -> URLRequest` (static, internal)
  - `DeepgramTranscriber.body(fromResponse:locale:) throws -> TranscriptBody` (static, internal)

- [ ] **Step 1: Capture the response fixture by hand**

Once, with a real key and a short recording. **Never in a test.**

```bash
curl -sS -X POST "https://api.deepgram.com/v1/listen?model=nova-3&diarize=true&punctuate=true&utterances=true" \
  -H "Authorization: Token $DEEPGRAM_KEY" \
  -H "Content-Type: audio/mpeg" \
  --data-binary @"$(ls ~/Recordings/Steno/*/*.mp3 | head -1)" \
  -o Tests/StenoUITests/Fixtures/deepgram-response.json
python3 -m json.tool Tests/StenoUITests/Fixtures/deepgram-response.json | head -40
```

If no key exists yet, hand-write a minimal fixture matching the documented shape (`results.utterances[]` with `start`, `end`, `transcript`, `speaker`) and mark it in `follow-ups.md` as needing replacement with a real capture.

- [ ] **Step 2: Write the failing tests**

Create `Tests/StenoUITests/DeepgramTranscriberTests.swift`:

```swift
import Foundation
import Testing
@testable import StenoUI

@Test func requestCarriesTheKeyAsATokenHeaderAndNeverInTheURL() throws {
    let request = try DeepgramTranscriber.request(
        for: URL(fileURLWithPath: "/tmp/a.mp3"), apiKey: "secret-key")

    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Token secret-key")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "audio/mpeg")
    #expect(request.url?.absoluteString.contains("secret-key") == false)
    #expect(request.url?.absoluteString.contains("diarize=true") == true)
    #expect(request.url?.absoluteString.contains("model=nova-3") == true)
}

@Test func anEmptyKeyIsRefusedBeforeAnyNetworkCall() {
    #expect(throws: TranscriberError.missingCredential("Deepgram")) {
        try DeepgramTranscriber.request(for: URL(fileURLWithPath: "/tmp/a.mp3"), apiKey: "")
    }
}

@Test func responseParsesIntoSegmentsWithSpeakers() throws {
    let url = try #require(Bundle.module.url(
        forResource: "deepgram-response", withExtension: "json", subdirectory: "Fixtures"))
    let body = try DeepgramTranscriber.body(
        fromResponse: Data(contentsOf: url), locale: "en_PH")

    #expect(body.backend == "deepgram")
    #expect(body.modelID == "nova-3")
    #expect(!body.text.isEmpty)
    #expect(!body.segments.isEmpty)
    #expect(body.segments.contains { $0.speaker != nil },
            "diarization requested but no speaker came back")
}

@Test func malformedResponseThrowsRatherThanReturningEmptyText() {
    #expect(throws: (any Error).self) {
        try DeepgramTranscriber.body(fromResponse: Data("{}".utf8), locale: "en_PH")
    }
}

@Test func transcriberIdIsStableBecauseItIsPersistedInEveryTranscript() {
    #expect(DeepgramTranscriber().id == "deepgram")
}
```

- [ ] **Step 3: Create `Keychain.swift`**

```swift
import Foundation
import Security

/// The Deepgram API key. `UserDefaults` is readable by anything running as the
/// user and ends up in backups in plain text; a credential does not belong there.
public enum Keychain {
    private static let service = "com.jiggsfoo.steno"

    public static func string(for account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    public static func set(_ value: String, for account: String) throws {
        remove(account)
        guard !value.isEmpty else { return }
        var query = baseQuery(account: account)
        query[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.writeFailed(status) }
    }

    public static func remove(_ account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}

public enum KeychainError: Error, Equatable {
    case writeFailed(OSStatus)
}
```

- [ ] **Step 4: Create `DeepgramTranscriber.swift`**

```swift
import Foundation

/// Cloud transcription, run only on explicit request for one recording.
///
/// Chosen over Whisper-family APIs because it adds a CAPABILITY rather than
/// accuracy: speaker diarization, which no on-device option provides. It also
/// accepts hour-long files directly, so there is no 25 MB cap to chunk around.
public struct DeepgramTranscriber: Transcriber {
    public static let keychainAccount = "deepgram-api-key"

    public let id = "deepgram"
    public let displayName = "Deepgram Nova-3 (cloud)"

    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func isAvailable() async -> Bool {
        Keychain.string(for: Self.keychainAccount) != nil
    }

    public func transcribe(audio: URL, locale: Locale) async throws -> TranscriptBody {
        guard let key = Keychain.string(for: Self.keychainAccount) else {
            throw TranscriberError.missingCredential("Deepgram")
        }
        guard let file = try? Data(contentsOf: audio) else {
            throw TranscriberError.audioUnreadable(audio.path)
        }

        let request = try Self.request(for: audio, apiKey: key)
        let (data, response) = try await session.upload(for: request, from: file)

        guard let http = response as? HTTPURLResponse else {
            throw TranscriberError.backendFailed("no HTTP response")
        }
        guard http.statusCode == 200 else {
            throw TranscriberError.backendFailed("HTTP \(http.statusCode)")
        }

        return try Self.body(fromResponse: data, locale: locale.identifier)
    }

    /// The key travels in the Authorization header, never the URL — query
    /// strings end up in logs and proxies.
    static func request(for audio: URL, apiKey: String) throws -> URLRequest {
        guard !apiKey.isEmpty else {
            throw TranscriberError.missingCredential("Deepgram")
        }
        var components = URLComponents(string: "https://api.deepgram.com/v1/listen")!
        components.queryItems = [
            URLQueryItem(name: "model", value: "nova-3"),
            URLQueryItem(name: "diarize", value: "true"),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "utterances", value: "true"),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Content-Type")
        return request
    }

    /// Throws rather than returning empty text: a silently blank transcript
    /// would be written to disk and treated as done, and re-running it costs
    /// money the user already spent.
    static func body(fromResponse data: Data, locale: String) throws -> TranscriptBody {
        struct Response: Decodable {
            struct Results: Decodable {
                struct Utterance: Decodable {
                    let start: Double
                    let end: Double
                    let transcript: String
                    let speaker: Int?
                }
                let utterances: [Utterance]?
            }
            let results: Results
        }

        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard let utterances = decoded.results.utterances, !utterances.isEmpty else {
            throw TranscriberError.backendFailed("no utterances in response")
        }

        let segments = utterances.map {
            Segment(start: $0.start, end: $0.end, text: $0.transcript, speaker: $0.speaker)
        }
        return TranscriptBody(text: segments.map(\.text).joined(separator: " "),
                              segments: segments,
                              locale: locale,
                              backend: "deepgram",
                              modelID: "nova-3")
    }
}
```

- [ ] **Step 5: Run the tests**

Run: `swift build 2>&1 | grep -i warning; swift test --filter Deepgram`
Expected: zero warnings, all PASS. **No network traffic** — confirm with Little Snitch or by running with Wi-Fi off.

- [ ] **Step 6: Commit**

```bash
git add Sources/StenoUI/Keychain.swift Sources/StenoUI/DeepgramTranscriber.swift \
        Tests/StenoUITests/DeepgramTranscriberTests.swift \
        Tests/StenoUITests/Fixtures/deepgram-response.json
git commit -m "feat(transcribe): Deepgram Nova-3 backend with Keychain-stored key

Chosen for diarization, which no on-device backend offers, and for
accepting hour-long files so no chunking is needed. Tests parse a
captured fixture and never touch the network."
```

---

## Task 13: Wire the queue into AppModel and the menu

**Files:**
- Modify: `Sources/StenoUI/AppModel.swift` (new stored properties, `startTranscription()`, call site after sync and in `start()`)
- Modify: `Sources/StenoUI/MenuBarView.swift:169-174` (recent rows), `:127` area (notice row)
- Create: `Sources/StenoUI/TranscriberRegistry.swift`
- Test: `Tests/StenoUITests/MenuBarViewTests.swift`, `Tests/StenoUITests/TranscriberRegistryTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 2, 3, 9, 10, 11, 12.
- Produces:
  - `enum TranscriberRegistry { static let selectionKey: String; static func all() -> [any Transcriber]; static func automatic() -> any Transcriber; static func selected() -> any Transcriber }`
  - `AppModel.transcriptionProgress: QueueProgress?`
  - `AppModel.startTranscription()`
  - `AppModel.retranscribe(_ sidecar: Sidecar, using: any Transcriber)`
  - `MenuBarView.transcriptionLabel(for: QueueProgress?) -> String?` (static, pure, testable)

- [ ] **Step 1: Write the failing tests**

Create `Tests/StenoUITests/TranscriberRegistryTests.swift`:

```swift
import Foundation
import Testing
@testable import StenoUI

/// The automatic backend must be the free one. A cloud backend running
/// unattended would bill on every 66-minute meeting without being asked.
@Test func theAutomaticBackendIsAlwaysOnDevice() {
    #expect(TranscriberRegistry.automatic().id == "speechanalyzer")
}

@Test func bothBackendsAreRegistered() {
    #expect(Set(TranscriberRegistry.all().map(\.id)) == ["speechanalyzer", "deepgram"])
}
```

Append to `Tests/StenoUITests/MenuBarViewTests.swift`:

```swift
@Test func transcriptionLabelReadsAsProgressWhileWorking() {
    #expect(MenuBarView.transcriptionLabel(for: QueueProgress(done: 2, total: 11))
            == "Transcribing 3 of 11")
}

@Test func transcriptionLabelIsAbsentWhenIdleOrFinished() {
    #expect(MenuBarView.transcriptionLabel(for: nil) == nil)
    #expect(MenuBarView.transcriptionLabel(for: QueueProgress(done: 11, total: 11)) == nil)
}

@Test func transcriptionLabelHandlesAnEmptyQueueWithoutDividingByZero() {
    #expect(MenuBarView.transcriptionLabel(for: QueueProgress(done: 0, total: 0)) == nil)
}
```

- [ ] **Step 2: Run and watch them fail**

Run: `swift test --filter "TranscriberRegistry or transcriptionLabel"`
Expected: FAIL to compile.

- [ ] **Step 3: Create `TranscriberRegistry.swift`**

```swift
import Foundation

/// Which backends exist and which one the user picked.
public enum TranscriberRegistry {
    public static let selectionKey = "transcriberID"

    public static func all() -> [any Transcriber] {
        [SpeechAnalyzerTranscriber(), DeepgramTranscriber()]
    }

    /// The backend that runs UNATTENDED after every sync. Always on-device,
    /// and not user-overridable: automatic transcription only stays honest
    /// while it is free. Cloud is a deliberate per-recording action.
    public static func automatic() -> any Transcriber {
        SpeechAnalyzerTranscriber()
    }

    /// The backend chosen in Settings, used for explicit re-transcription.
    public static func selected() -> any Transcriber {
        let id = UserDefaults.standard.string(forKey: selectionKey)
        return all().first { $0.id == id } ?? automatic()
    }
}
```

- [ ] **Step 4: Add the pure label helper to `MenuBarView`**

```swift
    /// Pure, and therefore the testable part. `done` is a completed count, so
    /// the item being worked on is `done + 1`.
    static func transcriptionLabel(for progress: QueueProgress?) -> String? {
        guard let progress, progress.total > 0, progress.done < progress.total else { return nil }
        return "Transcribing \(progress.done + 1) of \(progress.total)"
    }
```

- [ ] **Step 5: Show the title on recent rows**

Replace `Sources/StenoUI/MenuBarView.swift:169-174`:

```swift
            ForEach(model.recent, id: \.signature) { item in
                MenuRow(Self.dateLabel(item.recordedAt),
                        value: Self.durationLabel(item.durationSeconds),
                        // The second line spec 1.5 added `detail` for. Absent
                        // until the queue has been through this recording.
                        detail: item.title,
                        detailLineLimit: 1) {
                    reveal(item)
                }
            }
```

And render the progress line beside the existing notice row:

```swift
        if let label = Self.transcriptionLabel(for: model.transcriptionProgress) {
            MenuRow("", accent: .notice, detail: label, detailLineLimit: 1)
        }
```

- [ ] **Step 6: Wire the queue into `AppModel`**

Add stored properties beside the existing ones and two methods. Do **not** restructure anything already there.

`AppModel` is already `@MainActor @Observable`, so a plain `Task { }` written inside it **inherits main-actor isolation** — every property write below is already on the main actor and `MainActor.run` would be redundant. What does need pushing off the main actor is the slow work: `scanSidecars()` enumerates and JSON-decodes the whole library, and `updateSidecar` writes a file. Both go behind `Task.detached`. Transcription itself already suspends inside the queue actor. Capturing `self` strongly matches the existing code, whose class comment explains why a `weak self` capture is the thing the region checker cannot prove safe here.

```swift
    /// nil when nothing is queued. Drives the menu's progress line.
    public var transcriptionProgress: QueueProgress?

    private var transcriptionTask: Task<Void, Never>?

    /// Transcribes everything that lacks a transcript, one at a time.
    ///
    /// The work list is recomputed from sidecars each run rather than stored, so
    /// there is nothing to resume and nothing to corrupt. Safe to call at launch,
    /// after every sync, and repeatedly — `pending` filters out finished work.
    public func startTranscription() {
        guard transcriptionTask == nil else { return }
        let root = libraryRoot
        let library = Library(root: root)
        let queue = TranscriptionQueue(
            root: root,
            store: TranscriptStore(root: root),
            filer: Filer(root: root),
            resolver: TopicResolver(suggester: OnDeviceSuggester()),
            transcriber: TranscriberRegistry.automatic())

        transcriptionTask = Task {
            defer {
                self.transcriptionTask = nil
                self.transcriptionProgress = nil
            }

            let all = await Task.detached { (try? library.scanSidecars()) ?? [] }.value
            let todo = await queue.pending(from: all)
            guard !todo.isEmpty else { return }

            for (offset, sidecar) in todo.enumerated() {
                if Task.isCancelled { return }
                self.transcriptionProgress = QueueProgress(done: offset, total: todo.count)

                let updated = await queue.process(sidecar)
                await Task.detached { try? library.updateSidecar(updated) }.value

                try? self.index?.upsert(updated)
                self.reloadRecent()
            }
        }
    }

    /// Explicit, one recording, one backend. The ONLY path by which audio leaves
    /// this machine.
    public func retranscribe(_ sidecar: Sidecar, using transcriber: any Transcriber) {
        let root = libraryRoot
        let store = TranscriptStore(root: root)
        store.remove(for: sidecar)          // force a fresh run
        var fresh = sidecar
        fresh.transcriptionAttempts = nil
        let library = Library(root: root)

        Task {
            let queue = TranscriptionQueue(
                root: root, store: store, filer: Filer(root: root),
                resolver: TopicResolver(suggester: OnDeviceSuggester()),
                transcriber: transcriber)
            let updated = await queue.process(fresh)
            await Task.detached { try? library.updateSidecar(updated) }.value

            try? self.index?.upsert(updated)
            self.reloadRecent()
        }
    }
```

Add the sidecar writer to `Library.swift` beside `commit`:

```swift
    /// Rewrites an existing sidecar in place. Used when transcription adds
    /// fields to a recording already on disk. Never touches the audio.
    public func updateSidecar(_ sidecar: Sidecar) throws {
        let audio = root.appendingPathComponent(sidecar.relativePath)
        let destination = Self.sidecarURL(forAudio: audio)
        let staged = destination.appendingPathExtension("part")
        try Self.encoder.encode(sidecar).write(to: staged)
        do {
            try Self.install(staged, at: destination)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
    }
```

Call `startTranscription()` at the end of `start()` and after a sync completes in `apply(_:)` when progress reaches its finished state.

- [ ] **Step 7: Run the whole suite**

Run: `swift build 2>&1 | grep -i warning; swift test`
Expected: zero warnings, everything PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/StenoUI/TranscriberRegistry.swift Sources/StenoUI/AppModel.swift \
        Sources/StenoUI/Library.swift Sources/StenoUI/MenuBarView.swift \
        Tests/StenoUITests/TranscriberRegistryTests.swift \
        Tests/StenoUITests/MenuBarViewTests.swift
git commit -m "feat(app): run transcription after sync and show titles in the menu

The automatic backend is pinned to on-device and is not user-overridable,
because unattended cloud transcription would bill on every recording."
```

---

## Task 14: Settings and the re-transcribe action

**Files:**
- Modify: `Sources/StenoUI/SettingsView.swift:16-71`
- Modify: `Sources/StenoUI/MenuBarView.swift` (context menu on recent rows)
- Test: `Tests/StenoUITests/SettingsViewTests.swift`

**Interfaces:**
- Consumes: `TranscriberRegistry`, `Keychain`, `AppModel.retranscribe(_:using:)`, `Filer.rebuild(from:store:)`.
- Produces: `AppModel.rebuildTopicFolders()`

- [ ] **Step 1: Write the failing test**

Create `Tests/StenoUITests/SettingsViewTests.swift`:

```swift
import Foundation
import Testing
@testable import StenoUI

/// The key must never land in UserDefaults, where anything running as the user
/// can read it and where it ends up in backups as plain text.
@Test func theApiKeyIsNotStoredInUserDefaults() throws {
    let account = DeepgramTranscriber.keychainAccount
    defer { Keychain.remove(account) }

    try Keychain.set("secret-key", for: account)

    #expect(Keychain.string(for: account) == "secret-key")
    #expect(UserDefaults.standard.string(forKey: account) == nil)
    #expect(UserDefaults.standard.string(forKey: "deepgram") == nil)
}

@Test func removingTheKeyMakesTheCloudBackendUnavailable() async throws {
    let account = DeepgramTranscriber.keychainAccount
    try Keychain.set("secret-key", for: account)
    #expect(await DeepgramTranscriber().isAvailable())

    Keychain.remove(account)
    #expect(await DeepgramTranscriber().isAvailable() == false)
}
```

- [ ] **Step 2: Run and watch it fail**

Run: `swift test --filter SettingsView`
Expected: PASS already if Task 12 landed — this pins behaviour rather than driving new code. If it fails, Task 12 is wrong; fix that first.

- [ ] **Step 3: Add the `Transcription` section**

Insert into `Sources/StenoUI/SettingsView.swift` after the `Library` section:

```swift
            Section("Transcription") {
                // On-device always runs automatically; this picker chooses what
                // "Transcribe again" uses. Stated in the help text because a
                // picker that silently means something narrower is a lie.
                Picker("Model for re-transcribing", selection: $selectedTranscriberID) {
                    ForEach(TranscriberRegistry.all(), id: \.id) { backend in
                        Text(backend.displayName).tag(backend.id)
                    }
                }
                .onChange(of: selectedTranscriberID) { _, id in
                    UserDefaults.standard.set(id, forKey: TranscriberRegistry.selectionKey)
                }

                Text("New recordings are always transcribed on this Mac, for free. "
                     + "Cloud models run only when you ask, one recording at a time.")
                    .font(.caption).foregroundStyle(.secondary)

                SecureField("Deepgram API key", text: $deepgramKey)
                    .onSubmit { try? Keychain.set(deepgramKey, for: DeepgramTranscriber.keychainAccount) }
                    .accessibilityLabel("Deepgram API key")

                Button("Rebuild Topic Folders") { model.rebuildTopicFolders() }
            }
```

with these `@State` properties beside the existing ones:

```swift
    @State private var selectedTranscriberID =
        UserDefaults.standard.string(forKey: TranscriberRegistry.selectionKey)
        ?? SpeechAnalyzerTranscriber().id
    @State private var deepgramKey =
        Keychain.string(for: DeepgramTranscriber.keychainAccount) ?? ""
```

- [ ] **Step 4: Add `rebuildTopicFolders()` to `AppModel`**

```swift
    /// Topic folders are derived, exactly like `index.sqlite`. This is a button,
    /// not a recovery operation.
    public func rebuildTopicFolders() {
        let root = libraryRoot
        Task.detached {
            let library = Library(root: root)
            let sidecars = (try? library.scanSidecars()) ?? []
            try? Filer(root: root).rebuild(from: sidecars, store: TranscriptStore(root: root))
        }
    }
```

- [ ] **Step 5: Add the per-row re-transcribe action**

On the recent-row `MenuRow` in `MenuBarView`:

```swift
                .contextMenu {
                    ForEach(TranscriberRegistry.all(), id: \.id) { backend in
                        Button("Transcribe again with \(backend.displayName)") {
                            model.retranscribe(item, using: backend)
                        }
                    }
                }
```

- [ ] **Step 6: Run the whole suite**

Run: `swift build -c release 2>&1 | grep -i warning; swift test`
Expected: zero warnings in debug and release, everything PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/StenoUI/SettingsView.swift Sources/StenoUI/MenuBarView.swift \
        Sources/StenoUI/AppModel.swift Tests/StenoUITests/SettingsViewTests.swift
git commit -m "feat(settings): transcription section, Keychain key field, topic rebuild

Re-transcribing is a per-recording context-menu action, which keeps the
only path off this machine to one deliberate click on one recording."
```

---

## Task 15: Whole-branch review and follow-ups

Per-task reviews cannot see a later task undoing an earlier one's guarantee. Three defects on spec 1.5 had exactly that shape and only the whole-branch pass caught them.

**Files:**
- Modify: `docs/superpowers/follow-ups.md`

- [ ] **Step 1: Run the full verification**

```bash
swift build 2>&1 | grep -iE "warning|error"
swift build -c release 2>&1 | grep -iE "warning|error"
swift test 2>&1 | tail -20
```

Expected: no warnings, no errors, every test passing. Record the test count.

- [ ] **Step 2: Re-verify every mutation check still bites**

The guards from Tasks 1, 2, 5, 6, 8, 9, 10 and 11 were each proven once, in isolation. Re-run every one of them against the finished branch, because a later task may have made an earlier guard unreachable without failing its test.

- [ ] **Step 3: Review the whole diff against the spec**

```bash
git diff main...HEAD --stat
git diff main...HEAD
```

Check specifically:
- **Audio never moves.** `git diff main...HEAD -- Sources/StenoUI/Library.swift` must show no change to `destinationURL`. Any change there breaks `SyncEngine`'s diff.
- **`JensenKit` is untouched.** `git diff main...HEAD --stat -- Sources/JensenKit/` must be empty.
- **`deviceModel` is still `"hidock-p1"`.**
- **No third-party dependency** entered `Package.swift`.
- No `.sheet` was added inside `MenuBarExtra`.

- [ ] **Step 4: Run the real app against the real library**

```bash
./Scripts/make-app.sh
open /Applications/Steno.app
```

Confirm by hand, and report rather than claim:
- Recent rows show titles.
- Topic folders appeared for any recording that carried a directive.
- `~/Recordings/Steno/*/*.transcript` exist and hold real text.
- Deleting a topic folder and pressing **Rebuild Topic Folders** puts it back.

- [ ] **Step 5: Record what only a human can check**

Append to `docs/superpowers/follow-ups.md` under `## Spec 2 hardware and quality checks`: the Task 4 verdict, whether `FoundationModels` extracted topics from naturally-spoken directives, how the menu's second line looks at real title lengths, and whether Deepgram diarization was ever exercised against the live API.

- [ ] **Step 6: Commit and open the branch for review**

```bash
git add docs/superpowers/follow-ups.md
git commit -m "docs: record spec 2 follow-ups and deferred human checks"
```

Then use `superpowers:requesting-code-review` for a whole-branch review before merging, and `superpowers:finishing-a-development-branch` to integrate.
