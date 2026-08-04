// Sources/HiDockCLI/main.swift
import Foundation
import IOKit
import IOUSBHost
import HiDockKit

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "probe"

switch command {
case "probe":
    let services = HiDockDeviceMatching.copyMatchingServices()
    defer { services.forEach { IOObjectRelease($0) } }

    guard let service = services.first else {
        print("No HiDock P1 found.")
        print("Attached USB devices can be listed with: system_profiler SPUSBDataType")
        exit(1)
    }

    let vid = HiDockDeviceMatching.intProperty(service, "idVendor") ?? -1
    let pid = HiDockDeviceMatching.intProperty(service, "idProduct") ?? -1
    print(String(format: "Found interface 0 on VID 0x%04x PID 0x%04x", vid, pid))

    do {
        let iface = try IOUSBHostInterface(
            __ioService: service, options: [], queue: nil, interestHandler: nil)
        defer { iface.destroy() }
        print("Interface claimed.")
        try iface.selectAlternateSetting(0)
        print("Alternate setting 0 selected.")
        let out = try iface.copyPipe(withAddress: 0x01)
        let inp = try iface.copyPipe(withAddress: 0x82)
        print("Pipes opened: OUT 0x01 = \(out), IN 0x82 = \(inp)")
        print("PROBE OK")
    } catch {
        print("Failed: \(error)")
        exit(1)
    }

default:
    print("usage: hidock-cli probe")
    exit(2)
}
