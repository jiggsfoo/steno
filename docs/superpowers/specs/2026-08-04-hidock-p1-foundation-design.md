# HiDock P1 native Mac app: foundation (spec 1)

- **Date:** 2026-08-04
- **Status:** approved, ready for implementation planning
- **Scope:** menubar presence + auto-sync. Wishlist features 1 and 2.

## Context

Angelo records meeting notes and personal voice memos on a HiDock P1. The official
companion app (hinotes.hidock.com) is a clunky web app. This project replaces it with
a native Swift macOS app.

The original framing was "reverse-engineer the companion app". That turned out to be
unnecessary. The device protocol has already been reverse-engineered by the community
and published under MIT. This spec is therefore a **port**, not an RE project.

Prior art (both MIT, both used as protocol reference only, no code copied):

- `sgeraldes/hidock-next`, specifically `packages/jensen-protocol/src/jensen-device.ts`
- `ghecko/OpenHiNotes`

Neither is a native Mac app. One is Python/Tkinter plus a React web app, the other is a
Dockerised FastAPI/React stack. Both require WebUSB or a Python bridge. That is exactly
what this project is avoiding.

## Goals

1. A menubar item that always reflects whether the P1 is connected.
2. New recordings copy themselves to the Mac automatically, with zero interaction.
3. Never lose a recording.
4. Leave a clean foundation for spec 2 (transcription and AI filing).

## Non-goals for this spec

Transcription, AI filing, prompt directives ("file this under grocery list"), audio
routing to Meet/Zoom, Vibe Mic support, `.hda` conversion, interrupted-transfer resume,
HiNotes cloud import, and support for device models other than the P1. These are either
deferred to spec 2 / spec 3 or dropped.

## Decisions

| # | Decision | Rationale |
|---|---|---|
| 1 | Build features 1+2 only. AI is spec 2, audio routing and Vibe Mic are spec 3. | Six features span USB, menubar, AI transcription, AI classification, CoreAudio and Bluetooth HID. Too much for one spec. Foundation first also validates the Swift protocol port against real hardware before anything is built on it. |
| 2 | Visible files are the source of truth. SQLite index is a rebuildable cache. | Finder-browsable, greppable, Obsidian/iCloud friendly. The app can never strand data. Spec 2 writes transcripts as markdown next to the audio. |
| 3 | Never auto-delete from the device. Reclaim is a manual, explicitly confirmed action. | No retention engine to build or debug in v1, and no auto-sync bug can ever destroy a recording. |
| 4 | Menubar only. No library window. | Finder and QuickLook already browse and play audio. Spec 2 needs a purpose-built window once transcripts exist; building one now would mean designing it twice. |
| 5 | Clean break from HiNotes. No cloud import. | Avoids an authenticated-scraping subsystem against an undocumented API that can change under us. The app owns the device. |
| 6 | Personal build now, but the protocol layer is a standalone SPM package. | Costs almost nothing today and makes open-sourcing later a packaging job rather than a rewrite. Also gives the packet layer a test seam. |

## Protocol reference

Established from `hidock-next`. All of this needs confirming against Angelo's actual
device during step 1 (see Build order).

**Identification**

- Vendor IDs: `0x10d6` (Actions Semiconductor), `0x3887` (newer HiDock)
- P1 product IDs: `0xaf0e`, `0xb00e`, `0x2040`
- Configuration 1, interface 0, alternate setting 0. This is a vendor-specific
  interface, so no macOS kernel driver claims it.
- Bulk endpoints: OUT `0x01`, IN `0x82`

**Framing** (12-byte header, big-endian, followed by body)

```
offset  size  field
0       2     sync marker, always 0x12 0x34
2       2     command id (u16)
4       4     sequence (u32)
8       4     top byte = padding length, bottom 24 bits = body length
12      n     body
```

**Commands used by this spec**

| Code | Name | Use |
|---|---|---|
| 1 | `GET_DEVICE_INFO` | model, serial, firmware version |
| 2 | `GET_DEVICE_TIME` | drift check |
| 3 | `SET_DEVICE_TIME` | correct drift; the device clock names recordings |
| 4 | `GET_FILE_LIST` | returns name, createDate, createTime, duration, version, length, signature |
| 5 | `TRANSFER_FILE` | streamed download |
| 6 | `GET_FILE_COUNT` | sanity check against list length |
| 7 | `DELETE_FILE` | manual reclaim only |
| 16 | `GET_CARD_INFO` | used / capacity / free |
| 4100 | `GET_BATTERY_STATUS` | menubar display |

