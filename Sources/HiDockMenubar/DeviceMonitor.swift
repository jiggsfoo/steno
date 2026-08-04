import AppKit
import Foundation
import HiDockKit
import IOKit
import IOKit.usb

public enum DeviceEvent: Sendable {
    case attached
    case detached
}

/// Watches for the P1's Jensen interface appearing and disappearing.
/// Also re-scans on wake, because match notifications do not reliably
/// re-fire across sleep.
public final class DeviceMonitor: @unchecked Sendable {
    private let onChange: @Sendable (DeviceEvent) -> Void
    private var notifyPort: IONotificationPortRef?
    private var matchedIterator: io_iterator_t = 0
    private var terminatedIterator: io_iterator_t = 0
    private var wakeObserver: (any NSObjectProtocol)?
    private var sleepObserver: (any NSObjectProtocol)?

    public init(onChange: @escaping @Sendable (DeviceEvent) -> Void) {
        self.onChange = onChange
    }

    deinit { stop() }

    public func start() {
        guard notifyPort == nil else { return }

        let port = IONotificationPortCreate(kIOMainPortDefault)
        notifyPort = port
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)

        let context = Unmanaged.passUnretained(self).toOpaque()

        let matchedCallback: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            let monitor = Unmanaged<DeviceMonitor>.fromOpaque(refcon).takeUnretainedValue()
            monitor.drain(iterator, event: .attached)
        }

        let terminatedCallback: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            let monitor = Unmanaged<DeviceMonitor>.fromOpaque(refcon).takeUnretainedValue()
            monitor.drain(iterator, event: .detached)
        }

        IOServiceAddMatchingNotification(
            port, kIOMatchedNotification,
            HiDockDeviceMatching.matchingDictionary(),
            matchedCallback, context, &matchedIterator)

        IOServiceAddMatchingNotification(
            port, kIOTerminatedNotification,
            HiDockDeviceMatching.matchingDictionary(),
            terminatedCallback, context, &terminatedIterator)

        // Arming requires draining the initial iterator contents.
        drain(matchedIterator, event: .attached)
        drain(terminatedIterator, event: .detached)

        let center = NSWorkspace.shared.notificationCenter
        sleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.onChange(.detached)
        }
        wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.rescan()
        }
    }

    /// Idempotent, and safe to call from `deinit` on any thread.
    ///
    /// The handles are copied out and cleared synchronously, then released on
    /// the main queue — the queue IOKit delivers callbacks on. Releasing an
    /// iterator while `drain` is mid-walk on that queue would be a
    /// use-after-free, and `deinit` carries no main-thread guarantee. Capturing
    /// the handles by value rather than `self` also means the teardown block
    /// never touches a deallocating object.
    public func stop() {
        // nonisolated(unsafe): these are handed to a @Sendable closure below so
        // it can cross to the main queue. IONotificationPortRef and
        // NSObjectProtocol aren't Sendable, but they're captured by value here
        // (not shared mutable state) and the teardown closure is the only thing
        // that ever touches them again, so there is nothing left to race.
        nonisolated(unsafe) let port = notifyPort
        let matched = matchedIterator
        let terminated = terminatedIterator
        nonisolated(unsafe) let sleepObs = sleepObserver
        nonisolated(unsafe) let wakeObs = wakeObserver

        notifyPort = nil
        matchedIterator = 0
        terminatedIterator = 0
        sleepObserver = nil
        wakeObserver = nil

        let teardown: @Sendable () -> Void = {
            if matched != 0 { IOObjectRelease(matched) }
            if terminated != 0 { IOObjectRelease(terminated) }
            if let port { IONotificationPortDestroy(port) }
            let center = NSWorkspace.shared.notificationCenter
            if let sleepObs { center.removeObserver(sleepObs) }
            if let wakeObs { center.removeObserver(wakeObs) }
        }

        if Thread.isMainThread {
            teardown()
        } else {
            DispatchQueue.main.async(execute: teardown)
        }
    }

    /// Emits at most one event per callback, regardless of how many
    /// interfaces the iterator holds.
    ///
    /// The matching dictionary is a bare `IOUSBHostInterface` class match (see
    /// `HiDockDeviceMatching.matchingDictionary`), so these callbacks fire for
    /// EVERY USB interface on the system. Attach events must be filtered here
    /// or plugging in a keyboard would kick off a sync.
    ///
    /// Termination is handled differently: a terminated service may no longer
    /// expose `idVendor`, so the filter cannot be trusted on the way out.
    /// Any termination triggers an authoritative rescan instead.
    private func drain(_ iterator: io_iterator_t, event: DeviceEvent) {
        var sawRelevant = false
        while case let service = IOIteratorNext(iterator), service != 0 {
            if event == .detached || HiDockDeviceMatching.isHiDockP1Interface(service) {
                sawRelevant = true
            }
            IOObjectRelease(service)
        }
        guard sawRelevant else { return }
        if event == .detached { rescan() } else { onChange(.attached) }
    }

    public func rescan() {
        let services = HiDockDeviceMatching.copyMatchingServices()
        defer { services.forEach { IOObjectRelease($0) } }
        onChange(services.isEmpty ? .detached : .attached)
    }
}
