# Spec 2 — transcription and AI filing

Every synced recording gets a transcript automatically. A spoken instruction
inside a recording — *"file this under Grocery List"* — puts a note in a folder
of that name.

Wishlist items 3 and 4. Item 5 (call audio routing) is spec 3; item 6 (Vibe Mic)
is unscheduled. Neither is folded in here.

## The two things, kept apart

Transcription and filing were one idea in the wishlist and are two features here.

**Transcription is automatic and unprompted.** Every recording gets one when it
syncs. Nothing has to be said.

**Filing is the only spoken part.** No directive in the audio means a transcript
and nothing else; the recording stays where it is.

That separation decides the model story. Automatic only works if the default
backend is free, so the on-device model is the always-on path and the cloud
backend is a deliberate per-recording action. A cloud API cannot be the
automatic default without silently billing for every 66-minute meeting.

## Decisions

### On-device by default, cloud on request

`SpeechAnalyzer` (macOS 26+) is the automatic backend. It benchmarks at 2.12%
WER on clean read-aloud speech against Whisper large-v3's ~2.1%, at roughly 3x
the speed, on-device, free, with native long-form support and **no third-party
dependency**. Published benchmarks disagree about the exact ordering; treat
these as the same league rather than a settled ranking.

This is the reason the no-dependency rule survives spec 2 intact. "Best
available on-device model" and "zero dependencies" turned out not to be in
tension. The constraint was weighed, as the priming doc required, and it holds.

**The platform target moves from `.macOS(.v15)` to `.macOS(.v26)`.** Both
`SpeechAnalyzer` and `FoundationModels` require it. That also forces
`swift-tools-version` up from 6.0, whose `PackageDescription` has no `.v26` case.
Verified locally: Swift 6.3.3 under Xcode 26.6 on arm64, so both the toolchain
and Apple Intelligence's hardware requirement are already satisfied.

Deepgram Nova-3 is the cloud backend, chosen because it adds a *capability*
rather than accuracy points: **speaker diarization**, which neither
`SpeechAnalyzer` nor Whisper does natively. It also accepts hour-long files
directly, so spec 2 needs no audio chunking at all — the 25 MB caps on OpenAI
and Groq would have forced chunking and stitching to be built and tested for no
capability gain. A plain `URLSession` upload, so the dependency rule still holds.

### Audio never moves

`Library.destinationURL(for:)` is documented pure, and `SyncEngine`'s diff
checks the filesystem at that computed path. Filing does not touch it.

What lands in a topic folder is a **note**, not the recording. The audio and its
sidecar stay in their dated folder permanently.

The deciding argument is already in this codebase. `Library.commit` says a
redundant download is a better failure than a confident lie, and that rule
exists because sync has to guess. AI filing is a far worse guesser. It will
mishear a topic, invent one, or file a client call under "Grocery List"
eventually. So the question is what a wrong guess costs:

- **Note filed wrongly:** a text file in a badly named folder. Fix the topic
  field, regenerate, done.
- **Audio filed wrongly:** the only copy of a 66-minute recording is in the
  wrong place, and a crash mid-move leaves the sidecar and index disagreeing
  about where it is.

Guesses may move derived data. They may not move canonical data.

Two consequences worth stating. Topic folders become regenerable from sidecars,
exactly like `index.sqlite` — so "rebuild topics" is a button, not a recovery
operation. And the `isAlreadySynced` tightening that `follow-ups.md` said should
land *before* spec 2 adds title slugs **is no longer a prerequisite**, because
no path computation changes. It remains an open follow-up on its own merits.

The accepted cost: you cannot open a topic folder and hit play. If that matters
in daily use, a symlink beside the note is a small additive change later. The
reverse is not true — once audio has scattered into topic folders, gathering it
back is a migration.

### The transcript is canonical, the note is derived

These cannot be the same file. A note is throwaway; a transcript costs money and
minutes to recompute. So the transcript lives beside the audio and the note is
rendered from it.

```
~/Recordings/Steno/
├── 2026-08-05/
│   ├── 130006-c8357e00.mp3          audio, never moves
│   ├── 130006-c8357e00.json         sidecar
│   └── 130006-c8357e00.transcript   canonical
└── Grocery List/
    └── 2026-08-05 1300 Grocery List.md    derived, regenerable
```