Known but deliberately unused in this spec: `GET/SET_SETTINGS(11/12)`,
`GET_FILE_BLOCK(13)`, `TRANSFER_FILE_PARTIAL(21)`, `REALTIME_CONTROL/TRANSFER(33/34)`,
Bluetooth commands (`4097`-`4104`), firmware upgrade (`8/9`), `FORMAT_CARD(17)`,
`RESTORE_FACTORY_SETTINGS(19)`, `FACTORY_RESET(61451)`.

**Recording formats. Corrected 2026-08-04 against real hardware.** This section
originally assumed firmware 1.4.3 wrote `.mp3`/`.wav` and that `.hda` was a legacy format
needing a WAV-header wrapper. Both assumptions were wrong.

Angelo's P1 runs firmware **1.4.5** and writes `.hda` for every recording. A pulled `.hda`
proved to be **plain MPEG-1 Layer III**: de-framing the transfer yields exactly the
device-reported byte count, and `afinfo` reports `1 ch, 48000 Hz, .mp3`, 96 kbps, with a
correct duration. `file(1)` agrees: `MPEG ADTS, layer III, v1, 96 kbps, 48 kHz, Monaural`.

So no wrapper and no transcoding are needed. `.hda` is MP3 under a proprietary extension,
and correcting the extension on write is sufficient for Finder, QuickLook and AVFoundation.
Bytes are stored exactly as the device sends them; the original device filename is kept in
the sidecar. Device filenames are timestamp-based (`2026Aug04-135302-Wip02.hda`).

**Sizing note.** WAV 768 kbps is roughly 170 MB for a 30-minute recording. Transfers must
stream to disk, never buffer in memory. At the observed MP3 96 kbps a 30-minute recording
is a far more modest ~21 MB, but the streaming requirement stands: the WAV mode exists in
firmware and a long meeting is still large enough that buffering it is wasteful.

**Transfer framing, verified 2026-08-04.** `TRANSFER_FILE` payloads arrive as ordinary
Jensen packets (command 5, echoing the request sequence), not as a raw byte stream. A
single bulk read coalesces several: a 53,568-byte recording arrived as 7 packets in ONE
53,652-byte read. The device layer's decode loop must therefore drain multiple packets per
buffer, which it does.

## Architecture

```
        MenuBarExtra (SwiftUI)
                 |  observes
        AppModel  @MainActor @Observable
                 |
   DeviceMonitor ---> SyncEngine (actor) ---> Library
   (IOKit notify)          |               (files + SQLite)
                 +-----------------+
                 |   HiDockKit     |   SPM package, no app dependencies
                 |  JensenDevice   |   actor
                 |  JensenPacket   |   pure value type
                 |  USBTransport   |   protocol
                 +-----------------+
                           |
                 IOUSBHostTransport
```

Everything inside `HiDockKit` is hardware-independent behind the `USBTransport` protocol
and testable without a P1 attached.

### HiDockKit

| Type | Responsibility | Depends on |
|---|---|---|
| `JensenPacket` | Encode and decode the 12-byte frame. No I/O, pure functions. | Foundation |
| `USBTransport` | `protocol { open, close, write, read }`. The test seam. | Foundation |
| `IOUSBHostTransport` | Real hardware. Claims config 1 / interface 0 / alt 0, bulk `0x01` and `0x82`. | IOUSBHost, IOKit |
| `JensenDevice` | `actor`. Command queue, sequence assignment, response matching, timeouts, endpoint draining. | `USBTransport`, `JensenPacket` |
| Models | `DeviceInfo`, `FileInfo`, `CardInfo`, `BatteryStatus` | Foundation |

`JensenDevice` is an `actor` guarding a shared read buffer, plus an explicit FIFO gate
that keeps exactly one command on the wire at a time.

**Corrected 2026-08-04, during implementation.** This section originally claimed the actor
alone enforced the one-outstanding-command invariant "for free" via its serial executor.
That is false. Swift actors are reentrant: isolation protects state *between* suspension
points, it does not make an `async` method body atomic. Two concurrent callers both reach
`transport.write` before either reads a response, putting two commands on a wire that
permits one. Demonstrated empirically during Task 3's review. The invariant needs the
explicit gate; the actor only makes the buffer and sequence counter safe to touch.

**Also corrected: the device does echo the request sequence.** Measured against a real P1
with sequences `0x00000000`, `0x00000007`, `0x00003039`, and `0xDEADBEEF`, all returned
byte-identical. Responses are therefore matched on **(command id, sequence)** rather than
command id alone, which is what prevents a late response from an abandoned command from
satisfying its own retry.

