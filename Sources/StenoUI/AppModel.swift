import Foundation
import JensenKit
import Observation
import SwiftUI

public enum DeviceStatus: Equatable, Sendable {
    case disconnected
    case connected(battery: Int?, freeMiB: Int, capacityMiB: Int)
    case syncing(done: Int, total: Int, percent: Int)
    case busy
    case unavailable(String)
}

/// `@unchecked Sendable`: every mutable property is only ever written from
/// MainActor-isolated code (this class's own `@MainActor` methods, or an
/// explicit `MainActor.run` / `Task { @MainActor in ... }` hop from a
/// background sync task). Sync progress arrives on SyncEngine's actor via a
/// plain `@Sendable` closure, so forwarding it back to `apply(_:)` needs to
/// send a reference to `self` across that boundary; the conformance is what
/// lets the region checker accept that hop instead of rejecting a `weak self`
/// capture it otherwise can't prove safe.
@MainActor
@Observable
public final class AppModel: @unchecked Sendable {
    public var status: DeviceStatus = .disconnected
    public var recent: [Sidecar] = []
    public var lastError: String?
    /// The recording currently in progress on the device, or nil when idle.
    /// Set from the idle-poll loop (see `pollTick`); cleared on detach.
    public private(set) var recordingInProgress: String?
    /// nil when nothing is queued. Drives the menu's progress line.
    public var transcriptionProgress: QueueProgress?

    public var libraryRoot: URL {
        didSet {
            guard libraryRoot != oldValue else { return }
            UserDefaults.standard.set(libraryRoot.path, forKey: Self.rootKey)

            // An in-flight sweep captured the OLD root in its own local
            // `library`/`queue` and keeps writing sidecars there even after
            // `rebuildIndex()` below repoints `index` at the NEW root -- its
            // next `self.index?.upsert(updated)` would then insert an OLD-root
            // row into the just-rebuilt NEW-root index, exactly the failure
            // `rebuildIndex` exists to prevent (see its own comment). Cancel
            // first: `startTranscription`'s loop checks `Task.isCancelled`
            // between recordings, so this stops it from starting the NEXT one
            // under the old root. This is `transcriptionTask`'s first real
            // cancellation call site.
            transcriptionTask?.cancel()
            transcriptionTask = nil

            // Rebuild, not just reload: the index still holds rows for the OLD
            // root, and the menubar would resolve those relative paths against
            // the new one and open nothing.
            rebuildIndex()

            // The new root has its own backlog -- possibly including
            // recordings the old root's sweep never got to.
            startTranscription()
        }
    }

    /// One definition, shared with the migration that has to find this key in
    /// the old domain -- two copies of the string could drift.
    private static let rootKey = LegacyMigration.libraryRootKey

    /// Where recordings go when the user has never chosen a folder. Stored
    /// nowhere: an unset `libraryRoot` means "this", which is exactly why the
    /// migration has to move the folder this used to name.
    static let defaultLibraryRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Recordings/Steno")
    private var monitor: DeviceMonitor?
    private var index: LibraryIndex?
    private var syncTask: Task<Void, Never>?
    private var syncGeneration = 0
    private var transcriptionTask: Task<Void, Never>?
    private var transcriptionGeneration = 0
    /// Signatures the automatic sweep or a manual `retranscribe` is currently
    /// writing. `startTranscription`'s sweep and `retranscribe` each build
    /// their OWN `TranscriptionQueue` -- actor isolation protects state
    /// WITHIN one instance, not across two -- so nothing else stops them
    /// from both writing the SAME sidecar/transcript at once. Task 13 made
    /// every such write UUID-staged and atomic, so two writers can no
    /// longer tear a file, but they can still race last-writer-wins on the
    /// same sidecar: whichever install finishes last silently decides the
    /// recording's title, topic, and transcriptBackend -- e.g. an automatic
    /// sweep finishing after a deliberate Deepgram re-transcription would
    /// revert it back to on-device values with no sign anything happened.
    /// This set is the guard that keeps the sweep and a manual retry off
    /// the same recording at the same time; see
    /// `mayStartTranscribing(signature:inFlight:)` for the pure predicate,
    /// and `startTranscription`/`retranscribe` for where it's held.
    private var sidecarsInFlight: Set<String> = []
    private var retryDelay: Duration = .seconds(2)
    /// The one real diagnostic logger for this process's lifetime, handed to
    /// every `SyncEngine` this class constructs. Tests never construct
    /// `AppModel` (it drives real USB I/O), so there is no injected `nil`
    /// case needed here the way there is on `SyncEngine`.
    private let log = DiagnosticLog()
    /// Idle-poll loop. Only ever runs while the P1 is presumed attached
    /// (started once a sync completes after `.attached`, cancelled on
    /// `.detached`) -- see `startPolling`/`pollTick`.
    private var pollTask: Task<Void, Never>?
    /// The device file count as of the last IDLE poll tick (nil until the
    /// first one). A change detector, not a running total: comparing against
    /// `index.all().count` instead would break in two ways -- reclaim never
    /// removes index rows (so it stays synced-but-not-present), which after a
    /// reclaim makes the device count permanently undershoot it and the poll
    /// never fires again; and a file that permanently fails to transfer never
    /// enters the index, which re-fires a sync every tick forever. Reset to
    /// nil on `.detached` and in `startPolling`, updated on every idle tick.
    private var lastSeenDeviceFileCount: Int?
    /// True only while a poll tick holds the claimed USB interface -- open
    /// through close, including the 300ms post-open settle and up to a
    /// `recordingFile()`/`fileCount()` timeout. Without this the guard is
    /// one-directional: `pollTick` respects `syncTask`/`isReclaiming`, but
    /// nothing respects a tick in progress, so `syncNow`, `loadReclaimable`,
    /// `reclaim`, or an attach-driven `startSync` can all pass their guards
    /// mid-tick and then fail `openFirstAvailable()` with "user client
    /// already created". Same bug class `isReclaiming`'s two-way check kills.
    private var isPolling = false

