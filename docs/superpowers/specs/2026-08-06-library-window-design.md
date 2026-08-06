# Spec 4 — the library window

A resizable window that lists every recording, reads its transcript, searches
across all of them, plays audio from any line, and lets a wrong title or topic
be corrected.

## Why now

Spec 2 produced 26,118 words across 2,308 timestamped segments — three hours of
meetings — and none of it is reachable from inside Steno. The menu shows a
title. Reading a transcript means opening Finder and a text editor. The segment
timings were persisted specifically because they arrive free with transcription
and cost a full re-run to recover, and nothing has used them yet.

The menu also cannot grow. It renders at 272×412pt and hit a structural layout
failure the day titles were added to it — two-line rows collapsing into each
other under a height the popover would not give them. Search, transcript
reading and topic browsing do not fit there, and adding them makes the menu
worse rather than better.

## Decisions

### Play, and seek from the transcript

Clicking a line starts audio at that moment. This is the thing Finder and a text
editor cannot do, and it is what the stored timings are for. A search result is
therefore a **moment**, not a file: "here is the sentence, press play."

### Search runs in memory, loaded when the window opens

`LibraryIndex.all()` for the sidecars, `TranscriptStore.transcript(for:)` for
each transcript, held for the window's lifetime and searched live as you type.

No schema change, no FTS table, no second copy of the text to keep in step with
the transcripts. The transcripts on disk stay the single source of truth, which
is the rule this project has held throughout — and a duplicated index that can
drift is exactly the class of bug that kept surfacing during spec 2.

The library is ~200 KB today. A year of this recording habit is roughly 5 MB of
JSON, which loads in a moment. If it ever outgrows that, swapping in FTS5
touches one type, because search is already isolated behind a pure function.

### Title and topic are editable

Spec 2's design says a wrong AI guess is fixed by "editing the topic field and
regenerating" — but nothing in the app can do that, so in practice it means
hand-editing JSON, which means bad titles stay. The window is where that gets
fixed.

It also gives filing a way to be useful before a directive is ever spoken.
Today the library has zero topic folders, because none of three hours of real
speech contained a genuine filing directive.

### Layout: sidebar and transcript, search returns moments

Recordings on the left grouped by topic; transcript on the right; playhead
along the bottom. Typing narrows the sidebar **and** turns the right pane into a
list of matching moments grouped by recording, each one playable. Clearing the
query returns it to the transcript.

The alternative — highlighting matches inside one transcript with next/previous
arrows — keeps more surrounding context but answers "where in this recording"
one recording at a time. With 50–66 minute recordings the question is "where in
the library", and a moment list answers it everywhere at once.

### Playback follows the transcript, and stops when you scroll

The current line highlights and is kept in view. **Scrolling by hand detaches
following**, and a small banner offers to resume.

That detach rule is the feature, not a refinement of it. Auto-scroll that yanks
the view while you are re-reading something is worse than no auto-scroll.

## Architecture

Eight new files in `StenoUI`, and a third `Window(_:id:)` scene alongside the
Settings and Reclaim scenes `StenoApp` already declares.

```
LibraryStore.swift        @Observable. Loads sidecars + transcripts into
                          memory once, owns the selection. The window's model.
TranscriptSearch.swift    PURE. query + recordings -> [Moment]. No I/O.
AudioPlayer.swift         @Observable AVPlayer wrapper: play, seek, currentTime.
LibraryWindow.swift       The scene's root. Sidebar + detail split.
LibrarySidebar.swift      Recordings grouped by topic, filtered by the query.
TranscriptPane.swift      The reader, and the follow-and-detach behaviour.
MomentsPane.swift         Search results, grouped by recording.
RecordingEditor.swift     Title and topic editing.
```

**Nothing in `SyncEngine`, `LibraryIndex`, `DeviceMonitor`, `TranscriptionQueue`
or `AppModel`'s sync guards is restructured.** Three additions, all at existing
seams:

- `MenuBarView.libraryWindowID`, beside `settingsWindowID` and
  `reclaimWindowID` — the window IDs already live there, not on `AppModel`.
- `MenuBarView` gains one row, "Library…", opening it the same way
  "Settings…" does.
- `AppModel` gains one method so the editor can take the same guard the sweep
  uses. `sidecarsInFlight` stays private; a scoped accessor is what the editor
  gets, so no caller can insert without also removing:

```swift
    /// Runs `work` while this recording is marked in flight, or returns nil if
    /// something else already holds it. Scoped so the set cannot leak an entry.
    func withRecordingHeld<T>(_ signature: String,
                              perform work: () async -> T) async -> T?
```

Two types carry the design:

```swift
/// One recording with its transcript, held for the window's lifetime.
///
/// `transcript` is nil until the queue has been through it. That is not an
/// error state — the sweep is asynchronous and a freshly synced recording
/// legitimately has none yet.
struct LoadedRecording: Identifiable, Sendable {
    let sidecar: Sidecar
    let transcript: Transcript?
    var id: String { sidecar.signature }
}

/// A single matching line — the unit a search returns, rather than a recording.
struct Moment: Identifiable, Sendable {
    let signature: String
    let recordingTitle: String
    let segment: Segment          // carries `start`, so it is playable
    /// Where the query matched WITHIN `segment.text`, for highlighting.
    let highlight: Range<String.Index>
    var id: String { "\(signature)-\(segment.start)" }
}
```

