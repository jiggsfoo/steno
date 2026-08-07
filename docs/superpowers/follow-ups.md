# Known follow-ups

Carried out of the final whole-branch review of `feat/foundation` (2026-08-04).
None block merge. Each was adjudicated rather than silently dropped.

## Queue first

**Index reset leaves WAL sidecars behind.** `AppModel.openIndex()` deletes
`index.sqlite` on a failed open but not `index.sqlite-wal` / `-shm`. WAL is
enabled, so a stale write-ahead log from a crash can be recovered back into the
fresh file, reviving the corruption the delete was meant to clear. Degrades to a
visible error rather than silence, so it is recoverable, but the cleanup should
remove all three files.

## Lower priority

**`isAlreadySynced`'s fallback is weaker than the old gate.** When the index has
no row for a signature, it falls back to checking the computed path against the
*device-reported* length. That branch is newly reachable, and `isAlreadySynced`
also gates `reclaimable` / `deleteFromDevice` — so with an empty index and no
sidecar it would authorise a device delete on the device's own claim about
length. Only reachable in the audio-installed / sidecar-failed state, where the
audio is complete, so no recording is at risk today. Worth tightening before
spec 2 adds title slugs, which will change how paths are computed.

**`.attached` is ignored while status is already `.connected`.** This stops
routine USB churn elsewhere on the system from restarting a sync. If a
terminating service is still registry-visible when `rescan()` runs, though, the
status can stay `.connected` and a genuine replug is dropped. Self-heals on the
next detach or on sleep/wake.

**`scheduleRetry()` conflates two different situations.** `startSync`'s guard
retries when it is blocked by a running sync, a reclaim, or a poll tick — but in
those cases nothing has failed, something else legitimately owns the USB
interface. It shares a backoff counter with genuine connection failures, so a
drop doubles `retryDelay` toward its 60 s cap. Self-heals on the next successful
connect, and not reachable often enough to ratchet in practice (poll ticks run
strictly sequentially), but the two cases deserve separate handling.

**`retryDelay` ratchets from the reclaim guard.** `scheduleRetry()` doubles the
backoff toward its 60 s cap and is only reset on a successful connect, so
repeated attach-during-reclaim events lengthen the delay.

**After an index wipe, Recent stays empty until a manual rebuild.** Already-synced
recordings hit the fallback path, are skipped, and never re-`upsert`, so the
index does not refill on its own. Settings → "Rebuild index" recovers it, which
is the documented path.

## Spec 4 carried debt (`feat/library-window`, 2026-08-06)

Filed out of the final fix wave, so that none of it lives only in a code
comment or a report. None blocks merge; all four were adjudicated.

**`AppModel.init` has no injection seam, and constructing one in a test is a
real hazard.** `init` runs `LegacyMigration.runIfNeeded` unconditionally, gated
solely by a `UserDefaults` bool. Five tests construct `AppModel()` purely to
compose a view around it — `LibraryWindowTests`, `LibraryLayoutTests`,
`MenuBarIconLabelTests`, and `MenuMetricsTests` twice. On this machine the flag
is set, so the migration is a no-op and nothing happens. Where it is NOT set —
a fresh clone, a new user account, CI — those five tests would MOVE
`~/Recordings/HiDock` to `~/Recordings/Steno`, move
`~/Library/Application Support/HiDock`, and append to the real diagnostic log.
`AppModel.swift`'s doc comment on `log` promises this seam; this is where the
promise is recorded. It also unblocks the two gaps below. Related constraint:
no test may point a constructed `AppModel` at a temp root either, because
`libraryRoot`'s setter writes the user's real defaults key and rebuilds the
hardcoded `~/Library/Application Support/Steno/index.sqlite`.

**Two review-only gaps, both mutation-proven, both waiting on that seam.**
Neither can lose data; both were verified to leave the whole suite green when
mutated.
1. `updateRecording`'s note removal reads `previous.topic` — the freshly
   re-read sidecar — rather than the caller's stale snapshot. Changing it back
   passes every test, because `updateRecording` itself is unreachable. Only the
   `topic:` argument is actually load-bearing: `Filer.removeNote` locates the
   note by scanning front matter for `signature:`, and `AppModel.writeEdit`
   already guarantees the signatures match, so `for: previous` versus
   `for: sidecar` is semantically a no-op. The pure step that produces
   `previous` IS covered.
