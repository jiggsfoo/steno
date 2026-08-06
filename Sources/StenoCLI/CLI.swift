// Sources/StenoCLI/CLI.swift
import Foundation
import IOKit
import IOUSBHost
import JensenKit
import StenoUI

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
            await device.close()
            print("LIST OK")

        case "pull":
            guard args.count >= 2 else { print("usage: steno pull <device-filename>"); exit(2) }
            let target = args[1]

            let transport = try IOUSBHostTransport.openFirstAvailable()
            let device = JensenDevice(transport: transport)
            try await device.open()


            let files = try await device.listFiles()
            guard let file = files.first(where: { $0.name == target }) else {
                print("not found on device: \(target)"); exit(1)
            }

            // Write with the corrected extension so the result is directly playable.
            // The device names MP3 recordings `.hda`; the bytes need no conversion.
            let stem = (file.name as NSString).deletingPathExtension
            let out = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("\(stem).\(file.preferredExtension)")
            try await device.transferFile(file, to: out) { done, total in
                let pct = total > 0 ? done * 100 / total : 0
                FileHandle.standardError.write(Data("\r\(pct)% (\(done)/\(total))".utf8))
            }
            await device.close()
            print("\nwrote \(out.path)")
            print("PULL OK")

        case "watch":
            // Line-buffer stdout. print() BLOCK-buffers to a pipe or file, so every
            // event is lost unflushed when the process is killed — `watch > log`
            // produces an empty file and the monitor looks broken when it is not.
            setvbuf(stdout, nil, _IOLBF, 0)

            print("Watching for HiDock P1 attach/detach. Ctrl-C to stop.")
            let monitor = DeviceMonitor { event in
                let stamp = ISO8601DateFormatter().string(from: Date())
                switch event {
                case .attached: print("\(stamp)  ATTACHED")
                case .detached: print("\(stamp)  DETACHED")
                }
            }
            monitor.start()

            // withExtendedLifetime is load-bearing, not defensive. Nothing else holds a
            // strong reference — IOKit keeps only an unretained pointer — so ARC may
            // release `monitor` at its last syntactic use, running deinit -> stop() and
            // tearing down every notification before the process even parks. The
            // initial rescan() would still print ATTACHED, so the tool would look like
            // it worked while being permanently deaf to attach and detach.
            withExtendedLifetime(monitor) {
                // RunLoop.main.run() is `noasync`, so it cannot be called directly from
                // an async main. The Swift concurrency runtime parks the real main
                // thread in dispatch_main() and drains DispatchQueue.main, which is
                // where IOKit delivers, so this only needs to not return.
                func parkForever() { RunLoop.main.run() }
                parkForever()
            }

        default:
            print("usage: steno [probe|info|list|pull <name>|watch]")
            exit(2)
        }
    }
}
