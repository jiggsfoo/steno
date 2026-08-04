import Foundation
import IOKit
import IOUSBHost

public enum HiDockDeviceMatching {
    public static let vendorIDs: [Int] = [0x10d6, 0x3887]
    public static let p1ProductIDs: [Int] = [0xaf0e, 0xb00e, 0x2040]

    /// Matches every USB interface; callers narrow with `isHiDockP1Interface`.
    ///
    /// This is deliberately a bare class match. Passing `interfaceNumber: 0`
    /// to `IOUSBHostInterface.__createMatchingDictionary` produces a dictionary
    /// that matches NOTHING on macOS 27 (build 26A5388g), even though the
    /// device's registered `bInterfaceNumber` really is 0 — IOKit's property
    /// matching compares CFNumber types strictly, not just numeric values.
    /// Verified on hardware 2026-08-04: the predicate form returned 0 matches
    /// while this form found the P1 and claimed it. Filter in Swift instead.
    public static func matchingDictionary() -> CFMutableDictionary {
        IOServiceMatching("IOUSBHostInterface")
    }

    /// Returns io_service_t handles for every attached P1 Jensen interface.
    /// Caller owns each handle and must IOObjectRelease it.
    public static func copyMatchingServices() -> [io_service_t] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, matchingDictionary(), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var services: [io_service_t] = []
        while case let svc = IOIteratorNext(iterator), svc != 0 {
            if isHiDockP1Interface(svc) {
                services.append(svc)
            } else {
                IOObjectRelease(svc)
            }
        }
        return services
    }

    /// True for interface 0 of an attached HiDock P1. Public because
    /// DeviceMonitor must apply the same filter to notification callbacks:
    /// the bare class match fires for every USB interface on the system.
    public static func isHiDockP1Interface(_ service: io_service_t) -> Bool {
        guard let vid = intProperty(service, "idVendor"),
              let pid = intProperty(service, "idProduct"),
              let interfaceNumber = intProperty(service, "bInterfaceNumber") else { return false }
        return vendorIDs.contains(vid) && p1ProductIDs.contains(pid) && interfaceNumber == 0
    }

    /// USB interface nubs inherit idVendor/idProduct from the parent device,
    /// so walk up the IOService plane when the property is not local.
    /// Public because HiDockCLI (a separate module) calls it.
    public static func intProperty(_ service: io_service_t, _ key: String) -> Int? {
        if let cf = IORegistryEntrySearchCFProperty(
            service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)) {
            return (cf as? NSNumber)?.intValue
        }
        return nil
    }
}