2. `TranscriptPane.scrub(to:)` calls `followsAfterPlayheadMove()` rather than
   assigning `isFollowing = true` inline. Reverting it passes every test —
   Swift emits no unused-static-method warning. Enforceable only by review.
   (The third gap in this class, "nothing asserts the playhead is mounted", was
   closed:  `LibraryLayoutTests.theTransportRowIsMountedBelowARuleAtTheBottomOfThePane`.)

**`TopicName` points the wrong way at `LibrarySidebar`.** `TopicName` is a
Foundation-only domain type and now reads `LibrarySidebar.unfiled` — a `View`'s
static — to keep the reserved sentinel a single source of truth. The sentinel
should move DOWN instead: define it on `TopicName` (or a shared constants type)
and have `LibrarySidebar.unfiled` read that, which preserves the single source
of truth while pointing the dependency the right way. Deliberately not done in
the fix wave: it touches a spec-2 file and belongs in its own change.

## Ready to plan

**Spec 3's audio routing is no longer speculative.** BlueCatch was verified on hardware
2026-08-05: the P1 pairs directly to Bluetooth earphones, presents a second USB audio
device (`0x1395:0x005d`, 2ch out / 1ch in @ 48 kHz) alongside the data device, and records
both directions of a call. Both devices operate simultaneously, so syncing during a call
works. `BLUETOOTH_STATUS` and `BT_GET_PAIRED_DEV_LIST` are decoded and read the paired
earphones' name, MAC and connection state straight off the device. The remaining
unknowns are the mutating commands (`BLUETOOTH_CMD`, `BT_SCAN`, `BT_DEV_LIST`), which
were deliberately not fired at a working setup. Full detail in `docs/device-reference.md`.

## Deferred hardware checks

Both need a person at the cable and were never performed.

1. **Unplug the P1 mid-command.** Expect prompt failure via a propagated
   `kIOReturnNoDevice` rather than a spin to the full timeout. The
   `kIOReturnTimeout`-only tolerance in `IOUSBHostTransport.transfer` is correct
   by inspection; this confirms it end to end.
   Command: `swift run steno info`, pull the cable during the run.

2. **Attach/detach notifications.** With `swift run steno watch` running:
   unplug and replug the P1, expecting `DETACHED` then `ATTACHED`. Then plug in
   an unrelated USB device and confirm it produces **no** output. That second
   half matters: the IOKit matching dictionary is a bare `IOUSBHostInterface`
   class match, so the callbacks fire for every USB interface on the machine and
   the VID/PID filter is the only thing making an event meaningful.

   Note the first `ATTACHED` line proves only that the initial `rescan()` works —
   it prints before the process parks. Only the unplug exercises the
   notification path.

## Deferred hardware checks — HIG polish (`feat/hig-polish`, 2026-08-05)

No agent in this project has a display. `screencapture` returns black frames, and
there is no way to drive VoiceOver headlessly. Everything below was verified
structurally, by measuring rendered pixels, or not at all — each says which.
The first item is the only one that can invalidate the branch.

1. **Does the menu bar icon actually change state?** *Nobody has ever seen this
   work.* The whole branch exists to make the icon convey state without opening
   the menu, and every one of the 134 tests would still pass if it never
   updated. The original code read `model.status` inside the `MenuBarExtra`
   `label:` closure — that is `App.body` evaluation, where Observation's
   invalidation contract is undocumented. It now reads from `MenuBarIconLabel`,
   a real `View`, which is the documented path. Structural, not observed.

   Check: launch the app with the P1 unplugged (expect `waveform.slash`), plug
   it in (expect a plain waveform), start a sync (expect the down-arrow badge),
   record on the device while docked (expect the red mic badge). If the icon
   never moves off its launch state, the fix did not take.

   This branch already hit this exact shape once: `MenuBarExtra(.window)` builds
   its content lazily, so `.task { model.start() }` never ran until the menu was
   clicked. Found only on hardware.

2. **VoiceOver pass.** Does the status item announce its state at all; is a
   recent row read as "Today 13:00, 66 minutes 24 seconds" rather than
   "66:24"; does a disabled row announce "Sync Now, unavailable"; do the error
   and notice rows announce their severity prefix. Rows were restored to real
   `Button`s so they sit in the Full Keyboard Access focus ring again — confirm
   Tab reaches them.

