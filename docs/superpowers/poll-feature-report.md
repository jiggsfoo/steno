# Idle-poll auto-sync — implementation report

## What was built

1. **`JensenCommand.getRecordingFile = 18`** (`Sources/HiDockKit/JensenCommand.swift`).
2. **`JensenDevice.recordingFile(timeout:)`** (`Sources/HiDockKit/JensenDevice.swift`) — sends
   command 18, strips NUL bytes, returns `nil` for an empty/blank body, otherwise the in-progress
   recording's filename. Implemented exactly as specified.
3. **`AppModel` poll loop** (`Sources/HiDockMenubar/AppModel.swift`):
   - `pollTask: Task<Void, Never>?` — one long-running loop, started by `startPolling()` right
     after a sync completes successfully inside `startSync()`'s task (both the attach-triggered
     sync and any poll-triggered sync land on this same call site, and `startPolling()` is a no-op
     if already running).
   - Interval: 3s while `recordingInProgress != nil`, 10s otherwise, computed fresh each iteration
     via `MainActor.run`.
   - `pollTick()` mirrors `startSync`'s open/do/close discipline: opens its own
     `IOUSBHostTransport`/`JensenDevice`, does its work, and closes it on every path (capture the
     error, close unconditionally, then handle) — the interface is free between ticks. If
     `syncTask != nil` or `isReclaiming`, the tick returns before touching the transport at all. If
     `openFirstAvailable()`/`device.open()` throws, the tick returns quietly (no status/error
     change) — busy-or-gone is `DeviceMonitor`'s job. A transient read failure mid-tick also just
     skips quietly rather than overwriting `lastError`/`status` set by a real sync or reclaim.
   - On success: calls `recordingFile()`; if non-nil, publishes it and stops. If nil, calls
     `fileCount()`, compares against `index?.all().count` (the local synced count), and calls
     `startSync()` — as its own independent open — when `shouldSyncAfterPoll` says so.
   - `nonisolated static func shouldSyncAfterPoll(recording:deviceFileCount:localCount:)` — pure,
     exactly as specified. Marked `nonisolated` because a static member of a `@MainActor` class is
     MainActor-isolated by default, which would force the synchronous unit tests onto the main
     actor for no reason.
   - `.detached` now also cancels/nils `pollTask` and clears `recordingInProgress`.
   - `public func syncNow()` — guards on `syncTask == nil` and `!isReclaiming` exactly like the
     existing guards, otherwise sets a `lastError` explaining which one blocked it.
4. **`AppModel.recordingInProgress: String?`** (public, private(set)), cleared on detach.
5. **`MenuBarView`** (`Sources/HiDockMenubar/MenuBarView.swift`): a red "Recording..." /
   "Recording: <name>" label shown whenever `recordingInProgress != nil` (name only shown if every
   character is printable ASCII — command 18's body layout beyond "empty means idle" is
   unverified, so anything else falls back to the bare label); a "Sync now" button in the actions
   section calling `model.syncNow()`, disabled when `status == .disconnected`.

## Design notes / deviations