    public init() {
        // MUST be the first thing here, ahead of the read below. Renaming the
        // bundle identifier moved this app to a fresh `UserDefaults` domain,
        // so without the carry-over the stored library root is invisible, the
        // fallback default folder wins, and the app re-syncs the whole device
        // into somewhere the user never chose. Synchronous by necessity: there
        // is no point in the launch at which "settings, but later" is useful.
        LegacyMigration.runIfNeeded(
            logURL: DiagnosticLog.defaultURL,
            applicationSupport: Self.indexURL().deletingLastPathComponent(),
            defaultLibraryRoot: Self.defaultLibraryRoot)

        let stored = UserDefaults.standard.string(forKey: Self.rootKey)
        self.libraryRoot = stored.map { URL(fileURLWithPath: $0) } ?? Self.defaultLibraryRoot
    }

    public func start() {
        try? FileManager.default.createDirectory(
            at: libraryRoot, withIntermediateDirectories: true)
        index = openIndex()
        reloadRecent()

        let monitor = DeviceMonitor { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        monitor.start()
        self.monitor = monitor
        monitor.rescan()

        // Whatever missed the sweep at the end of a previous sync (the app
        // quit mid-queue, or was never running when one finished) gets picked
        // up here too -- `startTranscription` is safe to call repeatedly.
        startTranscription()
    }

    private static func indexURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Steno/index.sqlite")
    }

    /// Every file SQLite may have created for this database.
    ///
    /// WAL is enabled, so deleting only `index.sqlite` leaves a write-ahead log
    /// that can be recovered back into the fresh file — reviving exactly the
    /// corruption the delete was meant to clear.
    nonisolated static func indexSidecarURLs(for db: URL) -> [URL] {
        ["", "-wal", "-shm"].map { URL(fileURLWithPath: db.path + $0) }
    }

    /// Opens the on-disk index, deleting and retrying once on failure.
    ///
    /// `LibraryIndex` is a DERIVED cache (its own doc comment says so) —
    /// nothing is lost by throwing away a corrupt one, and `rebuildIndex()`
    /// can always reconstruct it from the sidecars on disk. Without this, a
    /// corrupt `index.sqlite` left `index` nil forever: `startSync`'s
    /// `guard let index` returned silently on every attach — P1 plugged in,
    /// menubar reading "No device", nothing in `lastError` — and the in-app
    /// recovery button (`rebuildIndex`) was ALSO a no-op with `index` nil, so
    /// there was no way out short of quitting and manually deleting the file.
    /// If the retry also fails, surface the reason instead of staying silent.
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