3. **The app icon beside real neighbours.** Generated by `Scripts/make-icon.swift`
   and inset to the 824/1024 grid, but only ever viewed as a bare PNG. Check it
   in Finder, the Dock and Login Items, where the point is how it sizes against
   the icons on either side.

4. **The red recording icon in a live menu bar**, light and dark. It rendered
   flat black until Task 6 caught it — `isTemplate = false` was set but no code
   ever applied red, so the one state that must never be missed was invisible.
   Pixel tests now gate it, but nobody has seen it in the bar.

5. **Reveal Log on a machine with no `~/Library/Logs/Steno/`.** Task 4 dropped
   the `createDirectory` guard rather than moving it, so the button silently did
   nothing on a fresh install. Restored, but unreproducible here without
   deleting the real log.

## Not defects

Recorded so they are not "fixed" later by mistake.

- **Battery is always `nil`.** `GET_BATTERY_STATUS`'s body layout was never
  verified against hardware, so no parser was invented. The menubar omits the
  line when nil. **Update 2026-08-05:** one sample captured,
  `00 62 00 3d b8 c8`, where `0x62` = 98 looks like a percentage. Needs a
  second reading at a materially different charge level before decoding it.
  See `docs/device-reference.md`.
- **`SET_DEVICE_TIME` is never sent.** The *read* is hardware-verified BCD. That
  the write accepts the same layout is an inference, not a measurement, and a
  wrong write would corrupt the clock that names every recording.
- **`DELETE_FILE`'s response is not parsed.** The format is unverified, so
  `deleteFromDevice` confirms the outcome by re-listing the device instead. If
  that listing fails, every file is reported failed, never deleted.
- **`SyncEngine.isSyncing` is unreachable from the app**, because `startSync`
  builds a fresh engine per call. `AppModel.syncTask` is the real mutex. The
  engine guard remains for direct API users and is exercised by tests.

## Spec 2 hardware and quality checks

### On-device transcription quality (2026-08-06) — measured, PASS with caveats

All 11 recordings in the live library transcribed through `steno transcribe`
with `SpeechAnalyzer`. 10 produced text; the 11th is a 3-second clip that is
silence. A 66-minute meeting took 47 s — roughly 85x realtime, on the Neural
Engine — so long-form needs no chunking and the automatic path is effectively
free. English output is clean and coherent.

**Taglish was NOT measured.** The sample is 26,118 words of English business
meetings with essentially no Tagalog in it. The spec's largest flagged risk is
therefore *unmeasured*, not disproven. Recorded here so nobody later reads
"quality check passed" as "Taglish works".

**Tagalog has no on-device model at all.** `fil_PH` and `tl_PH` both resolve to
`nil` through `supportedLocale(equivalentTo:)`. On a code-switched recording
only the English side has a model behind it. Hard limit, not a tuning problem.

**`en_PH` is not a supported locale and its fallback is non-deterministic.**
The same call returned `en_AU`, `en_US`, and `en_SG` across runs, which makes
both the acoustic model and the persisted `locale` field vary run to run.
Explicit locales resolve to themselves, so **the transcription locale is pinned
to `en_US`**. Variants agree 94–99.7% on this audio, differing mostly on
spelling (`realise`/`realize`), so the pin costs little.

### A filing pattern was disproved by real speech, before it was built

Scanning 3 hours of real recordings for directive-shaped phrases returned 12
hits and **zero genuine filing directives**. Two of them matched the plan's
own `put (this|that|it) (under|into)` pattern:

- "take that credit card string, **put it into** the payment method"
- "I reconstitute it and I **put it into** a sprayer"

Both sit deep inside long client calls, and both would have filed a real
recording under an invented topic — the exact failure the regex prefilter
exists to prevent. `put` and `stick` were dropped from `DirectiveParser`;
only explicit filing verbs (`file`, `filing`, `save … under/in/to/into`)
remain. All four real sentences are now negative test cases.

The lesson generalises: the prefilter's value is entirely in what it refuses,
so its patterns must be validated against real speech rather than imagined
speech. Any new pattern added later gets the same treatment.

### Deferred human checks (Task 15, 2026-08-06)

No agent in this project has a display, a Deepgram account, or a mouth to
speak a directive into a real microphone. Everything below needs a person
with the app open and real audio behind it — recorded here so it isn't
quietly assumed working just because the mutation checks and the Task 4
quality pass came back clean.