`transferFile` streams chunks to a file handle and reports progress. It does not return
a `Data`.

### App

| Type | Responsibility |
|---|---|
| `DeviceMonitor` | `IOServiceAddMatchingNotification` filtered on the VID/PID set. Publishes attach and detach. Re-scans on wake from sleep. |
| `SyncEngine` | `actor`. Orchestrates connect, clock sync, list, diff, download, verify, commit. Emits progress. |
| `Library` | Owns the recordings folder and the derived SQLite index. |
| `AppModel` | `@MainActor @Observable` menubar state. |
| `MenuBarView` | SwiftUI `MenuBarExtra`. |

## Library layout

```
<root chosen by user>/
  2026-08-04/
    143022.mp3        audio, byte-identical to what the device sent
    143022.json       sidecar
  .incoming/
    <signature>.part  in-flight downloads only

~/Library/Application Support/HiDock/index.sqlite
    recordings(signature PK, device_name, path, length,
               duration, recorded_at, synced_at)
```

Sidecar JSON carries the full record: device filename, signature, byte length, duration,
recordedAt, syncedAt, device model, device serial, source format. Because sidecars hold
everything, the SQLite index is disposable and rebuilt by walking the folder.

Identity is the device-reported `signature`, not the path. Spec 2 can therefore append a
title slug to filenames (`143022-standup.mp3`) without breaking sync.

## Sync flow

1. P1 attaches, `DeviceMonitor` fires.
2. Open transport, claim interface 0, wait 300 ms for firmware readiness, `GET_DEVICE_INFO`.
3. `GET_DEVICE_TIME`. If drift exceeds 60 s, `SET_DEVICE_TIME`.
4. `GET_FILE_COUNT`, then `GET_FILE_LIST`.
5. Diff on `signature`. Skip anything already indexed whose file exists on disk at the
   recorded byte length.
6. For each new file, oldest first:
   a. Check free disk space against `FileInfo.length`. Abort the file if insufficient.
   b. `TRANSFER_FILE`, streaming to `.incoming/<signature>.part`, reporting progress.
   c. Verify received byte count equals `FileInfo.length`.
   d. Atomically move into `<root>/YYYY-MM-DD/HHMMSS.<ext>`, where the date and time come
      from the parsed device timestamp and `<ext>` is carried over from the device
      filename unchanged.
   e. Write the sidecar, then insert into the index.
7. Nothing is deleted from the device at any point in this flow.

The 300 ms settle in step 2 comes from `hidock-next`, which notes some devices reject
commands immediately after interface claim.

## Reclaim flow (manual only)

1. User selects "Free up space on P1..." from the menubar.
2. For each device file, re-verify **at that moment**: local file exists and its byte
   length matches the sidecar. A stale index row is not sufficient evidence.
3. Show only files that pass. User confirms.
4. `DELETE_FILE` per file, then refresh the listing.

## Menubar

The entire UI surface for this spec.

```
+- HiDock ----------------+
| * P1 connected      87% |   status, battery
|   12.4 GB free          |   from GET_CARD_INFO
+-------------------------+
| Syncing 2 of 3...       |   only while syncing
| ########....      64%   |
+-------------------------+
| Recent                  |   last 5 synced, newest first
|   Aug 4  14:30   12:04  |   date, time of day, duration
|   Aug 4  11:02   31:22  |
+-------------------------+
| Reveal in Finder        |
| Free up space on P1...  |   disabled when disconnected
| Settings...             |
+-------------------------+
```

Recent entries show date, time of day and duration, because the foundation has no titles.
Spec 2 replaces these with AI-derived titles. Clicking an entry reveals it in Finder.

The status line has four states: connected and idle, syncing, `P1 busy`, and
`P1 unavailable`. Disconnected collapses to a dimmed icon with `No device`.

Settings holds exactly three things: the library root folder picker, a launch-at-login
toggle (`SMAppService`), and a "Rebuild index" button.

## Error handling