    private func handle(_ event: DeviceEvent) {
        switch event {
        case .detached:
            log.log("detach")
            syncTask?.cancel()
            syncTask = nil
            stopPolling()
            recordingInProgress = nil
            lastSeenDeviceFileCount = nil
            status = .disconnected
        case .attached:
            log.log("attach")
            guard syncTask == nil else { return }
            // DeviceMonitor cannot trust its own termination filter (a
            // terminated service may not expose idVendor), so ANY USB device
            // detaching elsewhere on the system forces an authoritative
            // rescan — and if the P1 is still attached, that rescan re-emits
            // `.attached` even though nothing changed for it. Once a sync has
            // already completed (`status == .connected`), routine churn must
            // not restart it or wipe `lastNotice`/`lastError` — e.g. clobbering
            // a reclaim result the user hasn't read yet just because a
            // keyboard was unplugged. An actual P1 detach resets `status` to
            // `.disconnected` above, so a real replug still syncs.
            if case .connected = status { return }
            startSync(trigger: "attach")
        }
    }

    public func rebuildIndex() {
        guard let index = index ?? openIndex() else { return }
        self.index = index
        let library = Library(root: libraryRoot)
        try? index.rebuild(from: (try? library.scanSidecars()) ?? [])
        reloadRecent()
    }

    private func reloadRecent() {
        recent = (try? index?.recent(limit: 5)) ?? []
    }

    private func startSync(trigger: String) {
        guard let index else { return }

        // The precondition belongs HERE, not scattered across callers who
        // each have to remember it. `syncTask == nil` in particular: the poll
        // tick checks it before opening the transport, but its call to
        // `startSync` below comes after several awaits AND a deliberate
        // 250ms settle sleep -- a genuine MainActor suspension point another
        // caller (e.g. the "Sync now" button) can land in and start a sync of
        // its own during. Without re-checking here, that races two
        // `SyncEngine`s against the same USB interface and can clobber the
        // `syncGeneration` mutex. Reclaim and a poll tick likewise hold the
        // USB interface, so the guard has to run in ALL directions -- see
        // `isPolling`'s doc comment.
        // Unlike a plain "index is nil" return, dropping the attach here must
        // NOT be silent: whatever's running (reclaim, the tick, or the sync
        // already in flight) finishes and releases the interface, but nothing
        // else re-triggers a sync, so an unplug during any of them would
        // otherwise leave auto-sync dead until a physical replug.
        guard syncTask == nil, !isReclaiming, !isPolling else {
            scheduleRetry(reason: "guard-blocked")
            return
        }
        log.log("sync.start", ["trigger": trigger])
        let library = Library(root: libraryRoot)
        let engine = SyncEngine(library: library, index: index, log: log)

        // Clear stale state before a fresh attempt. lastError is now rendered,
        // so a drift warning or failure count from a previous attach would
        // otherwise sit in the menu forever, describing something that is no
        // longer true.
        lastError = nil
        lastNotice = nil

        // Identity token. A fast unplug/replug can cancel sync A, start sync B,
        // and only THEN have A's unwind clear `syncTask` — reopening the guard
        // while B is still running and letting a wake- or retry-rescan start a
        // second concurrent sync against the same device. Clearing only when the
        // generation still matches closes that. `SyncEngine.isSyncing` cannot
        // cover this: `startSync` builds a fresh `SyncEngine` every call, so
        // `syncTask` (guarded by generation) is the only real mutex here.
        syncGeneration &+= 1
        let generation = syncGeneration

        syncTask = Task { [weak self] in
            defer {
                Task { @MainActor in
                    guard let self, self.syncGeneration == generation else { return }
                    self.syncTask = nil
                }
            }

            let device: JensenDevice
            do {
                let transport = try IOUSBHostTransport.openFirstAvailable()
                device = JensenDevice(transport: transport)
                try await device.open()
            } catch let error as JensenError {
                await MainActor.run { self?.handleConnectionFailure(error) }
                return
            } catch {
                await MainActor.run { self?.status = .unavailable(error.localizedDescription) }
                return
            }

            // Swift has no async `defer`, and `defer { Task { ... } }` does NOT
            // work here — it is fire-and-forget and may never run. The device
            // MUST be closed on every path: `close()` aborts in-flight pipes and
            // destroys the user client, and an interface left claimed makes every
            // later open() fail with "user client already created" for the rest of
            // the process's life. The app would sync once and then be dead until
            // relaunch. So: capture the error, close unconditionally, then handle.
            let syncStarted = ContinuousClock.now
            var caught: (any Error)?
            do {
                let info = try await device.deviceInfo()
                let card = try await device.cardInfo()
                self?.log.log("sync.device", [
                    "firmware": info.versionCode,
                    "serial": info.serialNumber,
                    "freeMiB": "\(card.freeMiB)",
                ])
                await MainActor.run {
                    self?.retryDelay = .seconds(2)
                    self?.status = .connected(battery: nil,
                                              freeMiB: card.freeMiB,
                                              capacityMiB: card.capacityMiB)
                }

                if let drift = await Self.readClockDrift(device: device), abs(drift) > 60 {
                    await MainActor.run {
                        self?.lastError = "Device clock is off by "
                            + "\(Int(abs(drift) / 60)) min. Recording timestamps may be wrong."
                    }
                }

                // `progress` is a synchronous `@Sendable` callback invoked from
                // SyncEngine's own actor, not from this Task, so forwarding it to
                // `apply` needs its own hop back to MainActor via a fresh Task.
                // The region checker rejects sending the outer `[weak self]`
                // binding itself into that new Task (it's still "in flight" on
                // this Task's region); rebinding it to a fresh local first gives
                // the checker a value it can send instead. Safe in practice: this
                // class is `@unchecked Sendable` precisely because every mutation
                // of its state — including `apply` — happens on MainActor.
                let selfForProgress = self
                let syncResult = try await engine.sync(device: device, serial: info.serialNumber) { progress in
                    Task { @MainActor in selfForProgress?.apply(progress) }
                }

                self?.log.log("sync.end", [
                    "downloaded": "\(syncResult.downloaded.count)",
                    "skipped": "\(syncResult.skipped)",
                    "failed": "\(syncResult.failed.count)",
                    "seconds": DiagnosticLog.seconds(ContinuousClock.now - syncStarted),
                ])
                let refreshed = try? await device.cardInfo()
                await MainActor.run {
                    self?.reloadRecent()
                    self?.status = .connected(battery: nil,
                                              freeMiB: refreshed?.freeMiB ?? card.freeMiB,
                                              capacityMiB: refreshed?.capacityMiB ?? card.capacityMiB)
                    // A full sync just completed after attach: the device is
                    // known-present and idle enough to have answered every
                    // command above, so it's safe to start noticing new
                    // recordings without a replug. `startPolling` is a no-op
                    // if a poll loop from an earlier attach is already running.
                    self?.startPolling()
                    // Name and cause, not just a count — a permanently-failing
                    // recording used to render as "1 recording(s) failed to
                    // sync" forever, with no way to tell which one or why.
                    if let first = syncResult.failed.first {
                        let extra = syncResult.failed.count > 1
                            ? " (+\(syncResult.failed.count - 1) more)" : ""
                        self?.lastError = "\(first.name) failed to sync: "
                            + "\(first.error.localizedDescription)\(extra)"
                    }
                }
            } catch {
                caught = error
            }

            await device.close()

            if let caught {
                if let jensen = caught as? JensenError {
                    await MainActor.run { self?.handleConnectionFailure(jensen) }
                } else {
                    await MainActor.run {
                        self?.status = .unavailable(caught.localizedDescription)
                        self?.lastError = caught.localizedDescription
                    }
                }
            }
        }
    }