1. **The menu's second line at real title lengths.** Recent rows now render a
   model-generated (or fallback opening-words) title beneath the timestamp —
   built and pixel-tested against synthetic strings, never against a title
   `FoundationModels` or the fallback actually produced. Check: open the menu
   with real synced, transcribed recordings present. A problem looks like
   truncation with no ellipsis, a row tall enough to push others off-screen,
   or the title clipping into the timestamp above it.

2. **`Transcribing k of n` in the live menu.** `AppModel.transcriptionProgress`
   drives this line from `startTranscription`'s sweep loop, but nobody has
   watched it update against a real backlog, and nobody has confirmed it
   clears rather than freezing at its last value once the sweep finishes.
   Check: sync a device with several untranscribed recordings, watch the menu
   bar during the sweep, and confirm the line is gone — not stuck reading
   "3 of 3" — once the sweep has actually finished.

3. **Topic folders appearing in Finder.** Sync a recording that carries a
   spoken filing directive, then open the library root in Finder and confirm
   the topic folder and its note exist where `Filer.write` computes them.
   Then delete that folder by hand and press **Rebuild Topic Folders** in
   Settings — confirm the folder and note come back with the same content.
   `Filer.rebuild` only has coverage against an in-memory temp root; it has
   never written into a real, Finder-visible directory tree.

4. **Deepgram against the live API.** Only a 3-second clip has been sent
   through `DeepgramTranscriber` for real (see `DeepgramTranscriberTests`),
   which proves the request/response mapping but says nothing about
   diarization quality on a genuine multi-speaker call. Check: retranscribe a
   real two-person recording with the Deepgram backend and read the output —
   a problem looks like every segment attributed to one speaker, speaker
   labels swapping mid-sentence, or segment boundaries that don't line up
   with actual turn-taking.

5. **Whether `FoundationModels` extracts a topic from a directive spoken
   naturally mid-recording.** `OnDeviceSuggester.prompt` now appends the
   matched instruction explicitly (see `theSuggesterIsGivenTheDirectiveItself`
   and `aMidTranscriptDirectiveStillReachesTheModel` in
   `TopicResolverTests`), which proves the model is SHOWN the instruction —
   it does not prove the model interprets it correctly. No real
   `LanguageModelSession.respond` call has ever run against a naturally
   phrased mid-call directive, only synthetic prompts in tests. Check: record
   something that says, in passing, "let's file this under [topic]" partway
   through a longer recording, sync it, and read the resulting `topic` on the
   sidecar — a problem looks like a topic that plainly isn't what was asked
   for, or no topic at all when a directive was clearly spoken.

6. **The Settings "Transcription" section, rendered.** `SettingsViewTests`
   cover the view's structure, not its appearance. Check: open Settings →
   Transcription and look at the layout, then specifically trigger a failed
   Keychain write on the Deepgram key field (an empty or malformed key) and
   confirm the error caption actually appears next to the field, rather than
   only surfacing in `lastError` elsewhere in the window.

### Known limitations (Task 15, 2026-08-06)

Not deferred checks — things that are true by construction. Recorded so
nobody "fixes" them later without first reading why they're this way.

- **Taglish is still unmeasured, not disproven.** The Task 4 quality pass
  above covers 11 real recordings, all English. No session between then and
  this whole-branch review added a code-switched or Tagalog-only sample. The
  spec's largest named risk stays open, not closed.
- **A hung transcription wedges the automatic sweep for the process's whole
  lifetime.** `TranscriptionQueue.run` calls `transcriber.transcribe` with no
  timeout, and `startTranscription`'s loop `await`s each recording before
  starting the next. A transcriber call that never returns — a wedged
  `SpeechAnalyzer` session, a Deepgram request stuck on a dead connection —
  stops every recording behind it in that sweep from ever being tried.
  Nothing times out and nothing surfaces an error; the sweep just goes quiet
  until the app restarts.
- **Work requested while a sweep is running is dropped, not queued.**
  `startTranscription` guards on `transcriptionTask == nil` and returns
  immediately if a sweep is already in flight — a sync or a manual retry
  landing mid-sweep does not get queued behind it. It self-heals:
  `pending(from:)` recomputes the backlog from disk on the next call, so
  nothing requested is permanently lost, but it also isn't acted on until the
  next trigger (the next sync, or the next launch).
