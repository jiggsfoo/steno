import Foundation
import IOKit
import IOUSBHost

public enum HiDockDeviceMatching {
    public static let vendorIDs: [Int] = [0x10d6, 0x3887]
    public static let p1ProductIDs: [Int] = [0xaf0e, 0xb00e, 0x2040]

    /// Matches interface 0 (the vendor-specific Jensen interface) directly.
    /// macOS claims the audio interfaces separately, so this never contends with AppleUSBAudio.
    public static func matchingDictionary() -> CFMutableDictionary {
        let unmanaged = IOUSBHostInterface.__createMatchingDictionary(
            withVendorID: nil,
            productID: nil,
            bcdDevice: nil,
            interfaceNumber: NSNumber(value: 0),
            configurationValue: nil,
            interfaceClass: nil,
            interfaceSubclass: nil,
            interfaceProtocol: nil,
            speed: nil,
            productIDArray: nil)
        return unmanaged.takeRetainedValue()
    }

    /// Returns io_service_t handles for every attached P1 Jensen interface.
    /// Caller owns each handle and must IOObjectRelease it.
    public static func copyMatchingServices() -> [io_service_t] {
        var iterator: io_iterator_t = 0
        let dict = matchingDictionary()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, dict, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var services: [io_service_t] = []
        while case let svc = IOIteratorNext(iterator), svc != 0 {
            if matchesHiDockP1(svc) {
                services.append(svc)
            } else {
                IOObjectRelease(svc)
            }
        }
        return services
    }

    private static func matchesHiDockP1(_ service: io_service_t) -> Bool {
        guard let vid = intProperty(service, "idVendor"),
              let pid = intProperty(service, "idProduct") else { return false }
        return vendorIDs.contains(vid) && p1ProductIDs.contains(pid)
    }

    /// USB interface nubs inherit idVendor/idProduct from the parent device,
    /// so walk up the IOService plane when the property is not local.
    public static func intProperty(_ service: io_service_t, _ key: String) -> Int? {
        if let cf = IORegistryEntrySearchCFProperty(
            service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)) {
            return (cf as? NSNumber)?.intValue
        }
        return nil
    }
}
