import Foundation
import HiDockKit
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

    public var libraryRoot: URL {
        didSet {
            guard libraryRoot != oldValue else { return }
            UserDefaults.standard.set(libraryRoot.path, forKey: Self.rootKey)
            // Rebuild, not just reload: the index still holds rows for the OLD
            // root, and the menubar would resolve those relative paths against
            // the new one and open nothing.
            rebuildIndex()
        }
    }

    private static let rootKey = "libraryRoot"
    private var monitor: DeviceMonitor?
    private var index: LibraryIndex?
    private var syncTask: Task<Void, Never>?
    private var syncGeneration = 0
    private var retryDelay: Duration = .seconds(2)

    public init() {
        let stored = UserDefaults.standard.string(forKey: Self.rootKey)
        self.libraryRoot = stored.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Recordings/HiDock")
    }

    public func start() {
        try? FileManager.default.createDirectory(
            at: libraryRoot, withIntermediateDirectories: true)
        index = try? LibraryIndex(url: Self.indexURL())
        reloadRecent()

        let monitor = DeviceMonitor { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        monitor.start()
        self.monitor = monitor
        monitor.rescan()
    }

    private static func indexURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("HiDock/index.sqlite")
    }

    private func handle(_ event: DeviceEvent) {
        switch event {
        case .detached:
            syncTask?.cancel()
            syncTask = nil
            status = .disconnected
        case .attached:
            guard syncTask == nil else { return }
            startSync()
        }
    }

    public func rebuildIndex() {
        guard let index else { return }
        let library = Library(root: libraryRoot)
        try? index.rebuild(from: (try? library.scanSidecars()) ?? [])
        reloadRecent()
    }

    private func reloadRecent() {
        recent = (try? index?.recent(limit: 5)) ?? []
    }

    private func startSync() {
        // Reclaim holds the USB interface too. Without this, an attach or a
        // retry rescan can call startSync mid-reclaim and fail on "user
        // client already created". The guard has to run in BOTH directions.
        guard let index, !isReclaiming else { return }
        let library = Library(root: libraryRoot)
        let engine = SyncEngine(library: library, index: index)

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
            var caught: (any Error)?
            do {
                let info = try await device.deviceInfo()
                let card = try await device.cardInfo()
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
                _ = try await engine.sync(device: device, serial: info.serialNumber) { progress in
                    Task { @MainActor in selfForProgress?.apply(progress) }
                }

                let refreshed = try? await device.cardInfo()
                await MainActor.run {
                    self?.reloadRecent()
                    self?.status = .connected(battery: nil,
                                              freeMiB: refreshed?.freeMiB ?? card.freeMiB,
                                              capacityMiB: refreshed?.capacityMiB ?? card.capacityMiB)
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
    /// READ ONLY, DELIBERATELY. The GET_DEVICE_TIME body layout below is an
    /// educated guess and appears in neither reference implementation. Reading
    /// a wrong layout yields a nonsense date and is harmless; *writing* one
    /// would set the clock that names every future recording to garbage.
    /// Task 5's hardware check dumps the real bytes. Do not call
    /// SET_DEVICE_TIME until this parse is confirmed against them.
    private static func readClockDrift(device: JensenDevice) async -> TimeInterval? {
        guard let body = try? await device.send(.getDeviceTime, timeout: .seconds(5)),
              let deviceTime = ResponseParsers.deviceTime(body) else { return nil }
        return deviceTime.timeIntervalSinceNow
    }

    private func handleConnectionFailure(_ error: JensenError) {
        switch error {
        case .timeout:
            status = .busy                       // recording, or in Vibe Mic Bluetooth mode
        case .interfaceUnavailable(let detail):
            status = .unavailable(detail)
        default:
            status = .unavailable(String(describing: error))
        }
        scheduleRetry()
    }

    /// Backs off so a persistently unavailable device never busy-loops.
    private func scheduleRetry() {
        let delay = retryDelay
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
        case let .finished(downloaded, _, failed):
            if failed > 0 { lastError = "\(failed) recording(s) failed to sync" }
            if downloaded > 0 { reloadRecent() }
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

        guard let index, syncTask == nil, !isReclaiming else {
            lastError = "Can't check the device while a sync is running. Try again in a moment."
            return
        }
        isReclaiming = true
        isLoadingReclaim = true
        let engine = SyncEngine(library: Library(root: libraryRoot), index: index)

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
        guard let index, syncTask == nil, !isReclaiming, !files.isEmpty else {
            lastError = "Can't delete right now. Try again in a moment."
            return
        }
        isReclaiming = true
        lastError = nil
        lastNotice = nil
        let engine = SyncEngine(library: Library(root: libraryRoot), index: index)

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