- **The transcription locale is pinned to `en_US`, permanently, not as a
  placeholder.** `en_PH` isn't a supported `SpeechTranscriber` locale, and
  letting the system resolve it produced a different English variant —
  `en_AU`, `en_US`, `en_SG` — on different runs of the *same* audio during
  the Task 4 gate, which would have made both the acoustic model and the
  persisted `locale` field non-deterministic. `TranscriptionQueue.locale`
  pins to `en_US` on purpose. This is a permanent decision, not a TODO —
  revisiting it means re-solving the non-determinism, not swapping in a
  different constant.

### Residuals parked at the final whole-branch review

Both are Low. Neither blocks merge; both were adjudicated rather than dropped.

**Closing Settings with an empty key field deletes the stored key.**
`SettingsView`'s `.onDisappear` commits whatever is in the field, and
`Keychain.set("")` short-circuits to `Keychain.remove`. Two ways in: the user
clears the field and closes without meaning to save, which is defensible as
"commit what's shown"; or `Keychain.string(for:)` returned nil when the view
initialised — a transient Keychain read error — while a key really does exist,
in which case merely opening and closing Settings destroys a working
credential with no prompt. The loss is visible, because Deepgram then vanishes
from the context menu, and recoverable by pasting the key again. The fix is one
line: skip the commit when the field is empty on the `onDisappear` path only,
leaving the explicit-clear path through focus-loss intact.

**An empty context menu when nothing is available.** The menu is now filtered
for both backends, not just the cloud one. On a Mac where `SpeechTranscriber`
is unavailable and no Deepgram key is set, right-clicking a recent row yields
an empty menu with no explanation — worse feedback than the always-fail click
the filtering was added to prevent. The availability cache also refreshes only
at launch and on a key commit, so on-device availability flipping true
mid-session (a model asset finishing its download) goes unnoticed until
relaunch. Deepgram's own staleness is handled correctly in both directions.

### Two documentation drifts, recorded so they are not mistaken for design

- The spec still says *"`Rebuild Topic Folders` removes the whole tree and
  regenerates it from sidecars, which is the catch-all for any orphan a crash
  leaves behind."* The final review's Critical fix deliberately overrode that:
  `rebuild` now deletes only notes it owns by front-matter signature, because
  the wholesale delete destroyed user-authored files in topic folders. The
  "catch-all for orphans" property is now partial — an orphan whose recording
  no longer exists survives.
- `Filer.removeNote` identifies a note with a substring `contains("signature:
  …")` while `rebuild` uses an exact-line match. Harmless while signatures are
  fixed width, but the same file now answers the same identity question two
  ways.

## Spec 4 deferred human checks

No agent in this project has a display, so the library window itself has
never been seen open. Everything below needs a person with the window in
front of them — recorded here so it isn't quietly assumed working just
because the layout test and the release build came back clean.

1. **The window opening at a sensible size, and the split being draggable.**
   Check: open the library window and confirm it starts at a reasonable size
   on screen, and that the sidebar/reader split can actually be dragged wider
   and narrower.
2. **Search returning moments, and clicking one seeking correctly.** Check:
   type a search term that should match something in a real transcript,
   confirm moments come back, click one, and confirm playback seeks to that
   point rather than somewhere nearby or not at all.
3. **Following highlighting the right line and detaching on a hand scroll —
   including a MOUSE WHEEL, not only a trackpad drag.** Check: play a
   recording and watch the transcript auto-scroll and highlight the current
   line, then scroll by hand and confirm following stops rather than fighting
   the manual scroll. Do it twice, once with a two-finger trackpad drag and
   once with a discrete mouse wheel. The detach is driven by
   `.onScrollPhaseChange { if phase == .interacting }`, and a trackpad drag
   reliably passes through `.interacting` because the fingers are on the glass
   for the whole gesture. A wheel notch has no such phase — it may go straight
   to `.decelerating` and never report `.interacting` at all, in which case
   following never detaches for wheel users and the view fights them for the
   rest of the recording. Unverifiable without a display and a real mouse.
4. **The Resume banner appearing and working.** Check: after detaching by
   hand-scrolling, confirm the "Following paused" banner appears, and that
   its Resume button jumps back to the current line and re-attaches.
5. **Editing a title and a topic, and seeing the note move in Finder.**
   Check: use the editor to change a recording's title and topic, then
   confirm in Finder that the note file actually moved to the new topic
   folder rather than leaving a stale copy behind.
6. **Speaker labels appearing only on a Deepgram transcript, never on an
   on-device one.** Check: open a recording transcribed with Deepgram and
   confirm speaker labels are present, then open one transcribed on-device
   and confirm no speaker label is shown, invented or otherwise.
