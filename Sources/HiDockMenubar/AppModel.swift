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
            UserDefaults.standard.set(libraryRoot.path, forKey: Self.rootKey)
            reloadRecent()
        }
    }

    private static let rootKey = "libraryRoot"
    private var monitor: DeviceMonitor?
    private var index: LibraryIndex?
    private var syncTask: Task<Void, Never>?
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
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HiDock/index.sqlite")
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
        guard let index else { return }
        let library = Library(root: libraryRoot)
        let engine = SyncEngine(library: library, index: index)

        syncTask = Task { [weak self] in
            defer { Task { @MainActor in self?.syncTask = nil } }
            do {
                let transport = try IOUSBHostTransport.openFirstAvailable()
                let device = JensenDevice(transport: transport)
                try await device.open()


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
            } catch let error as JensenError {
                await MainActor.run { self?.handleConnectionFailure(error) }
            } catch {
                await MainActor.run {
                    self?.status = .unavailable(error.localizedDescription)
                    self?.lastError = error.localizedDescription
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
}
