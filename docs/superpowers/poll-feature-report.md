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