`TranscriptSearch` being a pure function over those makes the part most likely
to be wrong the part cheapest to test — the same split that made
`DirectiveParser` and `TopicName` testable in spec 2.

**`AVPlayer`, not `AVAudioPlayer`.** Only `AVPlayer` offers
`addPeriodicTimeObserver`, and following playback needs a time signal.
`Library.measureDuration`'s use of `AVAudioFile` is untouched.

**Resizable, unlike its siblings.** Settings and Reclaim use
`.windowResizability(.contentSize)` because they are fixed-size forms. This one
needs `.contentMinSize` and a `defaultSize` — it is the first scene in this app
anyone would want to make bigger.

## Data flow

### Loading

On window appear, `LibraryStore.load()` reads the index for sidecars and then
each transcript **off the main actor**, behind `Task.detached`, assigning the
result back in one go. That is N JSON decodes, and it is the same work Task 13
had to move off the main actor for the sweep.

Reload happens on appear, and again via `.onChange(of: model.transcriptionProgress)`
when it returns to nil — `AppModel` is `@Observable`, and the sweep finishing is
exactly when new transcripts exist. Nothing polls, and there is no timer.

### Searching

Every keystroke runs `TranscriptSearch.moments(matching:in:limit:)` over the
in-memory array. Case- and diacritic-insensitive, and capped at **500 moments**
so a one-letter query cannot produce tens of thousands of rows — when the cap
bites, the pane says so rather than silently truncating. Queries shorter than
two characters return nothing at all.

An empty query is not a search: the sidebar shows everything and the right pane
shows the selected transcript.

**Clicking a moment selects its recording and seeks to it.** Clearing the query
then leaves you in that transcript at that position, rather than snapping back
to whatever was selected before the search — the point of a moment is to land
you somewhere.

### Playing and following

Clicking a line seeks to `segment.start`. A periodic time observer updates
`currentTime`; the current segment is derived, highlighted and scrolled into
view.

```
time observer fires -> currentSegmentIndex changes
    -> if isFollowing: scroll to it

user scrolls by hand (onScrollPhaseChange)
    -> isFollowing = false
    -> banner: "Following paused · Resume"
```

### Editing — the only path that writes

```
1. take AppModel's sidecarsInFlight guard for that signature
2. Library.updateSidecar(updated)      atomic, UUID-staged
3. index.upsert(updated)
4. topic changed? Filer.removeNote(old) then Filer.write(new)
5. release the guard
```

**Step 1 is not optional.** `sidecarsInFlight` exists because the automatic
sweep and a manual re-transcribe could otherwise write one sidecar at once. The
editor is a **third** writer, and skipping the guard reintroduces exactly the
race Task 14 closed. The failure would be silent: last writer wins, so a title
just typed can be replaced by the sweep finishing.

Topic edits go through `TopicName.sanitised` like every other path. The picker
offers existing topics plus "New Folder…", and a typed name that is rejected is
refused with a reason rather than quietly repaired.

Recordings with no transcript appear in the sidebar with their timestamp, and
the pane says so plainly.

## Traps specific to this codebase

**`ImageRenderer` measures the IDEAL layout, not what a constrained container
does.** The menu bug that preceded this spec was invisible at ideal size: the
row measured a healthy 38pt and looked correct three times running, while on
screen the rows were collapsing into each other because the popover offered
less height than the content wanted. Every layout test here renders **both**
unconstrained and inside a deliberately short container.

**Assert on spacing, not on how many things are drawn.** Clipping and collapsing
both reduce an ink-band count, so a count-based assertion passes either way — a
test written that way during the menu fix survived its own mutation check and
proved nothing.

**Extract decisions from views.** Follow-and-detach gets
`shouldFollow(isFollowing:userScrolled:)` and `currentSegment(at:in:)` as pure
functions, matching `shouldClearTranscriptionState` and `mayStartTranscribing`.
The rendering stays untested; the decision does not.

**Speaker labels appear only where they exist.** `Segment.speaker` is populated
by Deepgram and nil on-device, so a diarized transcript reads as a conversation
and an on-device one reads as prose. No placeholder "Speaker 1" on a recording
that was never diarized.

**Filing has never run.** Zero topic folders, so every recording currently lands
under "Unfiled" and the topic grouping is unexercised against real data. It
needs a fixture test rather than relying on the live library to prove it.

## Testing

`TranscriptSearch` is pure and carries the bulk: empty query, single character,
no matches, diacritics, a query longer than any segment, a cap that actually
caps, and a match at the very start and very end of a segment.

`LibraryStore.load` runs against a temp library with a mix of transcribed and
untranscribed recordings.

The editor's write path asserts all four steps happened — sidecar written, index
upserted, old note removed, new note written — and that the guard was taken.

Layout tests render unconstrained and constrained, asserting spacing.

**No test requires a P1, a network, Apple Intelligence, a downloaded model, the
real library, or the real `deepgram-api-key` Keychain item.**

## Scope

**Out:** editing transcript text, export, deleting recordings, multi-select,
spec 3's call routing, Vibe Mic.

Cloud re-transcription stays in the menu's context menu. Adding it here too
would be a second way to do one thing.
