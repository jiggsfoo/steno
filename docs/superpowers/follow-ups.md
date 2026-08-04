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

**`retryDelay` ratchets from the reclaim guard.** `scheduleRetry()` doubles the
backoff toward its 60 s cap and is only reset on a successful connect, so
repeated attach-during-reclaim events lengthen the delay.

**After an index wipe, Recent stays empty until a manual rebuild.** Already-synced
recordings hit the fallback path, are skipped, and never re-`upsert`, so the
index does not refill on its own. Settings → "Rebuild index" recovers it, which
is the documented path.

## Deferred hardware checks

Both need a person at the cable and were never performed.

1. **Unplug the P1 mid-command.** Expect prompt failure via a propagated
   `kIOReturnNoDevice` rather than a spin to the full timeout. The
   `kIOReturnTimeout`-only tolerance in `IOUSBHostTransport.transfer` is correct
   by inspection; this confirms it end to end.
   Command: `swift run hidock-cli info`, pull the cable during the run.

2. **Attach/detach notifications.** With `swift run hidock-cli watch` running:
   unplug and replug the P1, expecting `DETACHED` then `ATTACHED`. Then plug in
   an unrelated USB device and confirm it produces **no** output. That second
   half matters: the IOKit matching dictionary is a bare `IOUSBHostInterface`
   class match, so the callbacks fire for every USB interface on the machine and
   the VID/PID filter is the only thing making an event meaningful.

   Note the first `ATTACHED` line proves only that the initial `rescan()` works —
   it prints before the process parks. Only the unplug exercises the
   notification path.

## Not defects

Recorded so they are not "fixed" later by mistake.

- **Battery is always `nil`.** `GET_BATTERY_STATUS`'s body layout was never
  verified against hardware, so no parser was invented. The menubar omits the
  line when nil.
- **`SET_DEVICE_TIME` is never sent.** The *read* is hardware-verified BCD. That
  the write accepts the same layout is an inference, not a measurement, and a
  wrong write would corrupt the clock that names every recording.
- **`DELETE_FILE`'s response is not parsed.** The format is unverified, so
  `deleteFromDevice` confirms the outcome by re-listing the device instead. If
  that listing fails, every file is reported failed, never deleted.
- **`SyncEngine.isSyncing` is unreachable from the app**, because `startSync`
  builds a fresh engine per call. `AppModel.syncTask` is the real mutex. The
  engine guard remains for direct API users and is exercised by tests.