| Failure | Behaviour |
|---|---|
| Interface claim fails (in use, permissions) | Menubar shows "P1 unavailable". Retry with backoff. Never busy-loop. |
| Device busy (recording, or in Vibe Mic Bluetooth mode) | Commands time out. Show "P1 busy", back off, retry on next attach. |
| Unplugged mid-transfer | `.part` remains, nothing commits. Next attach restarts that file. `.part` is keyed by signature so retries do not accumulate orphans. |
| Command timeout | Clear the read buffer and drain the IN endpoint before the next command. Both halves are required. A stranded partial packet's declared length would swallow the next response, and because its sync marker is intact `invalidHeader` never fires to clear it. Draining must span several quiet windows, not stop at the first empty read: an empty read means "nothing arrived in this window", and the response being guarded against is precisely the late one. |
| Invalid packet header | Transport is desynced. Drop the read buffer, drain, reconnect. No mid-stream resync attempt. |
| Received bytes != `FileInfo.length` | Discard `.part`, do not commit. Retry once, then surface the failure. A truncated recording must never enter the library. |
| Disk full | Pre-check before starting the transfer. Fail fast rather than writing a partial file. |
| Library folder unreachable (external volume, iCloud eviction) | Pause sync and surface it. Never silently recreate the folder at the old path. |
| Index and sidecars diverge, or schema version changes | Rebuild the index from sidecars. |
| Multiple P1s attached | Bind to the first device seen, keyed by IOKit service id. Ignore the rest and note it in the menubar. |
| Sleep and wake | Release the interface on `NSWorkspace.willSleepNotification`. On `didWakeNotification`, re-scan for an already-attached device, because IOKit match notifications do not reliably re-fire across sleep. |

**Timezone handling.** The P1 has no timezone concept and its local clock names the
recordings. Device time is interpreted as local wall time in the Mac's current timezone at
sync time. The sidecar records both the raw device timestamp and the resolved timezone, so
spec 2 can correct any recording synced in a different timezone from where it was made.

## Testing

Packet codec and sync diff are complex logic, so they are written test-first.

- **`JensenPacket`** — round-trip encode/decode, golden fixtures from captured frames,
  and the edge cases: u24 body length with the padding byte, one packet split across two
  reads, two packets in a single read, invalid sync marker.
- **`JensenDevice`** — `FakeTransport` conforming to `USBTransport` with scripted
  request/response pairs. Covers sequence assignment, response matching, timeout,
  drain-after-timeout, and command serialization under concurrent callers.
- **`SyncEngine`** — fake device plus a temp directory. Fresh sync, re-sync is a no-op,
  interruption leaves `.part` uncommitted, byte-count mismatch rejected, disk-full
  pre-check, detach mid-run.
- **`Library`** — index rebuild from sidecars, atomic move semantics.

No test in the suite requires a P1 to be attached.

## Build order

Ordered so the riskiest assumption is tested first.

1. **`hidock-cli`** (`info`, `list`, `pull <name>`), a small executable target in the
   package. The single riskiest assumption in this design is that a Swift `IOUSBHost` port
   actually talks to the P1. This proves it against real hardware on day one, with no
   SwiftUI in the way.
2. `JensenPacket` plus tests.
3. `JensenDevice` plus `FakeTransport` tests.
4. `Library` and the index.
5. `SyncEngine`.
6. `DeviceMonitor`.
7. `MenuBarExtra` UI and settings.
8. Login item via `SMAppService`.

## Hardware validation checklist

To confirm during step 1. Each has a defined fallback, so none of them blocks the build.

| Assumption | If wrong |
|---|---|
| P1 enumerates with one of the listed VID/PID pairs | Read the actual pair from `system_profiler SPUSBDataType` and add it. |
| Interface 0 is claimable from a non-sandboxed app via `IOUSBHost` | Fall back to the legacy `IOKit`/`IOUSBLib` plugin interface. Same endpoints, gnarlier C interop. |
| Device responds to `GET_DEVICE_INFO` after a 300 ms settle | Increase the settle delay, or retry the first command. |
| ~~Recordings on the device are `.mp3` or `.wav`~~ **RESOLVED 2026-08-04: they are `.hda`, which is MP3.** | No wrapper needed. `FileInfo.preferredExtension` maps `.hda` to `.mp3`; bytes untouched. |
| P1 also enumerates as a USB Audio Class device | Only affects spec 3. If it does not, audio routing needs a CoreAudio HAL plugin fed by `REALTIME_TRANSFER(34)`, which is substantially more work. |

## Open decisions deferred to later specs

- Which transcription models to offer, and local versus cloud (spec 2).
- Where AI filing routes notes to, for example Obsidian, Reminders, or plain folders (spec 2).
- Whether Vibe Mic dictation is handled in-app or delegated to an existing tool (spec 3).
  The Vibe Mic testing guide is a JS-rendered Notion page that could not be read
  programmatically; it needs a browser session or a manual walkthrough on the device.
