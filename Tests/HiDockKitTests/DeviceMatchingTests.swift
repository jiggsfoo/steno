// Tests/HiDockKitTests/DeviceMatchingTests.swift
import Foundation
import Testing
@testable import HiDockKit

@Test func p1ProductIDsCoverAllKnownRevisions() {
    #expect(HiDockDeviceMatching.p1ProductIDs.sorted() == [0x2040, 0xaf0e, 0xb00e])
}

@Test func vendorIDsCoverActionsAndHiDock() {
    #expect(HiDockDeviceMatching.vendorIDs.sorted() == [0x10d6, 0x3887])
}

@Test func matchingDictionaryIsBuiltForInterfaceZero() {
    let dict = HiDockDeviceMatching.matchingDictionary() as NSDictionary
    #expect(dict["bInterfaceNumber"] as? Int == 0)
}
