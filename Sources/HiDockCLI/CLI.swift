// Sources/HiDockCLI/CLI.swift
import Foundation
import IOKit
import IOUSBHost
import HiDockKit

@main
struct CLI {
    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        let command = args.first ?? "probe"

        switch command {
        case "probe":
            let services = HiDockDeviceMatching.copyMatchingServices()
            defer { services.forEach { IOObjectRelease($0) } }

            guard let service = services.first else {
                print("No HiDock P1 found.")
                // Note: SPUSBDataType returns nothing at all on macOS 27 (26A5388g).
                print("Attached USB devices can be listed with: system_profiler SPUSBHostDataType")
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

        case "info":
            let transport = try IOUSBHostTransport.openFirstAvailable()
            let device = JensenDevice(transport: transport)
            try await device.open()

            let body = try await device.send(.getDeviceInfo, timeout: .seconds(5))
            print("device info body (\(body.count) bytes): \(body.map { String(format: "%02x", $0) }.joined())")
            // Awaited, not `defer { Task { ... } }` — the process exits before a
            // detached task runs, so destroy() would never execute.
            await device.close()
            print("INFO OK")

        case "list":
            let transport = try IOUSBHostTransport.openFirstAvailable()
            let device = JensenDevice(transport: transport)
            try await device.open()


            let info = try await device.deviceInfo()
            print("firmware \(info.versionCode)  serial \(info.serialNumber)")

            // The GET_DEVICE_TIME body layout is NOT documented in either reference
            // implementation. Dump it raw so the real format can be read off the
            // device before anything ever writes SET_DEVICE_TIME.
            if let timeBody = try? await device.send(.getDeviceTime, timeout: .seconds(5)) {
                let hex = timeBody.map { String(format: "%02x", $0) }.joined(separator: " ")
                print("device time body (\(timeBody.count) bytes): \(hex)")
                print("  ^ compare against the wall clock now: \(Date())")
            }

            let card = try await device.cardInfo()
            print("storage: \(card.usedMiB) MiB used of \(card.capacityMiB) MiB")

            let count = try await device.fileCount()
            let files = try await device.listFiles()
            print("device reports \(count) files, listed \(files.count)")
            for f in files {
                let when = f.recordedAt.map(ISO8601DateFormatter().string(from:)) ?? "unknown"
                print("  \(f.name)  \(f.lengthBytes) bytes  \(when)  \(f.signature)")
            }
            print("LIST OK")

        default:
            print("usage: hidock-cli [probe|info|list]")
            exit(2)
        }
    }
}