    /// The device clock names the recordings, so drift means mislabelled notes.
    ///
    /// READ ONLY, DELIBERATELY. The GET_DEVICE_TIME body layout is
    /// hardware-verified — see `ResponseParsers.deviceTime`, confirmed BCD
    /// against a real device 2026-08-04. What remains unverified is the
    /// WRITE side: nothing confirms SET_DEVICE_TIME accepts the same layout
    /// back, and writing a wrong one would set the clock that names every
    /// future recording to garbage. Do not call SET_DEVICE_TIME until that is
    /// confirmed too.
    private static func readClockDrift(device: JensenDevice) async -> TimeInterval? {
        guard let body = try? await device.send(.getDeviceTime, timeout: .seconds(5)),
              let deviceTime = ResponseParsers.deviceTime(body) else { return nil }
        return deviceTime.timeIntervalSinceNow
    }

    private func handleConnectionFailure(_ error: JensenError) {
        let reason: String
        switch error {
        case .timeout:
            status = .busy                       // recording, or in Vibe Mic Bluetooth mode
            reason = "busy"
        case .interfaceUnavailable(let detail):
            status = .unavailable(detail)
            reason = "unavailable"
        default:
            status = .unavailable(error.localizedDescription)
            reason = "unavailable"
        }
        scheduleRetry(reason: reason)
    }

