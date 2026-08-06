// Tests/JensenKitTests/DeviceMatchingTests.swift
import Foundation
import Testing
@testable import JensenKit

@Test func p1ProductIDsCoverAllKnownRevisions() {
    #expect(HiDockDeviceMatching.p1ProductIDs.sorted() == [0x2040, 0xaf0e, 0xb00e])
}

@Test func vendorIDsCoverActionsAndHiDock() {
    #expect(HiDockDeviceMatching.vendorIDs.sorted() == [0x10d6, 0x3887])
}

/// The dictionary is a bare class match on purpose. Narrowing it with an
/// `interfaceNumber` criterion matches nothing on macOS 27; interface 0 is
/// selected in Swift by `isHiDockP1Interface` instead.
@Test func matchingDictionaryIsABareInterfaceClassMatch() {
    let dict = HiDockDeviceMatching.matchingDictionary() as NSDictionary
    #expect(dict["IOProviderClass"] as? String == "IOUSBHostInterface")
    #expect(dict["bInterfaceNumber"] == nil)
}

/// A service handle of 0 is never a device, and the filter must not trap on it.
@Test func isHiDockP1InterfaceRejectsNullService() {
    #expect(HiDockDeviceMatching.isHiDockP1Interface(0) == false)
}