The transcript extension is `.transcript`, **not** `.transcript.json`.
`Library.scanSidecars()` enumerates the whole root and decodes anything with
`pathExtension == "json"`. A transcript ending in `.json` would be
decode-attempted on every rebuild. It fails safely today, because `Sidecar`
decoding is all-or-nothing, but it is wasteful and it is the kind of coincidence
that becomes a defect later.

Segment timings are kept because they arrive free with the transcription run and
cost a full re-run to recover. Structure also means a richer note later — an
itemised list, a summary — regenerates from what is already on disk instead of
re-transcribing.

### A regex grants permission; the model extracts

`DirectiveParser` does not extract the topic. It decides whether a directive is
present at all. That is what stops a recording which merely *mentions* groceries
from being filed under Grocery List.

Only when it says yes does the on-device model produce a folder name, so
paraphrase works (*"stick this in my grocery list"*) without anything being
invented from silence.

## Architecture

Twelve new files in `StenoUI`. No module boundary changes. **`JensenKit` is
untouched — spec 2 sends nothing to the device and adds no command.**

```
Transcription
  Transcript.swift              the Codable artifact. Foundation only.
  TranscriptStore.swift         read/write .transcript beside the audio,
                                signature-verified on every read.
  Transcriber.swift             protocol + TranscriberError.
  SpeechAnalyzerTranscriber.swift   on-device. import Speech.
  DeepgramTranscriber.swift     URLSession upload. Foundation only.
  TranscriberRegistry.swift     which backends exist, which is selected.
  Keychain.swift                Security.framework wrapper, Deepgram key only.

Filing
  DirectiveParser.swift         PURE. String -> Directive?  No I/O, no model.
  TopicResolver.swift           DirectiveParser + FoundationModels,
                                degrading to raw capture when unavailable.
  TopicName.swift               PURE. sanitises a model string into a folder name.
  Filer.swift                   writes the note, rebuilds the topic tree.

Orchestration
  TranscriptionQueue.swift      actor. serial, derived, resumable.
```

`AppModel` gains one stored `TranscriptionQueue` and nothing else. `SyncEngine`,
`Library`, `LibraryIndex` and `DeviceMonitor` are extended at existing seams,
never restructured.

The only seam that matters:

```swift
public protocol Transcriber: Sendable {
    var id: String { get }
    var displayName: String { get }
    func isAvailable() async -> Bool
    func transcribe(audio: URL, locale: Locale) async throws -> Transcript
}
```

Two conformances ship. A third is a new file and a registry line, never a change
to the pipeline.

## Data model

### Transcript

```swift
public struct Transcript: Codable, Sendable, Equatable {
    public var signature: String        // binds to the recording
    public var text: String
    public var segments: [Segment]
    public var locale: String
    public var backend: String          // "speechanalyzer" | "deepgram"
    public var modelID: String
    public var transcribedAt: Date
    public var audioDurationSeconds: Double?
}

public struct Segment: Codable, Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var text: String
    public var speaker: Int?            // Deepgram only; nil on-device
}
```

`signature` inside the file is load-bearing, not decoration. `TranscriptStore`
compares it against the recording's own signature on every read and **discards a
mismatch rather than displaying it**. That is the standing rule applied to
transcripts: paying to transcribe twice beats showing someone else's meeting.

### Sidecar — five new optional fields

Optional so every sidecar already on disk decodes unchanged.

```swift
public var title: String?               // model-derived, feeds MenuRow.detail
public var topic: String?               // sanitised folder name
public var transcribedAt: Date?
public var transcriptBackend: String?
public var transcriptionAttempts: Int?  // bounds automatic retry
```

`deviceModel` stays `"hidock-p1"`. It is persisted in every existing sidecar and
changing it desyncs the library.

Provenance is duplicated between sidecar and transcript deliberately: an index
rebuild then reads only sidecars, exactly as today, instead of opening a
transcript file per recording.

### Index — schema version 2

New columns: `title`, `topic`, `transcribed_at`, `transcript_backend`. Four, not
five — `transcriptionAttempts` is queue bookkeeping that nothing reading the
index ever needs.

`migrate()` only ever runs `CREATE TABLE IF NOT EXISTS`, so it cannot add a
column to an existing table. Rather than invent an `ALTER` path: on
`user_version < 2`, drop and recreate the table, then let `rebuildIndex()` refill
it from sidecars. That is what the index being disposable is for.

**`LibraryIndex.decode` reads columns by position from `SELECT *`.** New columns
must be *appended*, never inserted, or every field after the insertion point
silently shifts. A test pins this.