7. **A recording with no transcript showing the not-yet state.** Check: open
   a recording that hasn't been transcribed yet and confirm the pane reads as
   "not transcribed yet" rather than blank or broken.
8. **Closing the window stopping playback.** Check: play a recording, close
   the library window while it is still playing, and confirm the audio stops
   rather than continuing with no window to control it.
   `LibraryWindow` has an explicit `.onDisappear { player.stop() }`, but only
   a person can confirm that a window CLOSE actually fires it — SwiftUI is
   free to keep a closed `Window` scene's `@State` alive, and `.onDisappear`
   timing on a scene rather than a subview is not something the tests can
   reach.
9. **The scrubber dragging smoothly.** Check: drag the transport bar's thumb
   across a long recording and confirm it tracks the pointer rather than
   stuttering or snapping back. One known stutter mechanism is now fixed in
   code — the binding's getter recomputes from `player.currentTime` instead of
   a per-body-pass snapshot, so a `get` landing between a `set` and the next
   pass no longer returns the pre-scrub position. What remains for eyes is the
   other direction: `AudioPlayer`'s periodic observer writes `currentTime` four
   times a second while the drag is writing it too, and whether those two fight
   visibly cannot be measured headlessly.
10. **The scrubber seeking to where it was dropped.** Check: drop the thumb at
    a recognisable point and confirm playback resumes from there, and that the
    elapsed/duration readout agrees with the transcript line highlighted
    underneath. `AudioPlayer.seek` now names zero tolerances, so this should be
    exact rather than nearest-sync-sample; confirm it, and confirm the exact
    seek does not make a fast drag feel sluggish on a long MP3.
11. **Following re-attaching after a scrub.** Check: hand-scroll the
    transcript until the "Following paused" banner appears, then scrub. The
    ruling is that a scrub re-attaches following, exactly as clicking a
    transcript line does — so confirm the banner clears and the transcript
    starts auto-scrolling again without touching Resume.
12. **The transport on a recording with no transcript.** Check: open a
    recording still in the transcription queue, confirm the pane reads "not
    transcribed yet" AND that the transport row underneath still plays it.
    That case had no way to play at all before this. (That the row is MOUNTED
    in both states is now asserted by
    `LibraryLayoutTests.theTransportRowIsMountedBelowARuleAtTheBottomOfThePane`;
    what needs a person is that it actually plays.)
13. **The scrubber being live the moment a recording is selected.** Check:
    select a recording and confirm the position bar is enabled and the readout
    shows the real length BEFORE pressing play — it should read e.g.
    `0:00 / 66:25`, not a dead grey bar reading `0:00 / --:--`. The length
    comes from `Sidecar.durationSeconds` until `AVPlayer` reports its own;
    confirm the two agree once playback starts rather than the bar jumping.
14. **The menu dismissing when a window opens — all THREE of them.** Check:
    open Library, then Settings, then Free Up Space, each from the menu, and
    confirm the popover goes away rather than staying up on top of the window
    it just opened. It is one shared `open(_:)`, so all three should behave
    identically; a menu that dismisses for one and not another is worse than
    the original bug. The fix is `@Environment(\.dismiss)` called before
    `NSApp.activate`, and **it is unverified** — `\.dismiss`'s documented
    behaviour covers being called from within a window and a `.window`-style
    `MenuBarExtra` hosts its content in one, but no agent here has a display
    and there is no test seam. If it does not work, the fix is to bridge an
    `NSViewRepresentable` to capture the popover's own hosting window and close
    that. Do NOT reach for `NSApp.keyWindow?.close()`: this popover does not
    activate the app, so key at that instant may be a different Steno window,
    and closing Settings out from under the user is a worse failure than the
    overlap. Also confirm the window still lands IN FRONT of other apps —
    that is what the `NSApp.activate` line exists for and it must not have
    been lost.
