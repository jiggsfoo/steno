# Spec 2 priming — transcription and AI filing

Handoff for a fresh session. Specs 1 and 1.5 are shipped and merged to `main`;
the app is in daily use. Read this before touching anything.

**Start with `superpowers:brainstorming`.** Nothing here is a design. It is the
ground the design has to stand on.

## What spec 2 builds

From the original wishlist, items 3 and 4:

3. **Transcription with a user-selectable model.** The user picks which model
   transcribes; the choice is theirs, not baked in.
4. **AI filing with prompt directives.** Spoken instructions inside the
   recording steer where it lands — *"File this under 'Grocery List'"* should
   put it under Grocery List. The directive is part of the audio, not a
   separate UI step.

Item 5 (routing P1 audio during calls) is **spec 3** and is no longer
speculative — see "Ready to plan" in `docs/superpowers/follow-ups.md`. Item 6
(Vibe Mic) is unscheduled. Do not fold either into spec 2.

## What already exists

macOS menu bar app, Swift 6, zero third-party dependencies, 161 tests.

| Module | Holds |
|---|---|
| `JensenKit` | USB transport and the Jensen wire protocol. Pure device I/O. |
| `StenoUI` | Everything else — model, sync, library, index, views. |
| `StenoApp` | `@main`, two `Window` scenes plus the `MenuBarExtra`. |
| `StenoCLI` | `steno probe\|info\|list\|pull\|watch`. |

Sync is done and reliable: recordings land byte-exact, the menu bar icon shows
device state in five shapes, and nothing is ever deleted without an explicit
confirmed action.

### The data model you are extending

Each recording is an `.mp3` plus a `.json` sidecar, in dated folders under the
library root (`~/Recordings/Steno` by default, overridable and stored in
`UserDefaults`):

```json
{
  "signature": "c8357e00d535682319c8e19d50685d1a",
  "deviceFilename": "2026Aug05-130006-Rec09.hda",
  "relativePath": "2026-08-05/130006-c8357e00.mp3",
  "recordedAt": "2026-08-05T05:00:06Z",
  "timeZoneIdentifier": "Asia/Manila",
  "durationSeconds": 3984.576,
  "lengthBytes": 47814924,
  "deviceSerial": "HDP1254506027",
  "deviceModel": "hidock-p1"
}
```

`~/Library/Application Support/Steno/index.sqlite` mirrors this in a
`recordings` table keyed on `signature`, with an index on `recorded_at DESC`.

**The sidecar is the source of truth; the index is a derived cache** — its own
doc comment says so, and `rebuildIndex()` reconstructs the index from sidecars.
Decide deliberately where a transcript lives. A transcript is expensive to
recompute (money and time), so treating it like the index — throwaway, derived —
would be wrong. It belongs with the sidecar or beside it, not only in SQLite.

`deviceModel: "hidock-p1"` is **persisted in every existing sidecar**. Changing
that string desyncs the user's library. It survived the rename for that reason.

### UI you can build on

`MenuRow` already takes an optional second line, added in spec 1.5 specifically
so transcript titles are an extension rather than a rewrite. Recent rows
currently show a timestamp and a duration; the second line is free.

`MenuMetrics` holds the menu geometry matched to a real `NSMenu`. Settings has
`Library`, `Diagnostics`, `Startup`, and a conditional `Last Error` section —
model selection needs a home there.

## Hard constraints — these are not negotiable

**Device safety.** Never send `DELETE_FILE`, `SET_DEVICE_TIME`, or any Bluetooth
command. The user's P1 holds real recordings and has AirPods paired via
BlueCatch. No test may require an attached P1. No test may write to
`~/Library/Logs/Steno/`.

**The standing rule, earned the hard way:** *a redundant download is a better
failure than a confident lie.* It is written into the sync code. It applies just
as well to transcripts — a second transcription costs money, but a transcript
attached to the wrong recording is worse.

**No third-party dependencies.** This has held through two specs. Transcription
will tempt you to break it. If a model runs locally, or an API needs a client,
weigh that against the constraint explicitly in the spec rather than quietly
adding a package.

**Privacy is a design input, not a footnote.** These are the user's meetings.
Sending audio to a third-party API is a real decision with real consequences,
and "which model" is partly a question of what leaves the machine. Surface it in
the brainstorm; do not assume cloud.

**Swift 6 strict concurrency, zero warnings, Swift Testing never XCTest.**

## Traps specific to this codebase

**`isAlreadySynced`'s fallback is weaker than the old gate, and spec 2 makes it
worse.** From `follow-ups.md`: when the index has no row for a signature, it
falls back to checking the computed path against the *device-reported* length,
and it also gates `reclaimable`/`deleteFromDevice`. **Filing by AI-derived title
changes how paths are computed** — that is exactly the change the follow-up
warns about. Tighten this before adding title slugs, not after.

**Renaming or moving files breaks `relativePath`.** Every sidecar stores it and
the index mirrors it. AI filing moves files by definition. Whatever moves a
recording must update both, atomically enough that a crash cannot leave them
disagreeing.

**Do not read `SyncEngine`, `AppModel`, `Library`, `LibraryIndex` or
`DeviceMonitor` as fair game for restructuring.** They shipped, they work, and
spec 1.5 held a no-behaviour-change guarantee across 27 commits. Extend them;
do not tidy them.

**`MenuBarExtra` will lie to you.** Two defects on this project came from it:
`.window` content is built lazily so `.task` never fires until first click, and
a `.sheet` inside the popover is stranded when AppKit tears it down. Long-lived
UI belongs in a `Window` scene — Settings and Reclaim both are.

**No agent here has a display.** `screencapture` returns black frames and
VoiceOver cannot be driven headlessly. `ImageRenderer` *does* work and was used
to measure real geometry. Anything visual is either measured or handed to the
user — never claimed.

## Where things live

- Ground truth about the hardware: `docs/device-reference.md`. **Where it
  conflicts with a spec, it wins.** It also carries a corrections log of about
  ten disproved beliefs — read it before theorising about the device.
- Open items and deferred hardware checks: `docs/superpowers/follow-ups.md`
- Shipped specs and plans: `docs/superpowers/specs/`, `docs/superpowers/plans/`

## Process

`superpowers:brainstorming` → spec → `superpowers:writing-plans` → 
`superpowers:subagent-driven-development`. That is what built specs 1 and 1.5.

Two things worth carrying from spec 1.5's review loop:

- **Per-task reviews cannot see a later task undoing an earlier one's
  guarantee.** Three defects had exactly that shape and only the whole-branch
  review caught them. Budget for it.
- **A test that passes by construction is worse than no test.** Six were caught
  on the last branch, each one looking fine. Mutation-check anything load-bearing:
  revert the fix, confirm the test fails, restore.
