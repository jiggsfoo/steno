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