15. **The Dock icon appearing on library open and going away on close.**
    Check: with no window open, confirm Steno has no Dock icon. Open the
    library and confirm one appears and that ⌘-Tab can now switch away and
    back. Close the library and confirm the icon goes away again. Then the
    awkward case: **open Settings, open the library, close the library while
    Settings is still up** — confirm Settings does not get pushed behind
    another app or reordered when the app drops to `.accessory`. That last one
    is the real unknown; `setActivationPolicy` is documented not to close or
    reorder windows, but an app resigning active as it leaves `.regular` is
    plausible and cannot be checked without a display.
    While the icon is up, glance at the **main menu bar**, which this app has
    never had before. It should carry a working ⌘W and ⌘Q and nothing dead —
    there is no `WindowGroup`, so no "New Window", and no `Settings` scene, so
    no ⌘, that opens nothing. If something dead is in there, say so.
    If `.onDisappear` does not fire on a scene close, the icon stays until
    relaunch. That is accepted as cosmetic and self-correcting — but note it
    shares its trigger with `player.stop()`, so check 8 passing means this
    fired too, and check 8 failing means both did not.
16. **Reopening the window restoring playback.** Check: play a recording,
    close the library window, reopen it, and confirm the play button and the
    transcript lines still work rather than being silent no-ops. This is the
    reopened-`@State` case: the selection survives the close, the player does
    not, and `.onChange(of: store.selection)` cannot fire for a selection that
    never changed. `LibraryWindow.task` now reloads the audio for the surviving
    selection, but only a person can confirm a real scene close-and-reopen
    behaves the way the model says.

**Filing has still never run on the real library.** Zero topic folders exist
under the real library root — the sidebar's topic grouping has only ever been
exercised against fixtures, never against a real directory tree, until either
a filing directive is actually spoken during a recording or a topic is set by
hand in this window.

## Spec 5 deferred human checks

No agent in this project has a display or a way to simulate a real tap, so
everything below needs a person with the app open and a finger on the
trackpad — recorded here so it isn't quietly assumed working just because the
layout and pure-function tests came back clean.

1. **A speed change being audible, and holding across recordings and across a
   relaunch.** Check: change the playback speed, confirm it is audibly faster
   or slower, then switch to a different recording and relaunch Steno, and
   confirm the chosen speed is still applied rather than reset to 1x.
2. **±10s landing ten seconds away, and re-attaching following when it was
   detached.** Check: hand-scroll the transcript until following detaches,
   tap ±10s, and confirm both that playback actually moved ten seconds and
   that the transcript resumes auto-scrolling.
3. **Changing speed does *not* move the transcript.** Check: change speed
   mid-line and confirm the highlighted transcript line does not jump — only
   elapsed time should move faster, not position.
4. **The remaining/total label toggling on click.** Check: click the time
   label and confirm it switches between showing total duration and
   remaining time.
5. **Hovering the title and the topic revealing the affordance before you
   click.** Check: hover each field without clicking and confirm some visual
   cue appears before any click happens.
6. **Return commits and Esc restores, for both the title and the topic
   field.** Check: edit each field and press Return, and confirm the new
   value sticks; edit again and press Esc, and confirm it reverts to what was
   there before.
7. **A refused topic name keeping the field open with what was typed, and
   showing the reason underneath.** Check: type a topic name that gets
   rejected and confirm the field stays open with the rejected text still in
   it and an explanation shown, rather than silently discarding it or
   closing.
8. **The combo box's chevron opening a list of the existing topics plus
   "None — unfile this."** Check: click the chevron and confirm the dropdown
   lists every topic currently in use, plus an unfiling option — and that
   picking one COMMITS it, closing the field with the new topic filed,
   rather than only filling the text field in and waiting for Return.
9. **The transport's disabled state — no known duration.** This is only
   reachable on a recording whose audio is missing entirely, and has never
   actually been seen. If one turns up, confirm the transport reads as
   disabled rather than showing a broken or infinite duration.

Four more came out of the review rounds, each recorded here because no test
on this branch can reach it:

10. **The chevron's on-screen legibility.** Task 5 proved by ink-area
    measurement that the fixed construction draws ~2.17× the ink of the
    broken one, but that measures the construction in isolation — not that
    `RecordingEditor`'s own tree draws it at a readable size under a real
    tap. Check: look at the chevron in the running app and confirm it reads
    clearly, not just that it measures bigger in isolation than before.
11. **That a live tap reaches the edit handlers at all.** `@State` on a
    detached view constructed in a test is inert — writes are accepted and
    silently dropped, because the storage only materialises once installed
    in a live hierarchy — and the suite has no gesture-simulation
    infrastructure. So click-to-edit, Return-commits, Esc-restores, the
    seed-from-disk on entry, and the menu selections (checks 5–8 above) are
    all unverified by machine; only a live tap in the running app proves them.
    What IS machine-checked is the decision each of those wires up: the
    commit-time pair in `RecordingEditorTests`
    (`committingTheTitleWritesTheTopicTheSidecarHasNow` and its mirror), which
    is where the final review's Critical actually lived. The wiring that calls
    it stays a human check. (The entry-time SIBLING resync those checks used
    to cover is gone — once a commit sources the untouched field from
    `recording.sidecar`, resyncing that field's `@State` on the other one's
    tap was a no-op in both of its branches.)