### TopicName — the one real security surface

A model-generated string becomes a filesystem path. `TopicName` is pure and
**rejects rather than repairs**:

- anything containing a path separator
- anything beginning with `.`
- `..`
- control characters
- empty or whitespace-only after trimming
- longer than 60 characters
- matching `^\d{4}-\d{2}-\d{2}$`, or equal to `undated` or `.incoming` — each
  collides with the library's own layout

A rejected topic means the recording is **not filed**. It still gets its
transcript. Unfiled is a better failure than wrongly filed.

### The note

Topic folders sit at the **library root**, beside the dated folders. There is no
`Filed/` wrapper — which is precisely why `TopicName` has to reject date-shaped
names.

```
<root>/<Topic>/<YYYY-MM-DD HHmm> <title>.md
```

Markdown with YAML front matter:

```yaml
---
signature: c8357e00d535682319c8e19d50685d1a
recordedAt: 2026-08-05T05:00:06Z
audio: ../2026-08-05/130006-c8357e00.mp3
backend: speechanalyzer
---
```

Below it, the title as an `#` heading and the transcript text. Later specs change
what goes under the front matter — an itemised list, a summary. Nothing else here
moves.

`signature` in the front matter is what makes writing idempotent. `Filer`
overwrites a note only when the one already there carries the same signature. A
different signature at the same path means two recordings produced the same title
in the same minute, and the newcomer gets its 8-character signature prefix
appended to its filename rather than destroying the incumbent. `Library` learned
that lesson expensively — "the signature prefix is not decoration" — and the note
path inherits it rather than rediscovering it.

## Pipeline

```
sync commits audio + sidecar
        │
        ▼
TranscriptionQueue.refresh()          ← also runs at launch
   enqueue every recording with no valid .transcript
        │
        ▼  (serial, one at a time, background priority)
Transcriber.transcribe(audio:locale:)
        │
        ▼
1. write .transcript        atomic: temp + replaceItemAt
2. update sidecar           title, topic, transcribedAt, backend
3. render note              <root>/<Topic>/<date time title>.md
```

### The queue is derived, not stored

There is no persisted job list. "What needs transcribing" is computed by asking
`TranscriptStore` which recordings lack a valid transcript. Same philosophy as
the SQLite index: state you can recompute cannot go stale or corrupt.

This also handles the existing library for free. The 11 recordings already on
disk have no transcripts, so first launch picks them up with no backfill code and
no migration. On-device, so it costs nothing but Neural Engine time.

### Write ordering is the inverse of `Library.commit`

In sync, the expensive thing is the download, so audio goes first. Here the
expensive thing is transcription, and **the already-done check is the presence of
a valid transcript file, not `sidecar.transcribedAt`**.

- Crash after step 1 → next run sees the transcript, skips transcription, redoes
  steps 2 and 3 for free.
- Crash after step 2 → next run redoes step 3 for free.
- The note regenerates from sidecar plus transcript at any time.

Nothing expensive is ever repeated. Same trade the sync path makes, pointed at
the thing that costs money here rather than the thing that costs bandwidth.

### Title and topic

One model call per transcript, with the topic half gated:

```
TopicResolver.resolve(transcript) -> (title: String, topic: String?)

  title   always produced, feeds MenuRow's second line
  topic   forced nil unless DirectiveParser found a directive
          phrase, regardless of what the model returns
```

Degradation when Apple Intelligence is off or on unsupported hardware: title
falls back to the transcript's opening words, topic falls back to
`DirectiveParser`'s own capture group. Filing still works, just more literally.

### Locale, and what re-transcribing does

`transcribe(audio:locale:)` receives the system locale. Spec 2 exposes no locale
picker.

Re-transcribing with Deepgram **overwrites** the `.transcript` in place. That is
the point of the action, and `backend` plus `modelID` inside the file record
whose output survived. Filing then re-runs against the new text, so a topic can
change.

When a topic changes, `Filer` deletes the note at the old location before writing
the new one. `Rebuild Topic Folders` removes the whole tree and regenerates it
from sidecars, which is the catch-all for any orphan a crash leaves behind.

### Failures

`transcriptionAttempts` bounds automatic retry so a permanently undecodable file
does not re-attempt on every launch forever. Manual retry ignores the count.

**Cloud transcription is never retried automatically**, because retrying it
spends money without asking.

