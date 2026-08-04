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

    public func stop() {
        if matchedIterator != 0 { IOObjectRelease(matchedIterator); matchedIterator = 0 }
        if terminatedIterator != 0 { IOObjectRelease(terminatedIterator); terminatedIterator = 0 }
        if let notifyPort { IONotificationPortDestroy(notifyPort) }
        notifyPort = nil

        let center = NSWorkspace.shared.notificationCenter
        if let sleepObserver { center.removeObserver(sleepObserver) }
        if let wakeObserver { center.removeObserver(wakeObserver) }
        sleepObserver = nil
        wakeObserver = nil
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