12. **That ±10s actually re-attaches following.** The rule is "anything that
    moves the playhead re-attaches"; `skip(by:)` implements it, but nothing
    asserts the call site — the same gap exists for `scrub(to:)` and the
    line tap. Check 2 above is the human check that closes this; it covers
    all three trigger paths, not just ±10s.

The fourth, "that changing speed does not move the transcript", was **not**
a human check after all and is now asserted:
`AudioPlayerTests.changingSpeedDoesNotMoveThePlayhead`. The transcript
follows `player.currentTime`, so the whole rule is reachable through the
injectable-defaults seam — no display, no audio hardware, no real file.
Mutation-checked: adding `currentTime = 0` to `setRate` passed all 361 tests
before it was written. Check 3 above stays only for what a person still adds
over it: that the highlighted line on screen does not visibly jump.

## Spec 5 carried debt (`feat/player-polish`, 2026-08-07)

Filed out of the final fix wave's re-review so that none of it lives only in a
report. None blocks merge; all five were adjudicated.

**`timestamp(_:)`'s `%ld` has no regression test.** The format was `%d`, which
reads 32 bits while Swift passes `Int` as 64, so at the clamp ceiling it
rendered `-2101409110:40` — a negative stamp. That is fixed. What is missing is
a guard: reverting `%ld` to `%d` passes all 365 tests, because `%d` corrupts
`.infinity`, `1e300` and `.nan` *identically*, so the existing comparison-based
assertions still hold. One line closes it:
`#expect(TranscriptPane.timestamp(TranscriptPane.stampCeiling) == "16666666666666:40")`.
The final-fix report claimed this was already covered; it was not.

**The Critical's residual: `recording.sidecar` is only as fresh as the last
reload.** The commit-time fix sources each field's sibling from
`recording.sidecar` rather than stale `@State`, which closes the tap-to-Return
window. But `LibraryWindow` reloads on `transcriptionProgress` going nil, and
`AppModel` sets that only in the sweep task's `defer` — when the *whole queue*
drains — while updating progress per recording without triggering a reload. So
during a multi-recording sweep, recording A's new topic is on disk but not yet
in `recording.sidecar`, and a Return in that window still commits the stale
value. Strictly narrower than what was fixed, and not closable while `AppModel`
stays untouched: `updateRecording(_:title:topic:)` takes a whole edit and
already spends `nil` on "unfile", so there is no way to say "leave this field
alone." Wants the patch-shaped-edit API filed under Spec 4 carried debt.

**Two doc comments assert more than was measured.** `ThrowawayDefaults`' comment
says overriding only the `Any?` variant would have let `AudioPlayer`'s write
reach the real domain — built and measured, it would not: `setDouble:forKey:`
routes through `setObject:forKey:`. The typed-setter overrides are harmless
belt-and-braces, not the load-bearing fix the comment claims. Separately,
`AudioPlayerTests` says one `ThrowawayDefaults` is shared *between tests*;
Swift Testing builds one suite instance per test, so the sharing is between the
two `player()` calls within a single test, as `ThrowawayDefaults`' own comment
correctly says.

**Picking a topic from the menu during an in-flight save looks committed and is
not.** The selection sets `topic`, so the field visibly shows the choice, but
`save()`'s `guard !isSaving` returns without writing and without a message.
Consistent with the Return path, but the menu path now *looks* like it took.

**`LegacyMigrationTests` leaks a plist per run into `~/Library/Preferences`.**
Pre-existing and unrelated to spec 5, but large: 4,342 empty 42-byte
`LegacyMigrationTests.*.plist` files had accumulated and were removed by hand
this session, and ~19 more appear per `swift test`. The `AudioPlayerTests` leak
found during this branch was fixed with a dictionary-backed `UserDefaults`
subclass (`Tests/StenoUITests/ThrowawayDefaults.swift`) after `removePersistentDomain`
proved insufficient — cfprefsd rewrites the file after the process exits. The
same substitute is what `LegacyMigrationTests` needs.