- No existing "close()-equivalent teardown" method exists on `AppModel` (it's a singleton that
  lives for the app's process lifetime — see `AppDelegate` in `HiDockApp.swift`). The only
  teardown-like path is `.detached`, which is where the poll task is cancelled.
- `startPolling()` is called from the *existing* successful-sync completion point in `startSync()`
  rather than only from the `.attached` handler, so a poll-triggered sync re-arms the loop the same
  way an attach-triggered one does — this was necessary for the loop to keep running across a
  poll-triggered sync/resync cycle.

## Tests added (all passing)

`Tests/HiDockKitTests/JensenDeviceTests.swift`:
- `recordingFileReturnsNilForAnEmptyBody`
- `recordingFileReturnsTheNameForANonEmptyBody`
- `recordingFileStripsTrailingNULs`

`Tests/HiDockMenubarTests/AppModelTests.swift` (new file):
- `pollDoesNotSyncWhileARecordingIsInProgressEvenIfDeviceCountIsHigher`
- `pollSyncsWhenIdleAndTheDeviceHasMoreFilesThanLocal`
- `pollDoesNotSyncWhenIdleAndCountsAreEqual`

## Verification performed

- `swift build` — clean, zero warnings.
- `swift test` — **85 tests, 0 failures** (79 existing + 6 new).
- `./Scripts/make-app.sh release` — built `build/HiDock.app` successfully.
- Quit the copy of HiDock.app that was already running from `/Applications` before touching the
  device (`osascript -e 'tell application "HiDock" to quit'`), confirmed via `ps aux` that no
  HiDock process was running before and after CLI testing.
- `swift run hidock-cli probe` — `PROBE OK`.
- `swift run hidock-cli info` — `INFO OK`, firmware/serial read back correctly.
- `swift run hidock-cli list` — `LIST OK`, device reports **8** files (all listed, all with valid
  names/sizes/timestamps/signatures). No `DELETE_FILE`, `SET_DEVICE_TIME`, or any Bluetooth command
  was sent by any code path touched in this change — `list`/`info`/`probe` are read-only, and the
  new `recordingFile`/`fileCount`/poll code path only ever calls `GET_RECORDING_FILE`,
  `GET_FILE_COUNT`, and (via `startSync`) the existing read/transfer path.
- Confirmed the AirPods-via-BlueCatch pairing was not touched: no Bluetooth command exists anywhere
  in this diff.
- Left no HiDock process running at the end.

## What could NOT be verified

The actual acceptance scenario — plugging in the P1, recording a voice note while it stays
attached, and watching it sync automatically without a replug — requires a human at the physical
device and was not performed. The device's file count went from the previously-noted 7 to 8
between the start of this session and the `list` check above (a `Wip05` file recorded
2026-08-05T03:28:31Z), which is consistent with a recording having happened on the device
independent of this work, but this was not used as a substitute for the real acceptance test: no
build produced during this task was ever run against the device with the poll loop active, so
nothing here confirms the poll loop actually detects and syncs a recording end-to-end on real
hardware. That still needs to be done manually after the user relaunches the app.

## Fix round 1

Review found two HIGH findings, both in the design of `shouldSyncAfterPoll`'s inputs, not in the
close-on-every-path discipline (confirmed clean across all five exits).

**The flaw:** comparing the device's live file count against `index.all().count` compares two
different populations. Index rows are every signature ever synced; device files are what's on the
device right now. Consequences: (1) `deleteFromDevice` deliberately never removes index rows (so
reclaim doesn't cause a re-download), so after a reclaim the device count permanently undershoots
the index count and the poll never fires again; (2) a file that permanently fails to transfer never
enters the index, so `deviceCount > indexCount` stays true and re-fires a sync every tick forever.

**Three changes made:**

1. **Change detector, not a running-total compare.** `shouldSyncAfterPoll` now takes
   `lastSeenCount: Int?` instead of `localCount: Int` and only returns true when the device count
   rose since the last observation (`nil` baseline → always false). `AppModel` added
   `private var lastSeenDeviceFileCount: Int?`, reset to `nil` on `.detached` and at the top of
   `startPolling()`, and updated to the freshly observed count on every IDLE tick regardless of
   whether it triggers a sync. This follows the count back down after a reclaim (baseline drops
   with it) and stops re-firing on a permanently-failing file (baseline tracks the unchanged count).
2. **`isPolling` flag, checked in both directions.** Added `private var isPolling = false`, set
   `true` before `pollTick` opens the transport and cleared right after `device.close()` (and on
   the open-failure exit). `startSync`, `syncNow`, `loadReclaimable`, and `reclaim` now all also
   guard on `!isPolling`, matching the existing two-way `isReclaiming` pattern — closes the window
   where a tick holding the interface (up to ~5s on a `recordingFile()` timeout) could be raced by
   any of those and fail `openFirstAvailable()` with "user client already created".
3. **250ms settle before a poll-triggered sync.** After a tick decides to sync, it now does
   `try? await Task.sleep(for: .milliseconds(250))` after `device.close()` and before calling
   `startSync()`, since that close→open pair is now microseconds apart instead of the seconds every
   other close→open pair in this app is separated by.

Tests: replaced the three `shouldSyncAfterPoll` cases with five covering `nil` baseline (false),
increase (true), unchanged (false), decrease/post-reclaim (false), and recording-in-progress-with-
increase (false) — `Tests/HiDockMenubarTests/AppModelTests.swift`.

Re-verified: `swift build` clean/zero warnings; `swift test` — **87 tests, 0 failures**;
`hidock-cli probe/info/list` re-run against the real device, still reports all 8 files intact, no
regression; no HiDock process left running.