Errors surface through the existing `lastError` and notice rows. **Nothing is
deleted on any failure path.**

`TranscriptionQueue` is an `actor`. It touches no device, so it needs none of
`AppModel`'s USB guards, but sidecar writes serialise through it so they cannot
interleave with a `rebuildIndex()` scan.

## UI

**Menu.** Recent rows get the second line `MenuRow.detail` was built for in
spec 1.5:

```
Today 13:00                                    66:24
Grocery list and the Tuesday supplier call
```

While the queue works, the status area carries `Transcribing 3 of 11` through the
existing notice row rather than new chrome.

**Settings** gains one `Transcription` section:

- Model picker over available `Transcriber`s. On-device is the default and the
  only one that runs automatically.
- Deepgram API key field, writing to the **Keychain**. Empty means the cloud
  backend is not offered at all.
- `Rebuild Topic Folders`, beside the existing `Rebuild Index` — the same kind of
  operation on the same kind of derived data.

**Re-transcribing is per-recording, never a global setting.** Right-clicking a
recent row offers `Transcribe with Deepgram…`. That is the only way audio ever
leaves the machine, and it is always one deliberate click on one recording.

Long-lived UI stays in `Window` scenes. `MenuBarExtra` has produced two defects
on this project already.

## Testing

Swift Testing only, never XCTest. No test may require an attached P1. No test may
write to `~/Library/Logs/Steno/`. No agent here has a display.

**Where the bulk lives.** `DirectiveParser` and `TopicName` are pure functions
with no I/O and no model, so they carry most of the suite cheaply. `TopicName`
gets the adversarial set: `../../etc`, `Grocery/List`, `.hidden`, `2026-08-05`,
`undated`, `.incoming`, empty, whitespace-only, 400 characters, control bytes.
Each asserts rejection, not repair.

**The three that actually matter**, each guarding something the spec would
otherwise silently lose:

1. **A transcript never attaches to the wrong recording.** Write a transcript
   carrying signature A, read it back for recording B, assert refusal.
2. **Nothing expensive is paid for twice.** A fake `Transcriber` counts calls.
   Run the pipeline, interrupt after the transcript write, resume, assert the
   count is still exactly 1. Repeat interrupting after the sidecar write.
3. **Old sidecars still decode.** Not a synthesised fixture — a real spec-1
   sidecar JSON checked into the test bundle, asserting it decodes with the five
   new fields nil.

All three are **mutation-checked**: revert the guard, confirm the test goes red,
restore. Six tests on the last branch passed by construction and these are
exactly that shape.

**Also covered:** index v1→v2 migration and refill; a column-position test so
appending versus inserting is caught rather than silently shifting later fields;
topic tree regeneration producing an identical tree after deletion; Deepgram
request construction and response parsing against a captured fixture, with the
key asserted to come from the Keychain and never `UserDefaults`.

**Never in tests:** a live Deepgram call. The fixture is captured once by hand.

**Budget for a whole-branch review.** Per-task reviews cannot see a later task
undoing an earlier one's guarantee; three defects on spec 1.5 had exactly that
shape and only the whole-branch pass caught them.

## Deferred to a human

Recorded in `follow-ups.md` when the branch lands.

1. **Transcription quality on Philippine-accented and Taglish recordings.** The
   single risk that can invalidate the on-device default. Apple's published wins
   are on clean US/EU read-aloud sets; Whisper is historically more forgiving of
   accent and code-switching. No test can answer this. The 11 existing recordings
   are the sample.
2. Whether `FoundationModels` reliably extracts a topic from directives spoken
   naturally mid-recording rather than at the start.
3. The menu's second line beside real content, at real title lengths.
4. Deepgram against the live API with a real key, including diarization output on
   a two-person call.

## Scope

**Out:** spec 3's call routing, Vibe Mic, itemised to-do parsing, transcript
search UI, transcript editing, summarisation, and moving audio under any
circumstance.

**No device code is touched.** No new Jensen command. Nothing is sent to the P1.
The whole spec runs on files already on disk.

### One adjacent fix folded in

`follow-ups.md`'s queue-first item: `AppModel.openIndex()` deletes `index.sqlite`
on a failed open but leaves `index.sqlite-wal` and `-shm`, so a stale
write-ahead log can revive the corruption the delete was meant to clear. The
v1→v2 migration edits this exact path. Removing all three files is a few lines
and closes a known defect while we are already inside it.