    /// Backs off so a persistently unavailable device never busy-loops.
    private func scheduleRetry(reason: String) {
        let delay = retryDelay
        log.log("retry", ["delay": "\(DiagnosticLog.seconds(delay))s", "reason": reason])
        retryDelay = min(delay * 2, .seconds(60))
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            await MainActor.run {
                guard let self, self.syncTask == nil else { return }
                self.monitor?.rescan()
            }
        }
    }

    private func apply(_ progress: SyncProgress) {
        switch progress {
        case .listing:
            status = .syncing(done: 0, total: 0, percent: 0)
        case let .downloading(_, index, total, bytesDone, bytesTotal):
            let percent = bytesTotal > 0 ? bytesDone * 100 / bytesTotal : 0
            status = .syncing(done: index, total: total, percent: percent)
        case .finished:
            // The full SyncResult — including per-file names and reasons for
            // any failures — is handled once, after `engine.sync` returns in
            // `startSync`, where it's actually available. This progress event
            // only ever carried counts, not enough to report anything useful.
            //
            // Kick the transcription sweep here rather than after `engine.sync`
            // returns: `.finished` fires on every exit path -- including the
            // early `libraryUnreachable`/listing-failure returns in
            // `SyncEngine.sync` -- so this is the one place that always runs.
            startTranscription()
        }
    }

    // MARK: - Idle polling

    /// The P1 doesn't push any notification when a recording starts or
    /// finishes, so a device left plugged in needs to be asked. Interval
    /// shortens while a recording is in progress so "Recording…" clears
    /// promptly once it stops; 10s otherwise keeps USB traffic light.
    ///
    /// A no-op if a poll loop is already running -- callers (sync completion
    /// after both an attach AND a poll-triggered sync) don't need to know
    /// whether one is already in flight.
    private func startPolling() {
        // Always start counting fresh. A baseline left over from before this
        // sync (or from a previous attach) must not be compared against a
        // count observed under different circumstances.
        lastSeenDeviceFileCount = nil
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval: Duration = await MainActor.run {
                    self?.recordingInProgress != nil ? .seconds(3) : .seconds(10)
                }
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                await self?.pollTick()
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// One iteration of the idle-poll loop.
    ///
    /// Must not fight the existing guards -- a sync or reclaim already owns
    /// the interface (or is about to) -- and must not BE fought: `isPolling`
    /// marks this tick's own claim on the interface so nothing else races it.
    ///
    /// Same open/close discipline as `startSync`: the interface must be free
    /// BETWEEN polls so `steno` and a user-triggered sync can still claim
    /// it, so every tick opens its own transport, does its work, and closes it
    /// again on every path -- capture the error, close unconditionally, then
    /// handle. `startSync` (called below) opens its own transport separately,
    /// after this one is already closed.
    private func pollTick() async {
        guard syncTask == nil, !isReclaiming, !isPolling else {
            let guardName = syncTask != nil ? "syncTask" : (isReclaiming ? "isReclaiming" : "isPolling")
            log.log("poll.skip", ["guard": guardName])
            return
        }
        isPolling = true

        let device: JensenDevice
        do {
            let transport = try IOUSBHostTransport.openFirstAvailable()
            device = JensenDevice(transport: transport)
            try await device.open()
        } catch {
            // Busy (interface already claimed elsewhere) or gone. DeviceMonitor
            // owns detecting an actual detach; this tick just skips quietly.
            log.log("poll.error", ["error": "\(error)"])
            isPolling = false
            return
        }

        var caught: (any Error)?
        var recording: String?
        var deviceFileCount = 0
        do {
            recording = try await device.recordingFile()
            if recording == nil {
                deviceFileCount = try await device.fileCount()
            }
        } catch {
            caught = error
        }
        await device.close()
        isPolling = false

        // A poll tick is background noise, not something the user asked for --
        // a transient read failure here must not overwrite lastError/status
        // that a real sync or reclaim set. Just try again next tick.
        guard caught == nil else {
            if let caught { log.log("poll.error", ["error": "\(caught)"]) }
            return
        }

        recordingInProgress = recording
        if let recording {
            log.log("poll", ["recording": recording])
            return
        }

        // Update the baseline on EVERY idle tick, whether or not it syncs --
        // that's what makes this a change detector rather than a running
        // total, and what makes it follow the count back down after a
        // reclaim instead of staying permanently tripped.
        let previouslySeen = lastSeenDeviceFileCount
        lastSeenDeviceFileCount = deviceFileCount
        let willSync = Self.shouldSyncAfterPoll(
            recording: recording, deviceFileCount: deviceFileCount, lastSeenCount: previouslySeen)
        log.log("poll", [
            "recording": "nil",
            "count": "\(deviceFileCount)",
            "lastSeen": previouslySeen.map(String.init) ?? "nil",
        ], suffix: willSync ? "-> sync" : nil)
        guard willSync else { return }

        // startSync reopens the interface this tick just released
        // microseconds ago. Every other close -> open pair in this app is
        // seconds apart; if the kernel doesn't release the exclusive claim
        // synchronously, an immediate reopen fails and only recovers via the
        // 2s backoff.
        try? await Task.sleep(for: .milliseconds(250))
        startSync(trigger: "poll")
    }

    /// Pure decision extracted for testing -- `AppModel` itself has no seam
    /// for it, since it depends on live device state fetched inside `pollTick`.
    /// `nonisolated`: a static member of a `@MainActor` class is MainActor-
    /// isolated by default, which would force every caller (including the
    /// synchronous tests below) onto the main actor for no reason -- this has
    /// no actor-isolated state to protect.
    ///
    /// Compares against the LAST OBSERVED device count, not a running total
    /// like `index.all().count`: reclaim deliberately never removes index
    /// rows (so an already-synced file doesn't get silently re-downloaded),
    /// which after a reclaim makes the device count permanently undershoot
    /// the index count and this would never fire again; and a file that
    /// permanently fails to transfer never enters the index either, which
    /// would re-fire a sync every tick forever. `nil` means "no observation
    /// yet" -- the first tick only establishes a baseline, it never syncs.
    nonisolated static func shouldSyncAfterPoll(
        recording: String?, deviceFileCount: Int, lastSeenCount: Int?
    ) -> Bool {
        guard recording == nil else { return false }
        guard let lastSeenCount else { return false }
        return deviceFileCount > lastSeenCount
    }

    /// Pure decision extracted for testing, same rationale as
    /// `shouldSyncAfterPoll` above -- `AppModel` itself has no seam for
    /// exercising a live task race under test, and this project's tests never
    /// construct `AppModel` at all (it drives real USB I/O).
    ///
    /// `true` means the captured generation is still current, so whichever
    /// transcription task's `defer` is asking is the one `transcriptionTask`
    /// actually points at, and it owns clearing `transcriptionTask`/
    /// `transcriptionProgress`. `false` means a STALE, already-cancelled
    /// task's cleanup is running after a newer task has already been
    /// assigned -- see `startTranscription`'s comment on `transcriptionGeneration`
    /// for the exact interleaving this guards against. Clearing unconditionally
    /// in that case would discard the reference to the newer, still-running
    /// task and defeat `startTranscription`'s own re-entrancy guard.
    ///
    /// `nonisolated`: see `shouldSyncAfterPoll` above -- same rationale.
    nonisolated static func shouldClearTranscriptionState(
        capturedGeneration: Int, currentGeneration: Int
    ) -> Bool {
        capturedGeneration == currentGeneration
    }

    /// Pure predicate behind `sidecarsInFlight` -- same rationale as
    /// `shouldSyncAfterPoll`/`shouldClearTranscriptionState` above: `AppModel`
    /// itself has no test seam, so the decision is extracted here to stay
    /// testable. See `sidecarsInFlight`'s own doc comment for the two-queue
    /// hazard this closes.
    ///
    /// `nonisolated`: see `shouldSyncAfterPoll` above -- same rationale.
    nonisolated static func mayStartTranscribing(signature: String, inFlight: Set<String>) -> Bool {
        !inFlight.contains(signature)
    }

    /// Manual escape hatch for the menu's "Sync now" button -- the same
    /// guard `startSync` already relies on via `.attached` and the poll loop,
    /// just reachable on demand instead of waiting for the next attach or tick.
    public func syncNow() {
        guard syncTask == nil else {
            lastError = "A sync is already running."
            return
        }
        guard !isReclaiming else {
            lastError = "Can't sync while freeing up space on the P1. Try again in a moment."
            return
        }
        guard !isPolling else {
            lastError = "Can't sync right now. Try again in a moment."
            return
        }
        startSync(trigger: "manual")
    }

    // MARK: - Transcription

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

        // Identity token, same shape as `syncGeneration` in `startSync` --
        // read that one's comment for the general case. Here specifically:
        // `libraryRoot`'s `didSet` can cancel this task and, still
        // synchronously, call `startTranscription()` again before the
        // cancelled task's slow `await queue.process(sidecar)` ever resumes.
        // By the time the cancelled task's `defer` runs, `transcriptionTask`
        // already points at the NEW task. An unconditional
        // `self.transcriptionTask = nil` there would discard that reference,
        // defeating the `guard transcriptionTask == nil` above and letting a
        // later trigger (e.g. the next `apply(.finished)`) spawn an
        // unbounded further sweep. Clearing only when the generation still
        // matches closes that.
        transcriptionGeneration &+= 1
        let generation = transcriptionGeneration

        transcriptionTask = Task {
            defer {
                if Self.shouldClearTranscriptionState(
                    capturedGeneration: generation, currentGeneration: self.transcriptionGeneration) {
                    self.transcriptionTask = nil
                    self.transcriptionProgress = nil
                }
            }

            let all = await Task.detached { (try? library.scanSidecars()) ?? [] }.value
            let todo = await queue.pending(from: all)
            guard !todo.isEmpty else { return }

            for (offset, sidecar) in todo.enumerated() {
                // Reached when `libraryRoot`'s `didSet` cancels this task
                // between recordings, so a sweep started under the OLD root
                // stops rather than going on to upsert further OLD-root rows
                // into the index `rebuildIndex()` just repointed at the NEW
                // one. Does not abort a recording already mid-transcription.
                if Task.isCancelled { return }
                self.transcriptionProgress = QueueProgress(done: offset, total: todo.count)

                // A manual "Transcribe again" (`retranscribe`) may already be
                // running against this exact recording -- see
                // `sidecarsInFlight`'s doc comment for why two independent
                // `TranscriptionQueue`s writing the same sidecar is unsafe.
                // Skip it this pass rather than race a second writer onto it;
                // `todo` is only a snapshot for this run, so the NEXT sweep
                // re-reads from disk and picks it up again if it still needs
                // work.
                guard Self.mayStartTranscribing(signature: sidecar.signature, inFlight: sidecarsInFlight)
                else { continue }
                sidecarsInFlight.insert(sidecar.signature)
                defer { sidecarsInFlight.remove(sidecar.signature) }

                let updated = await queue.process(sidecar)
                await Task.detached { try? library.updateSidecar(updated) }.value

                try? self.index?.upsert(updated)
                self.reloadRecent()
            }
        }
    }

    /// Explicit, one recording, one backend. The ONLY path by which audio leaves
    /// this machine.
    ///
    /// Does NOT delete the existing transcript up front. `retry` (see
    /// `TranscriptionQueue.run`) always re-transcribes rather than reusing what
    /// is on disk, and `store.write` installs the result by atomically
    /// replacing the old file — so removing here first would only reopen a
    /// window where a failed or interrupted retry leaves the recording with
    /// NEITHER transcript, while the sidecar still advertises the old,
    /// now-deleted one's `transcribedAt`/`transcriptBackend`.
    public func retranscribe(_ sidecar: Sidecar, using transcriber: any Transcriber) {
        // See `sidecarsInFlight`'s doc comment for the hazard this guards
        // against: this method and the automatic sweep each build their own
        // `TranscriptionQueue`, so nothing else stops them from both writing
        // this exact sidecar at once. Refusing here (rather than queuing or
        // cancelling the sweep) is the smallest thing that closes it without
        // touching `TranscriptionQueue` itself.
        guard Self.mayStartTranscribing(signature: sidecar.signature, inFlight: sidecarsInFlight) else {
            lastError = "Already transcribing this recording. Try again in a moment."
            return
        }
        sidecarsInFlight.insert(sidecar.signature)

        let root = libraryRoot
        let store = TranscriptStore(root: root)
        let library = Library(root: root)

        Task {
            defer { self.sidecarsInFlight.remove(sidecar.signature) }
            let queue = TranscriptionQueue(
                root: root, store: store, filer: Filer(root: root),
                resolver: TopicResolver(suggester: OnDeviceSuggester()),
                transcriber: transcriber)
            // `retry`, not `process`: this is the deliberate user-initiated path
            // and must ignore the attempt cap. It clears the counter itself.
            let updated = await queue.retry(sidecar)
            await Task.detached { try? library.updateSidecar(updated) }.value

            try? self.index?.upsert(updated)
            self.reloadRecent()
        }
    }

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

    public var reclaimCandidates: [FileInfo] = []
    public var isLoadingReclaim = false
    /// Neutral outcome message. `lastError` is for problems; this is for
    /// "it worked", which the reclaim flow otherwise had no way to say.
    public var lastNotice: String?
    /// Reclaim holds the USB interface too. Without this, an attach or a retry
    /// rescan can call startSync mid-reclaim and fail on "user client already
    /// created". The guard has to run in BOTH directions.
    private var isReclaiming = false

    /// Lists only recordings verified present on disk at the expected byte
    /// length, checked at call time rather than trusted from the index.
    public func loadReclaimable() {
        // Clear first: a stale list left from a previous Cancel would otherwise
        // be presented as if it were current.
        reclaimCandidates = []
        lastNotice = nil

        // Same reasoning, applied to the warning below. It says "Try again in
        // a moment", but until now the only thing that ever cleared `lastError`
        // was `startSync` -- so a user who did exactly what it asked kept
        // looking at a warning about a poll tick that had finished seconds
        // earlier, in the menu AND in Settings, until they happened to hit Sync
        // Now. Clearing here before the guard makes the retry the message asks
        // for the thing that clears it: a retry that gets through leaves no
        // message, and one that is blocked again posts a fresh one.
        lastError = nil

        guard let index, syncTask == nil, !isReclaiming, !isPolling else {
            lastError = "Can't check the device while a sync is running. Try again in a moment."
            return
        }
        isReclaiming = true
        isLoadingReclaim = true
        let engine = SyncEngine(library: Library(root: libraryRoot), index: index, log: log)

        Task { [weak self] in
            do {
                let transport = try IOUSBHostTransport.openFirstAvailable()
                let device = JensenDevice(transport: transport)
                try await device.open()

                // Same discipline as startSync: the device MUST be closed on
                // every path once open() succeeds, not only when reclaimable()
                // returns cleanly. Skipping close() when it throws leaves the
                // claimed interface behind, and every later open() — including
                // the next sync — fails with "user client already created" for
                // the rest of the process's life. open() itself already tears
                // down on ITS OWN failure, so close() only belongs on the
                // success side of THAT call.
                var caught: (any Error)?
                var candidates: [FileInfo] = []
                do {
                    candidates = try await engine.reclaimable(device: device)
                } catch {
                    caught = error
                }
                await device.close()

                await MainActor.run {
                    if let caught {
                        self?.lastError = caught.localizedDescription
                    } else {
                        self?.reclaimCandidates = candidates
                    }
                    self?.isLoadingReclaim = false
                    self?.isReclaiming = false
                }
            } catch {
                await MainActor.run {
                    self?.lastError = error.localizedDescription
                    self?.isLoadingReclaim = false
                    self?.isReclaiming = false
                }
            }
        }
    }

    public func reclaim(_ files: [FileInfo]) {
        guard let index, syncTask == nil, !isReclaiming, !isPolling, !files.isEmpty else {
            lastError = "Can't delete right now. Try again in a moment."
            return
        }
        isReclaiming = true
        lastError = nil
        lastNotice = nil
        log.log("reclaim.start", ["count": "\(files.count)"])
        let engine = SyncEngine(library: Library(root: libraryRoot), index: index, log: log)

        Task { [weak self] in
            do {
                let transport = try IOUSBHostTransport.openFirstAvailable()
                let device = JensenDevice(transport: transport)
                try await device.open()

                // See loadReclaimable: close on every path once open()
                // succeeds, including when deleteFromDevice itself throws.
                var caught: (any Error)?
                var result = DeleteResult()
                do {
                    result = try await engine.deleteFromDevice(files, device: device)
                } catch {
                    caught = error
                }
                await device.close()

                self?.log.log("reclaim.end", [
                    "deleted": "\(result.deleted.count)",
                    "skipped": "\(result.skipped.count)",
                    "failed": "\(result.failed.count)",
                ])

                await MainActor.run {
                    self?.reclaimCandidates = []
                    self?.isReclaiming = false
                    if let caught {
                        self?.lastError = caught.localizedDescription
                        return
                    }
                    // Report ALL three outcomes. A file reported `failed` may
                    // still be on the device, and a fully-`skipped` run used to
                    // look identical to a successful one.
                    var problems: [String] = []
                    if !result.failed.isEmpty {
                        problems.append("\(result.failed.count) could not be deleted")
                    }
                    if !result.skipped.isEmpty {
                        problems.append("\(result.skipped.count) skipped (no verified local copy)")
                    }
                    if problems.isEmpty {
                        self?.lastNotice = "Freed \(result.deleted.count) recording(s) from the P1."
                    } else {
                        self?.lastError = "Deleted \(result.deleted.count). "
                            + problems.joined(separator: ", ") + "."
                    }
                }
            } catch {
                await MainActor.run {
                    self?.lastError = error.localizedDescription
                    self?.isReclaiming = false
                }
            }
        }
    }
}
