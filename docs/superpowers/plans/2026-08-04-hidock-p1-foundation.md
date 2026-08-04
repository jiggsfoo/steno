# HiDock P1 Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A macOS menubar app that detects a HiDock P1 over USB and automatically copies new recordings into a local folder, never deleting anything from the device.

**Architecture:** A dependency-free SPM package (`HiDockKit`) implements the Jensen wire protocol over `IOUSBHost` behind a `USBTransport` protocol, so the entire packet and command layer is testable against a fake with no hardware attached. A second executable target (`HiDockMenubar`) adds a SwiftUI `MenuBarExtra`, an IOKit attach/detach monitor, a sync engine, and a file-backed library whose SQLite index is a rebuildable cache.

**Tech Stack:** Swift 6.3, SPM (no third-party dependencies), IOUSBHost, IOKit, SQLite3, AVFoundation, SwiftUI, ServiceManagement, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-08-04-hidock-p1-foundation-design.md`

## Global Constraints

- `swift-tools-version: 6.0`. Swift 6 language mode, strict concurrency enabled. All shared types are `Sendable`.
- Platform floor: `.macOS(.v15)`.
- **Zero third-party dependencies.** Only Foundation, IOUSBHost, IOKit, SQLite3, AVFoundation, SwiftUI, ServiceManagement, Testing.
- Tests use **Swift Testing** (`import Testing`, `@Test`, `#expect`), never XCTest.
- **No test in the suite may require an attached P1.** Hardware verification happens only through explicit `hidock-cli` commands run by hand.
- All multi-byte protocol fields are **big-endian**.
- The device is **never** sent `DELETE_FILE` outside the explicit reclaim flow in Task 11.
- A recording whose received byte count does not equal the device-reported length must **never** be committed to the library.
- `sgeraldes/hidock-next` and `ghecko/OpenHiNotes` (both MIT) are **wire-format reference only**. Write original Swift. Credit both in `README.md`.
- Every task ends with a commit.

## Verified API facts

These were confirmed by typechecking against the macOS SDK on 2026-08-04. Do not "correct" them from memory.

```swift
// No IOUSBHostDevice is needed. Match the interface directly.
let iface = try IOUSBHostInterface(__ioService: svc, options: [], queue: nil, interestHandler: nil)
let out   = try iface.copyPipe(withAddress: 0x01)
let inp   = try iface.copyPipe(withAddress: 0x82)
try iface.selectAlternateSetting(0)

var n = 0
try pipe.__sendIORequest(with: nsMutableData, bytesTransferred: &n, completionTimeout: 5.0)
iface.destroy()

IOUSBHostInterface.__createMatchingDictionary(
    withVendorID: NSNumber?, productID: NSNumber?, bcdDevice: NSNumber?,
    interfaceNumber: NSNumber?, configurationValue: NSNumber?, interfaceClass: NSNumber?,
    interfaceSubclass: NSNumber?, interfaceProtocol: NSNumber?, speed: NSNumber?,
    productIDArray: NSArray?)   // returns Unmanaged<CFMutableDictionary>
```

`sendIORequest(with:completionTimeout:)` without the `__` prefix resolves to the **isochronous** overloads and will not compile for bulk transfers.

## Wire formats

**Frame** (12-byte header, big-endian):

| Offset | Size | Field |
|---|---|---|
| 0 | 2 | sync marker, always `0x12 0x34` |
| 2 | 2 | command id (u16) |
| 4 | 4 | sequence (u32) |
| 8 | 4 | top byte = padding length, low 24 bits = body length |
| 12 | n | body |

**File list body:** optional 6-byte header (`0xFF 0xFF` + u32 total count), then repeating entries:

| Size | Field |
|---|---|
| 1 | file version |
| 3 | filename length (u24) |
| n | filename ASCII, skip zero bytes |
| 4 | file length in bytes (u32) |
| 6 | padding, skip |
| 16 | signature, hex-encode to a 32-char string |

**Device info body:** bytes 0-3 version (u32; display form is bytes 1,2,3 joined with `.`), bytes 4-19 serial number ASCII, skip zero bytes.

**Card info body:** u32 free MiB, u32 capacity MiB, u32 status.

**Deliberate deviation from the reference implementations:** they derive duration from a `fileVersion`-to-bitrate lookup table. We do not. Duration is read from the actual audio header with `AVURLAsset` after download (Task 7), which is measured rather than guessed. Nothing before download needs a duration.

## File structure

```
Package.swift
Scripts/make-app.sh                        assembles HiDock.app from the built executable
README.md                                  attribution to hidock-next + OpenHiNotes

Sources/HiDockKit/
  JensenCommand.swift                      command code enum
  JensenPacket.swift                       frame encode/decode, pure, no I/O
  JensenError.swift                        error enum
  USBTransport.swift                       protocol: the test seam
  IOUSBHostTransport.swift                 real hardware implementation
  DeviceMatching.swift                     VID/PID constants + IOKit matching dictionary
  JensenDevice.swift                       actor: command lifecycle, timeouts, draining
  Models.swift                             DeviceInfo, FileInfo, CardInfo, BatteryStatus
  ResponseParsers.swift                    body parsing for each command

Sources/HiDockCLI/
  main.swift                               probe | info | list | pull

Sources/HiDockMenubar/
  Info.plist                               LSUIElement = 1
  HiDockApp.swift                          @main, MenuBarExtra
  AppModel.swift                           @MainActor @Observable menubar state
  DeviceMonitor.swift                      IOKit attach/detach notifications
  SyncEngine.swift                         actor: connect, diff, download, verify, commit
  Library.swift                            folder + sidecar writes
  LibraryIndex.swift                       SQLite index, rebuildable
  Sidecar.swift                            Codable sidecar record
  MenuBarView.swift                        dropdown UI
  SettingsView.swift                       root picker, login item, rebuild index

Tests/HiDockKitTests/
  JensenPacketTests.swift
  FakeTransport.swift
  JensenDeviceTests.swift
  ResponseParserTests.swift
  TransferTests.swift

Tests/HiDockMenubarTests/
  LibraryTests.swift
  LibraryIndexTests.swift
  SyncEngineTests.swift
  FakeDevice.swift
```

**Why SPM and not an Xcode project:** the whole tree builds with `swift build` and `swift test`, with no GUI steps. `Scripts/make-app.sh` assembles the `.app` bundle that `SMAppService` needs. Trade-off: no SwiftUI previews. For a menubar dropdown that is a fair trade, and an `.xcodeproj` can be added later without moving any source.

---

### Task 1: Package scaffold and hardware probe

Proves the single riskiest assumption in the spec: that a non-sandboxed Swift binary can claim interface 0 on the P1. Nothing else is built until this works.

**Files:**
- Create: `Package.swift`
- Create: `Sources/HiDockKit/DeviceMatching.swift`
- Create: `Sources/HiDockKit/JensenError.swift`
- Create: `Sources/HiDockCLI/main.swift`
- Create: `README.md`
- Test: `Tests/HiDockKitTests/DeviceMatchingTests.swift`

**Interfaces:**
- Produces: `HiDockDeviceMatching.vendorIDs: [Int]`, `HiDockDeviceMatching.p1ProductIDs: [Int]`, `HiDockDeviceMatching.matchingDictionary() -> CFMutableDictionary`, `HiDockDeviceMatching.copyMatchingServices() -> [io_service_t]`, `enum JensenError: Error`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/HiDockKitTests/DeviceMatchingTests.swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter DeviceMatchingTests`
Expected: FAIL, `cannot find 'HiDockDeviceMatching' in scope`

- [ ] **Step 3: Write `Package.swift`**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HiDockKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "HiDockKit", targets: ["HiDockKit"]),
        .executable(name: "hidock-cli", targets: ["HiDockCLI"]),
    ],
    targets: [
        .target(name: "HiDockKit"),
        .executableTarget(name: "HiDockCLI", dependencies: ["HiDockKit"]),
        .testTarget(name: "HiDockKitTests", dependencies: ["HiDockKit"]),
    ]
)
```

- [ ] **Step 4: Write `JensenError.swift`**

```swift
import Foundation

public enum JensenError: Error, Equatable {
    case deviceNotFound
    case interfaceUnavailable(String)
    case invalidHeader
    case timeout(command: UInt16)
    case shortBody(command: UInt16, expected: Int, got: Int)
    case transferIncomplete(expected: Int, got: Int)
    case notConnected
}
```

- [ ] **Step 5: Write `DeviceMatching.swift`**

```swift
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
    static func intProperty(_ service: io_service_t, _ key: String) -> Int? {
        if let cf = IORegistryEntrySearchCFProperty(
            service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)) {
            return (cf as? NSNumber)?.intValue
        }
        return nil
    }
}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `swift test --filter DeviceMatchingTests`
Expected: PASS, 3 tests

- [ ] **Step 7: Write the probe CLI**

```swift
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
```

- [ ] **Step 8: Hardware check (manual, requires the P1 plugged in)**

Run: `swift run hidock-cli probe`
Expected: `PROBE OK`

If it prints `No HiDock P1 found`, run `system_profiler SPUSBDataType | grep -A5 -i hidock`, read the real vendor and product IDs, and add them to `DeviceMatching.swift` plus the Step 1 tests.

If the claim fails with an access error, the fallback documented in the spec applies: switch `IOUSBHostTransport` to the legacy `IOKit`/`IOUSBLib` plugin interface in Task 4. Endpoints and framing are unchanged. **Stop and report this before continuing.**

- [ ] **Step 9: Write `README.md`**

```markdown
# hidock-mac

Native macOS menubar app for the HiDock P1 voice recorder. Replaces the
hinotes.hidock.com web app for device sync.

## Credits

The Jensen wire protocol was reverse-engineered by the community. This project
is an original Swift implementation written against those published findings:

- [sgeraldes/hidock-next](https://github.com/sgeraldes/hidock-next) (MIT)
- [ghecko/OpenHiNotes](https://github.com/ghecko/OpenHiNotes) (MIT)

Not affiliated with or endorsed by HiDock.

## Build

    swift build
    swift test
    swift run hidock-cli probe
```

- [ ] **Step 10: Commit**

```bash
git add Package.swift Sources/HiDockKit Sources/HiDockCLI Tests README.md
git commit -m "feat(kit): package scaffold, device matching, hardware probe CLI"
```

---

### Task 2: Jensen packet codec

Pure encode/decode with no I/O. Every edge case that bit the reference implementation is a test here.

**Files:**
- Create: `Sources/HiDockKit/JensenCommand.swift`
- Create: `Sources/HiDockKit/JensenPacket.swift`
- Test: `Tests/HiDockKitTests/JensenPacketTests.swift`

**Interfaces:**
- Consumes: `JensenError` (Task 1)
- Produces: `enum JensenCommand: UInt16`, `struct JensenPacket { command: UInt16, sequence: UInt32, body: Data }`, `JensenPacket.encoded() -> Data`, `JensenPacket.decode(from: Data) throws -> JensenPacket.DecodeResult`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/HiDockKitTests/JensenPacketTests.swift
import Foundation
import Testing
@testable import HiDockKit

@Test func encodesTwelveByteHeaderWithSyncMarker() {
    let p = JensenPacket(command: 1, sequence: 0, body: Data())
    let bytes = [UInt8](p.encoded())
    #expect(bytes.count == 12)
    #expect(bytes[0] == 0x12)
    #expect(bytes[1] == 0x34)
    #expect(bytes[2] == 0x00 && bytes[3] == 0x01)          // command, big-endian
    #expect(Array(bytes[8...11]) == [0, 0, 0, 0])           // body length
}

@Test func encodesCommandAndSequenceBigEndian() {
    let p = JensenPacket(command: 4100, sequence: 0x01020304, body: Data())
    let bytes = [UInt8](p.encoded())
    #expect(bytes[2] == 0x10 && bytes[3] == 0x04)           // 4100 = 0x1004
    #expect(Array(bytes[4...7]) == [0x01, 0x02, 0x03, 0x04])
}

@Test func encodesBodyAndLength() {
    let p = JensenPacket(command: 5, sequence: 1, body: Data([0xAA, 0xBB, 0xCC]))
    let bytes = [UInt8](p.encoded())
    #expect(Array(bytes[8...11]) == [0, 0, 0, 3])
    #expect(Array(bytes[12...14]) == [0xAA, 0xBB, 0xCC])
}

@Test func roundTrips() throws {
    let original = JensenPacket(command: 4, sequence: 42, body: Data([1, 2, 3, 4, 5]))
    guard case let .packet(decoded, consumed) =
        try JensenPacket.decode(from: original.encoded()) else {
        Issue.record("expected a packet"); return
    }
    #expect(decoded == original)
    #expect(consumed == 17)
}

@Test func decodeReportsNeedMoreDataOnShortHeader() throws {
    let result = try JensenPacket.decode(from: Data([0x12, 0x34, 0x00]))
    #expect(result == .needMoreData)
}

@Test func decodeReportsNeedMoreDataOnTruncatedBody() throws {
    var bytes = [UInt8](JensenPacket(command: 1, sequence: 0, body: Data([9, 9, 9, 9])).encoded())
    bytes.removeLast(2)
    #expect(try JensenPacket.decode(from: Data(bytes)) == .needMoreData)
}

@Test func decodeThrowsOnBadSyncMarker() {
    #expect(throws: JensenError.invalidHeader) {
        _ = try JensenPacket.decode(from: Data([0xDE, 0xAD, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0]))
    }
}

/// The length word packs a padding byte into its top 8 bits and the body
/// length into the low 24. Padding bytes trail the body and are consumed
/// but not returned.
@Test func decodeHonoursPaddingByteInLengthWord() throws {
    var bytes: [UInt8] = [0x12, 0x34, 0x00, 0x01, 0, 0, 0, 0]
    bytes += [0x02, 0x00, 0x00, 0x03]          // padding 2, body length 3
    bytes += [0xAA, 0xBB, 0xCC]                // body
    bytes += [0x00, 0x00]                      // padding
    guard case let .packet(p, consumed) = try JensenPacket.decode(from: Data(bytes)) else {
        Issue.record("expected a packet"); return
    }
    #expect(p.body == Data([0xAA, 0xBB, 0xCC]))
    #expect(consumed == 17)
}

/// Two packets arriving in one bulk read must both decode.
@Test func decodesFirstOfTwoConcatenatedPackets() throws {
    var buffer = JensenPacket(command: 1, sequence: 1, body: Data([1])).encoded()
    buffer.append(JensenPacket(command: 2, sequence: 2, body: Data([2, 2])).encoded())

    guard case let .packet(first, consumed) = try JensenPacket.decode(from: buffer) else {
        Issue.record("expected first packet"); return
    }
    #expect(first.command == 1)

    guard case let .packet(second, _) =
        try JensenPacket.decode(from: buffer.dropFirst(consumed)) else {
        Issue.record("expected second packet"); return
    }
    #expect(second.command == 2)
    #expect(second.body == Data([2, 2]))
}

/// Regression guard: Data slices keep their parent's indices, so any decoder
/// that assumes a zero start index breaks on the second packet of a read.
@Test func decodesFromASliceWithNonZeroStartIndex() throws {
    var buffer = Data([0xFF, 0xFF, 0xFF])
    buffer.append(JensenPacket(command: 7, sequence: 3, body: Data([8])).encoded())
    let slice = buffer.dropFirst(3)
    #expect(slice.startIndex == 3)

    guard case let .packet(p, _) = try JensenPacket.decode(from: slice) else {
        Issue.record("expected a packet"); return
    }
    #expect(p.command == 7)
    #expect(p.body == Data([8]))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter JensenPacketTests`
Expected: FAIL, `cannot find 'JensenPacket' in scope`

- [ ] **Step 3: Write `JensenCommand.swift`**

```swift
import Foundation

public enum JensenCommand: UInt16, Sendable {
    case getDeviceInfo     = 1
    case getDeviceTime     = 2
    case setDeviceTime     = 3
    case getFileList       = 4
    case transferFile      = 5
    case getFileCount      = 6
    case deleteFile        = 7
    case getCardInfo       = 16
    case getBatteryStatus  = 4100
}
```

- [ ] **Step 4: Write `JensenPacket.swift`**

```swift
import Foundation

public struct JensenPacket: Sendable, Equatable {
    public let command: UInt16
    public let sequence: UInt32
    public let body: Data

    public init(command: UInt16, sequence: UInt32, body: Data = Data()) {
        self.command = command
        self.sequence = sequence
        self.body = body
    }

    public init(command: JensenCommand, sequence: UInt32, body: Data = Data()) {
        self.init(command: command.rawValue, sequence: sequence, body: body)
    }

    public static let headerSize = 12
    private static let syncMarker: [UInt8] = [0x12, 0x34]

    public func encoded() -> Data {
        var out = Data(capacity: Self.headerSize + body.count)
        out.append(contentsOf: Self.syncMarker)
        out.append(UInt8(truncatingIfNeeded: command >> 8))
        out.append(UInt8(truncatingIfNeeded: command))
        out.append(UInt8(truncatingIfNeeded: sequence >> 24))
        out.append(UInt8(truncatingIfNeeded: sequence >> 16))
        out.append(UInt8(truncatingIfNeeded: sequence >> 8))
        out.append(UInt8(truncatingIfNeeded: sequence))
        let length = UInt32(body.count)          // padding byte is 0 on send
        out.append(UInt8(truncatingIfNeeded: length >> 24))
        out.append(UInt8(truncatingIfNeeded: length >> 16))
        out.append(UInt8(truncatingIfNeeded: length >> 8))
        out.append(UInt8(truncatingIfNeeded: length))
        out.append(body)
        return out
    }

    public enum DecodeResult: Sendable, Equatable {
        case needMoreData
        case packet(JensenPacket, consumed: Int)
    }

    /// Decodes one packet from the front of `buffer`.
    /// `buffer` may be a slice; all indexing is relative to `startIndex`.
    public static func decode(from buffer: Data) throws -> DecodeResult {
        let base = buffer.startIndex
        let available = buffer.count
        guard available >= headerSize else { return .needMoreData }

        guard buffer[base] == syncMarker[0], buffer[base + 1] == syncMarker[1] else {
            throw JensenError.invalidHeader
        }

        let command = UInt16(buffer[base + 2]) << 8 | UInt16(buffer[base + 3])
        let sequence = UInt32(buffer[base + 4]) << 24
            | UInt32(buffer[base + 5]) << 16
            | UInt32(buffer[base + 6]) << 8
            | UInt32(buffer[base + 7])

        let raw = UInt32(buffer[base + 8]) << 24
            | UInt32(buffer[base + 9]) << 16
            | UInt32(buffer[base + 10]) << 8
            | UInt32(buffer[base + 11])
        let padding = Int((raw >> 24) & 0xFF)
        let bodyLength = Int(raw & 0x00FF_FFFF)

        let total = headerSize + bodyLength + padding
        guard available >= total else { return .needMoreData }

        let bodyStart = base + headerSize
        let body = Data(buffer[bodyStart ..< bodyStart + bodyLength])
        let packet = JensenPacket(command: command, sequence: sequence, body: body)
        return .packet(packet, consumed: total)
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter JensenPacketTests`
Expected: PASS, 10 tests

- [ ] **Step 6: Commit**

```bash
git add Sources/HiDockKit/JensenCommand.swift Sources/HiDockKit/JensenPacket.swift Tests/HiDockKitTests/JensenPacketTests.swift
git commit -m "feat(kit): Jensen packet codec with padding and slice handling"
```

---

### Task 3: Transport seam and JensenDevice actor

The actor's serial executor is what enforces the protocol's single-outstanding-command invariant.

**Files:**
- Create: `Sources/HiDockKit/USBTransport.swift`
- Create: `Sources/HiDockKit/JensenDevice.swift`
- Test: `Tests/HiDockKitTests/FakeTransport.swift`
- Test: `Tests/HiDockKitTests/JensenDeviceTests.swift`

**Interfaces:**
- Consumes: `JensenPacket`, `JensenCommand`, `JensenError`
- Produces: `protocol USBTransport: Sendable { func open() async throws; func close() async; func write(_: Data) async throws; func read(maxLength: Int, timeout: Duration) async throws -> Data }`, `actor JensenDevice`, `JensenDevice.init(transport:)`, `JensenDevice.send(_: JensenCommand, body: Data, timeout: Duration) async throws -> Data`, `JensenDevice.open()`, `JensenDevice.close()`

- [ ] **Step 1: Write the fake transport**

```swift
// Tests/HiDockKitTests/FakeTransport.swift
import Foundation
@testable import HiDockKit

/// Scriptable transport. Each written command id maps to the responses the
/// device would return, popped in order.
actor FakeTransport: USBTransport {
    struct Script: Sendable {
        var responses: [UInt16: [Data]] = [:]
        var readTimeoutFor: Set<UInt16> = []
    }

    private var script: Script
    private var pending: [Data] = []
    private(set) var written: [JensenPacket] = []
    private(set) var openCount = 0
    private(set) var closeCount = 0

    init(script: Script) { self.script = script }

    func open() async throws { openCount += 1 }
    func close() async { closeCount += 1 }

    func write(_ data: Data) async throws {
        guard case let .packet(p, _) = try JensenPacket.decode(from: data) else { return }
        written.append(p)
        if script.readTimeoutFor.contains(p.command) { return }   // deliberately answer nothing
        for body in script.responses[p.command] ?? [] {
            pending.append(JensenPacket(command: p.command, sequence: p.sequence, body: body).encoded())
        }
    }

    /// Hands back at most `readSplit` bytes per call, so encoded packets
    /// genuinely arrive across multiple reads and the device layer has to
    /// reassemble them. A fake that always returns whole packets would let a
    /// broken reassembler pass.
    private static let readSplit = 64

    func read(maxLength: Int, timeout: Duration) async throws -> Data {
        guard !pending.isEmpty else { return Data() }
        let next = pending.removeFirst()
        guard next.count > Self.readSplit else { return next }
        pending.insert(next.dropFirst(Self.readSplit), at: 0)
        return Data(next.prefix(Self.readSplit))
    }

    /// Queue an unsolicited packet, simulating a late response arriving after a timeout.
    func injectStrayResponse(command: UInt16, sequence: UInt32, body: Data) {
        pending.append(JensenPacket(command: command, sequence: sequence, body: body).encoded())
    }
}
```

- [ ] **Step 2: Write the failing tests**

```swift
// Tests/HiDockKitTests/JensenDeviceTests.swift
import Foundation
import Testing
@testable import HiDockKit

@Test func sendReturnsMatchingResponseBody() async throws {
    let t = FakeTransport(script: .init(responses: [1: [Data([0xAB])]]))
    let device = JensenDevice(transport: t)
    try await device.open()
    let body = try await device.send(.getDeviceInfo)
    #expect(body == Data([0xAB]))
}

@Test func sequenceNumbersIncrementPerCommand() async throws {
    let t = FakeTransport(script: .init(responses: [1: [Data([1])], 6: [Data([2])]]))
    let device = JensenDevice(transport: t)
    try await device.open()
    _ = try await device.send(.getDeviceInfo)
    _ = try await device.send(.getFileCount)
    let written = await t.written
    #expect(written.map(\.sequence) == [0, 1])
}

@Test func reassemblesBodySplitAcrossReads() async throws {
    // FakeTransport hands back 64 bytes per read, so this 300-byte body
    // arrives across five reads and must be reassembled.
    let t = FakeTransport(script: .init(responses: [4: [Data(repeating: 0x7, count: 300)]]))
    let device = JensenDevice(transport: t)
    try await device.open()
    let body = try await device.send(.getFileList)
    #expect(body.count == 300)
}

@Test func timesOutWhenDeviceNeverAnswers() async throws {
    let t = FakeTransport(script: .init(responses: [:], readTimeoutFor: [1]))
    let device = JensenDevice(transport: t)
    try await device.open()
    await #expect(throws: JensenError.timeout(command: 1)) {
        _ = try await device.send(.getDeviceInfo, timeout: .milliseconds(50))
    }
}

/// After a timeout the IN endpoint must be drained, or a late response
/// would be matched against the *next* command and desync everything.
@Test func drainsStrayResponseAfterTimeout() async throws {
    let t = FakeTransport(script: .init(responses: [6: [Data([0, 0, 0, 3])]], readTimeoutFor: [1]))
    let device = JensenDevice(transport: t)
    try await device.open()

    _ = try? await device.send(.getDeviceInfo, timeout: .milliseconds(50))
    await t.injectStrayResponse(command: 1, sequence: 0, body: Data([0xDE, 0xAD]))
    await device.drain()

    let body = try await device.send(.getFileCount)
    #expect(body == Data([0, 0, 0, 3]))          // not the stray 0xDEAD
}

@Test func concurrentCallersAreSerialized() async throws {
    let t = FakeTransport(script: .init(responses: [1: [Data([1])], 6: [Data([2])], 16: [Data([3])]]))
    let device = JensenDevice(transport: t)
    try await device.open()

    async let a = device.send(.getDeviceInfo)
    async let b = device.send(.getFileCount)
    async let c = device.send(.getCardInfo)
    _ = try await (a, b, c)

    let written = await t.written
    #expect(written.count == 3)
    #expect(Set(written.map(\.sequence)) == [0, 1, 2])   // no reuse
}

@Test func openAndCloseForwardToTransport() async throws {
    let t = FakeTransport(script: .init())
    let device = JensenDevice(transport: t)
    try await device.open()
    await device.close()
    #expect(await t.openCount == 1)
    #expect(await t.closeCount == 1)
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter JensenDeviceTests`
Expected: FAIL, `cannot find 'USBTransport' in scope`

- [ ] **Step 4: Write `USBTransport.swift`**

```swift
import Foundation

public protocol USBTransport: Sendable, Actor {
    func open() async throws
    func close() async
    func write(_ data: Data) async throws
    /// Returns an empty Data when nothing arrived before the timeout.
    func read(maxLength: Int, timeout: Duration) async throws -> Data
}
```

- [ ] **Step 5: Write `JensenDevice.swift`**

```swift
import Foundation

public actor JensenDevice {
    private let transport: any USBTransport
    private var sequence: UInt32 = 0
    private var buffer = Data()

    /// Bulk reads are capped at this size. The device streams file data in
    /// chunks well under this, and oversizing costs nothing but a temp buffer.
    private static let readChunk = 64 * 1024

    public init(transport: any USBTransport) {
        self.transport = transport
    }

    public func open() async throws {
        try await transport.open()
        buffer.removeAll(keepingCapacity: true)
        sequence = 0
        // Some devices reject commands issued immediately after interface claim.
        try? await Task.sleep(for: .milliseconds(300))
    }

    public func close() async {
        await transport.close()
        buffer.removeAll(keepingCapacity: true)
    }

    @discardableResult
    public func send(
        _ command: JensenCommand,
        body: Data = Data(),
        timeout: Duration = .seconds(5)
    ) async throws -> Data {
        try await sendRaw(command.rawValue, body: body, timeout: timeout)
    }

    func sendRaw(_ command: UInt16, body: Data, timeout: Duration) async throws -> Data {
        let seq = sequence
        sequence &+= 1
        try await transport.write(
            JensenPacket(command: command, sequence: seq, body: body).encoded())
        return try await awaitResponse(command: command, timeout: timeout)
    }

    /// Reads until a packet whose command id matches arrives, or the deadline passes.
    /// Packets for other commands are discarded as stale.
    private func awaitResponse(command: UInt16, timeout: Duration) async throws -> Data {
        let deadline = ContinuousClock.now.advanced(by: timeout)

        while true {
            if let packet = try takeBufferedPacket(matching: command) { return packet }

            guard ContinuousClock.now < deadline else {
                throw JensenError.timeout(command: command)
            }

            let chunk = try await transport.read(maxLength: Self.readChunk, timeout: timeout)
            if chunk.isEmpty {
                try await Task.sleep(for: .milliseconds(5))
                continue
            }
            buffer.append(chunk)
        }
    }

    private func takeBufferedPacket(matching command: UInt16) throws -> Data? {
        while !buffer.isEmpty {
            let result: JensenPacket.DecodeResult
            do {
                result = try JensenPacket.decode(from: buffer)
            } catch JensenError.invalidHeader {
                // Stream is desynced. Nothing in this buffer can be trusted.
                buffer.removeAll(keepingCapacity: true)
                throw JensenError.invalidHeader
            }

            guard case let .packet(packet, consumed) = result else { return nil }
            buffer.removeFirst(consumed)
            if packet.command == command { return packet.body }
            // else: stale response for an earlier command, drop it and keep looking
        }
        return nil
    }

    /// Reads and discards anything still queued on the IN endpoint.
    /// Must be called after a timeout before issuing the next command.
    public func drain(maxDuration: Duration = .milliseconds(500)) async {
        buffer.removeAll(keepingCapacity: true)
        let deadline = ContinuousClock.now.advanced(by: maxDuration)
        while ContinuousClock.now < deadline {
            guard let chunk = try? await transport.read(
                maxLength: Self.readChunk, timeout: .milliseconds(50)),
                  !chunk.isEmpty else { return }
        }
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter JensenDeviceTests`
Expected: PASS, 7 tests

- [ ] **Step 7: Commit**

```bash
git add Sources/HiDockKit/USBTransport.swift Sources/HiDockKit/JensenDevice.swift Tests/HiDockKitTests/FakeTransport.swift Tests/HiDockKitTests/JensenDeviceTests.swift
git commit -m "feat(kit): USBTransport seam and JensenDevice actor with drain-after-timeout"
```

---

### Task 4: Real hardware transport

**Files:**
- Create: `Sources/HiDockKit/IOUSBHostTransport.swift`
- Modify: `Sources/HiDockCLI/main.swift`

**Interfaces:**
- Consumes: `USBTransport`, `JensenError`, `HiDockDeviceMatching`
- Produces: `actor IOUSBHostTransport: USBTransport`, `IOUSBHostTransport.init(service: io_service_t)`, `IOUSBHostTransport.openFirstAvailable() throws -> IOUSBHostTransport`

- [ ] **Step 1: Write `IOUSBHostTransport.swift`**

Uses the API signatures verified in the header of this plan. `__sendIORequest` is synchronous and blocking, so every call is wrapped in a detached task on a dedicated queue to keep the actor's executor free.

```swift
import Foundation
import IOKit
import IOUSBHost

public actor IOUSBHostTransport: USBTransport {
    private let service: io_service_t
    private var interface: IOUSBHostInterface?
    private var outPipe: IOUSBHostPipe?
    private var inPipe: IOUSBHostPipe?

    private static let endpointOut: UInt = 0x01
    private static let endpointIn: UInt = 0x82

    public init(service: io_service_t) {
        self.service = service
    }

    /// Convenience for the CLI and for SyncEngine's connect path.
    public static func openFirstAvailable() throws -> IOUSBHostTransport {
        let services = HiDockDeviceMatching.copyMatchingServices()
        guard let first = services.first else { throw JensenError.deviceNotFound }
        for extra in services.dropFirst() { IOObjectRelease(extra) }
        return IOUSBHostTransport(service: first)
    }

    deinit {
        IOObjectRelease(service)
    }

    public func open() async throws {
        guard interface == nil else { return }
        do {
            let iface = try IOUSBHostInterface(
                __ioService: service, options: [], queue: nil, interestHandler: nil)
            try iface.selectAlternateSetting(0)
            self.outPipe = try iface.copyPipe(withAddress: Self.endpointOut)
            self.inPipe = try iface.copyPipe(withAddress: Self.endpointIn)
            self.interface = iface
        } catch {
            throw JensenError.interfaceUnavailable(String(describing: error))
        }
    }

    public func close() async {
        outPipe = nil
        inPipe = nil
        interface?.destroy()
        interface = nil
    }

    public func write(_ data: Data) async throws {
        guard let pipe = outPipe else { throw JensenError.notConnected }
        let buffer = NSMutableData(data: data)
        try await Self.transfer(pipe: pipe, buffer: buffer, timeout: 5.0)
    }

    public func read(maxLength: Int, timeout: Duration) async throws -> Data {
        guard let pipe = inPipe else { throw JensenError.notConnected }
        guard let buffer = NSMutableData(length: maxLength) else { return Data() }
        let seconds = Double(timeout.components.seconds)
            + Double(timeout.components.attoseconds) / 1e18
        let transferred = try await Self.transfer(
            pipe: pipe, buffer: buffer, timeout: max(seconds, 0.05), toleratesTimeout: true)
        guard transferred > 0 else { return Data() }
        return Data(bytes: buffer.bytes, count: transferred)
    }

    /// `__sendIORequest` blocks the calling thread, so it runs off the actor.
    @discardableResult
    private static func transfer(
        pipe: IOUSBHostPipe,
        buffer: NSMutableData,
        timeout: TimeInterval,
        toleratesTimeout: Bool = false
    ) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var transferred = 0
                do {
                    try pipe.__sendIORequest(
                        with: buffer, bytesTransferred: &transferred, completionTimeout: timeout)
                    continuation.resume(returning: transferred)
                } catch {
                    // A read that simply had nothing waiting is not an error.
                    if toleratesTimeout {
                        continuation.resume(returning: 0)
                    } else {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build`
Expected: builds with no errors

- [ ] **Step 3: Add the `info` command to the CLI**

Replace the `default:` case in `Sources/HiDockCLI/main.swift` with:

```swift
case "info":
    let transport = try IOUSBHostTransport.openFirstAvailable()
    let device = JensenDevice(transport: transport)
    try await device.open()
    defer { Task { await device.close() } }

    let body = try await device.send(.getDeviceInfo, timeout: .seconds(5))
    print("device info body (\(body.count) bytes): \(body.map { String(format: "%02x", $0) }.joined())")
    print("INFO OK")

default:
    print("usage: hidock-cli [probe|info]")
    exit(2)
```

Change the top of the file to support `await` at top level by wrapping the switch in:

```swift
@main
struct CLI {
    static func main() async throws {
        // ... the switch, unchanged ...
    }
}
```

and rename the file to `Sources/HiDockCLI/CLI.swift` (SPM treats `main.swift` and `@main` as mutually exclusive).

- [ ] **Step 4: Hardware check (manual, requires the P1 plugged in)**

Run: `swift run hidock-cli info`
Expected: `INFO OK` and a non-empty hex body of at least 20 bytes

If the command times out, increase the post-claim settle in `JensenDevice.open()` from 300 ms to 1000 ms and retry. **If it still times out, stop and report before continuing.**

- [ ] **Step 5: Commit**

```bash
git add Sources/HiDockKit/IOUSBHostTransport.swift Sources/HiDockCLI
git commit -m "feat(kit): IOUSBHost bulk transport and hidock-cli info"
```

---

### Task 5: Response parsers and listing

**Files:**
- Create: `Sources/HiDockKit/Models.swift`
- Create: `Sources/HiDockKit/ResponseParsers.swift`
- Modify: `Sources/HiDockKit/JensenDevice.swift` (add typed command methods)
- Modify: `Sources/HiDockCLI/CLI.swift` (add `list`)
- Test: `Tests/HiDockKitTests/ResponseParserTests.swift`

**Interfaces:**
- Consumes: `JensenDevice.send`, `JensenError`
- Produces: `struct DeviceInfo { versionCode: String, versionNumber: UInt32, serialNumber: String }`, `struct FileInfo { name: String, lengthBytes: Int, signature: String, version: UInt8, recordedAt: Date? }`, `struct CardInfo { freeMiB: Int, capacityMiB: Int, status: Int }`, `ResponseParsers.deviceInfo(_:) throws -> DeviceInfo`, `ResponseParsers.fileList(_:) throws -> (files: [FileInfo], headerTotal: Int)`, `ResponseParsers.cardInfo(_:) throws -> CardInfo`, `ResponseParsers.recordedAt(fromFilename:) -> Date?`, `JensenDevice.deviceInfo()`, `JensenDevice.listFiles()`, `JensenDevice.fileCount()`, `JensenDevice.cardInfo()`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/HiDockKitTests/ResponseParserTests.swift
import Foundation
import Testing
@testable import HiDockKit

private func fileListEntry(
    version: UInt8, name: String, length: UInt32, signature: [UInt8]
) -> Data {
    var d = Data()
    d.append(version)
    let nameBytes = Array(name.utf8)
    d.append(UInt8(truncatingIfNeeded: nameBytes.count >> 16))
    d.append(UInt8(truncatingIfNeeded: nameBytes.count >> 8))
    d.append(UInt8(truncatingIfNeeded: nameBytes.count))
    d.append(contentsOf: nameBytes)
    d.append(UInt8(truncatingIfNeeded: length >> 24))
    d.append(UInt8(truncatingIfNeeded: length >> 16))
    d.append(UInt8(truncatingIfNeeded: length >> 8))
    d.append(UInt8(truncatingIfNeeded: length))
    d.append(contentsOf: [UInt8](repeating: 0, count: 6))   // padding
    d.append(contentsOf: signature)
    return d
}

@Test func parsesDeviceInfo() throws {
    var body = Data([0x00, 0x01, 0x04, 0x03])               // version
    body.append(contentsOf: Array("SN12345".utf8))
    body.append(contentsOf: [UInt8](repeating: 0, count: 16 - 7))
    let info = try ResponseParsers.deviceInfo(body)
    #expect(info.versionCode == "1.4.3")
    #expect(info.versionNumber == 0x00010403)
    #expect(info.serialNumber == "SN12345")
}

@Test func deviceInfoThrowsOnShortBody() {
    #expect(throws: (any Error).self) { _ = try ResponseParsers.deviceInfo(Data([1, 2])) }
}

@Test func parsesSingleFileListEntry() throws {
    let sig = (0..<16).map { UInt8($0) }
    let body = fileListEntry(version: 1, name: "2026Aug04-143022-Rec1.mp3",
                             length: 1_234_567, signature: sig)
    let result = try ResponseParsers.fileList(body)
    #expect(result.files.count == 1)
    #expect(result.files[0].name == "2026Aug04-143022-Rec1.mp3")
    #expect(result.files[0].lengthBytes == 1_234_567)
    #expect(result.files[0].signature == "000102030405060708090a0b0c0d0e0f")
    #expect(result.files[0].version == 1)
}

@Test func parsesFileListWithCountHeader() throws {
    var body = Data([0xFF, 0xFF, 0x00, 0x00, 0x00, 0x02])
    body.append(fileListEntry(version: 1, name: "a.mp3", length: 10,
                              signature: [UInt8](repeating: 0xAA, count: 16)))
    body.append(fileListEntry(version: 1, name: "b.wav", length: 20,
                              signature: [UInt8](repeating: 0xBB, count: 16)))
    let result = try ResponseParsers.fileList(body)
    #expect(result.headerTotal == 2)
    #expect(result.files.map(\.name) == ["a.mp3", "b.wav"])
}

@Test func fileListStopsCleanlyOnTruncatedTrailingEntry() throws {
    var body = fileListEntry(version: 1, name: "a.mp3", length: 10,
                             signature: [UInt8](repeating: 0xAA, count: 16))
    body.append(contentsOf: [0x01, 0x00, 0x00])             // start of an entry, then nothing
    let result = try ResponseParsers.fileList(body)
    #expect(result.files.count == 1)
}

@Test func fileListSkipsEmbeddedNulBytesInNames() throws {
    var name = Array("a.mp3".utf8)
    name.append(0)
    var d = Data([1])
    d.append(contentsOf: [0, 0, UInt8(name.count)])
    d.append(contentsOf: name)
    d.append(contentsOf: [0, 0, 0, 10])
    d.append(contentsOf: [UInt8](repeating: 0, count: 6))
    d.append(contentsOf: [UInt8](repeating: 0xCC, count: 16))
    let result = try ResponseParsers.fileList(d)
    #expect(result.files[0].name == "a.mp3")
}

@Test func parsesCardInfo() throws {
    let body = Data([0, 0, 0x30, 0x00,  0, 0, 0x78, 0x00,  0, 0, 0, 1])
    let info = try ResponseParsers.cardInfo(body)
    #expect(info.freeMiB == 0x3000)
    #expect(info.capacityMiB == 0x7800)
    #expect(info.status == 1)
}

@Test func parsesMonthNameFilenameTimestamp() throws {
    let date = try #require(ResponseParsers.recordedAt(fromFilename: "2026Aug04-143022-Rec59.hda"))
    let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    #expect(c.year == 2026 && c.month == 8 && c.day == 4)
    #expect(c.hour == 14 && c.minute == 30 && c.second == 22)
}

@Test func parsesNumericFilenameTimestamp() throws {
    let date = try #require(ResponseParsers.recordedAt(fromFilename: "20260804143022REC001.wav"))
    let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    #expect(c.year == 2026 && c.month == 8 && c.day == 4)
    #expect(c.hour == 14 && c.minute == 30 && c.second == 22)
}

@Test func returnsNilForUnparseableFilename() {
    #expect(ResponseParsers.recordedAt(fromFilename: "whatever.mp3") == nil)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ResponseParserTests`
Expected: FAIL, `cannot find 'ResponseParsers' in scope`

- [ ] **Step 3: Write `Models.swift`**

```swift
import Foundation

public struct DeviceInfo: Sendable, Equatable {
    public let versionCode: String
    public let versionNumber: UInt32
    public let serialNumber: String
}

public struct FileInfo: Sendable, Equatable {
    public let name: String
    public let lengthBytes: Int
    public let signature: String
    public let version: UInt8
    /// Parsed from the filename. Nil when the device uses an unrecognised naming scheme.
    public let recordedAt: Date?
}

public struct CardInfo: Sendable, Equatable {
    public let freeMiB: Int
    public let capacityMiB: Int
    public let status: Int

    public var usedMiB: Int { max(0, capacityMiB - freeMiB) }
}
```

- [ ] **Step 4: Write `ResponseParsers.swift`**

```swift
import Foundation

public enum ResponseParsers {

    public static func deviceInfo(_ body: Data) throws -> DeviceInfo {
        guard body.count >= 20 else {
            throw JensenError.shortBody(command: 1, expected: 20, got: body.count)
        }
        let b = [UInt8](body)
        let versionNumber = UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
        let versionCode = "\(b[1]).\(b[2]).\(b[3])"
        let serial = String(decoding: b[4..<20].filter { $0 > 0 }, as: UTF8.self)
        return DeviceInfo(versionCode: versionCode, versionNumber: versionNumber, serialNumber: serial)
    }

    public static func cardInfo(_ body: Data) throws -> CardInfo {
        guard body.count >= 12 else {
            throw JensenError.shortBody(command: 16, expected: 12, got: body.count)
        }
        let b = [UInt8](body)
        func u32(_ i: Int) -> Int {
            Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
        }
        return CardInfo(freeMiB: u32(0), capacityMiB: u32(4), status: u32(8))
    }

    public static func fileList(_ body: Data) throws -> (files: [FileInfo], headerTotal: Int) {
        let b = [UInt8](body)
        var pos = 0
        var headerTotal = 0
        var files: [FileInfo] = []

        if b.count >= 6, b[0] == 0xFF, b[1] == 0xFF {
            headerTotal = Int(b[2]) << 24 | Int(b[3]) << 16 | Int(b[4]) << 8 | Int(b[5])
            pos = 6
        }

        while pos < b.count {
            let start = pos
            guard pos + 4 <= b.count else { break }
            let version = b[pos]; pos += 1

            let nameLength = Int(b[pos]) << 16 | Int(b[pos + 1]) << 8 | Int(b[pos + 2])
            pos += 3

            guard pos + nameLength <= b.count else { pos = start; break }
            let name = String(decoding: b[pos ..< pos + nameLength].filter { $0 > 0 }, as: UTF8.self)
            pos += nameLength

            guard pos + 4 <= b.count else { pos = start; break }
            let length = Int(b[pos]) << 24 | Int(b[pos + 1]) << 16 | Int(b[pos + 2]) << 8 | Int(b[pos + 3])
            pos += 4

            guard pos + 6 <= b.count else { pos = start; break }
            pos += 6                                        // padding

            guard pos + 16 <= b.count else { pos = start; break }
            let signature = b[pos ..< pos + 16].map { String(format: "%02x", $0) }.joined()
            pos += 16

            files.append(FileInfo(
                name: name,
                lengthBytes: length,
                signature: signature,
                version: version,
                recordedAt: recordedAt(fromFilename: name)))
        }

        return (files, headerTotal)
    }

    private static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                     "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// The P1 has no timezone concept, so its clock is read as local wall time.
    public static func recordedAt(fromFilename filename: String) -> Date? {
        if let d = parseMonthNameForm(filename) { return d }
        return parseNumericForm(filename)
    }

    /// e.g. 2026Aug04-143022-Rec59.hda
    private static func parseMonthNameForm(_ s: String) -> Date? {
        let pattern = /(\d{4})(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)(\d{1,2})-(\d{2})(\d{2})(\d{2})/
        guard let m = s.firstMatch(of: pattern),
              let monthIndex = monthNames.firstIndex(of: String(m.2)) else { return nil }
        return makeDate(year: Int(m.1), month: monthIndex + 1, day: Int(m.3),
                        hour: Int(m.4), minute: Int(m.5), second: Int(m.6))
    }

    /// e.g. 20260804143022REC001.wav
    private static func parseNumericForm(_ s: String) -> Date? {
        let pattern = /(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})/
        guard let m = s.firstMatch(of: pattern) else { return nil }
        return makeDate(year: Int(m.1), month: Int(m.2), day: Int(m.3),
                        hour: Int(m.4), minute: Int(m.5), second: Int(m.6))
    }

    private static func makeDate(year: Int?, month: Int?, day: Int?,
                                 hour: Int?, minute: Int?, second: Int?) -> Date? {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day
        c.hour = hour; c.minute = minute; c.second = second
        return Calendar.current.date(from: c)
    }
}
```

- [ ] **Step 5: Add typed command methods to `JensenDevice.swift`**

Append inside the actor:

```swift
    public func deviceInfo(timeout: Duration = .seconds(5)) async throws -> DeviceInfo {
        try ResponseParsers.deviceInfo(await send(.getDeviceInfo, timeout: timeout))
    }

    public func cardInfo(timeout: Duration = .seconds(5)) async throws -> CardInfo {
        try ResponseParsers.cardInfo(await send(.getCardInfo, timeout: timeout))
    }

    public func fileCount(timeout: Duration = .seconds(5)) async throws -> Int {
        let body = try await send(.getFileCount, timeout: timeout)
        guard body.count >= 4 else {
            throw JensenError.shortBody(command: 6, expected: 4, got: body.count)
        }
        let b = [UInt8](body)
        return Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
    }

    public func listFiles(timeout: Duration = .seconds(20)) async throws -> [FileInfo] {
        try ResponseParsers.fileList(await send(.getFileList, timeout: timeout)).files
    }
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter ResponseParserTests`
Expected: PASS, 11 tests

- [ ] **Step 7: Add the `list` command to the CLI**

Insert before `default:` in `Sources/HiDockCLI/CLI.swift`:

```swift
case "list":
    let transport = try IOUSBHostTransport.openFirstAvailable()
    let device = JensenDevice(transport: transport)
    try await device.open()
    defer { Task { await device.close() } }

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
```

Update the usage string to `[probe|info|list]`.

- [ ] **Step 8: Hardware check (manual, requires the P1 plugged in)**

Run: `swift run hidock-cli list`
Expected: `LIST OK`, firmware version matching the device, and one line per recording.

Record the observed file extensions. **If any file ends in `.hda`, stop and report** — the spec's fallback applies and a WAV-header wrapper must be added to this task.

**Also record the `device time body` hex line verbatim in the task report.** Its layout is unverified, and Task 10 deliberately never writes the clock until it is confirmed against these real bytes.

- [ ] **Step 9: Commit**

```bash
git add Sources/HiDockKit/Models.swift Sources/HiDockKit/ResponseParsers.swift Sources/HiDockKit/JensenDevice.swift Sources/HiDockCLI Tests/HiDockKitTests/ResponseParserTests.swift
git commit -m "feat(kit): response parsers, typed commands, hidock-cli list"
```

---

### Task 6: Streaming file transfer

A 30-minute WAV at 768 kbps is roughly 170 MB. This must stream to disk.

**Files:**
- Modify: `Sources/HiDockKit/JensenDevice.swift`
- Modify: `Sources/HiDockCLI/CLI.swift` (add `pull`)
- Test: `Tests/HiDockKitTests/TransferTests.swift`

**Interfaces:**
- Consumes: `JensenDevice.sendRaw`, `FileInfo`, `JensenError`
- Produces: `JensenDevice.transferFile(_ file: FileInfo, to url: URL, progress: @Sendable (Int, Int) -> Void) async throws`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/HiDockKitTests/TransferTests.swift
import Foundation
import Testing
@testable import HiDockKit

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
}

private func makeFile(length: Int) -> FileInfo {
    FileInfo(name: "20260804143022REC001.mp3", lengthBytes: length,
             signature: "abc123", version: 1, recordedAt: nil)
}

@Test func transferWritesAllBytesToDisk() async throws {
    let payload = Data((0..<5000).map { UInt8($0 % 251) })
    let chunks = stride(from: 0, to: payload.count, by: 1000).map {
        payload.subdata(in: $0 ..< min($0 + 1000, payload.count))
    }
    let t = FakeTransport(script: .init(responses: [5: chunks]))
    let device = JensenDevice(transport: t)
    try await device.open()

    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    try await device.transferFile(makeFile(length: payload.count), to: url) { _, _ in }

    #expect(try Data(contentsOf: url) == payload)
}

@Test func transferReportsProgress() async throws {
    let chunks = (0..<4).map { _ in Data(repeating: 1, count: 250) }
    let t = FakeTransport(script: .init(responses: [5: chunks]))
    let device = JensenDevice(transport: t)
    try await device.open()

    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url) }

    final class Box: @unchecked Sendable { var seen: [Int] = [] }
    let box = Box()
    try await device.transferFile(makeFile(length: 1000), to: url) { done, _ in
        box.seen.append(done)
    }
    #expect(box.seen.last == 1000)
    #expect(box.seen.count >= 2)
}

@Test func transferThrowsAndRemovesPartialOnShortStream() async throws {
    let t = FakeTransport(script: .init(responses: [5: [Data(repeating: 1, count: 100)]]))
    let device = JensenDevice(transport: t)
    try await device.open()

    let url = tempURL()
    await #expect(throws: JensenError.transferIncomplete(expected: 1000, got: 100)) {
        try await device.transferFile(makeFile(length: 1000), to: url) { _, _ in }
    }
    #expect(FileManager.default.fileExists(atPath: url.path) == false)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TransferTests`
Expected: FAIL, `value of type 'JensenDevice' has no member 'transferFile'`

- [ ] **Step 3: Implement `transferFile` in `JensenDevice.swift`**

Append inside the actor:

```swift
    /// Streams a recording to `url`. Never buffers the whole file in memory.
    /// Throws `transferIncomplete` and deletes the partial file if the byte
    /// count does not match what the device reported.
    public func transferFile(
        _ file: FileInfo,
        to url: URL,
        chunkTimeout: Duration = .seconds(30),
        progress: @Sendable (Int, Int) -> Void
    ) async throws {
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        fm.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else {
            throw JensenError.interfaceUnavailable("cannot open \(url.path) for writing")
        }

        var received = 0
        var failure: (any Error)?

        do {
            let seq = sequence
            sequence &+= 1
            let body = Data(file.name.utf8)
            try await transport.write(
                JensenPacket(command: JensenCommand.transferFile.rawValue,
                             sequence: seq, body: body).encoded())

            // Resets on every received chunk. A single deadline for the whole
            // transfer would cap a 170 MB WAV at chunkTimeout regardless of
            // link speed; this bounds the gap *between* chunks instead.
            var deadline = ContinuousClock.now.advanced(by: chunkTimeout)
            while received < file.lengthBytes {
                if let chunk = try takeBufferedPacket(
                    matching: JensenCommand.transferFile.rawValue), !chunk.isEmpty {
                    let slice = chunk.prefix(file.lengthBytes - received)
                    try handle.write(contentsOf: slice)
                    received += slice.count
                    progress(received, file.lengthBytes)
                    deadline = ContinuousClock.now.advanced(by: chunkTimeout)
                    continue
                }

                guard ContinuousClock.now < deadline else { break }
                let raw = try await transport.read(maxLength: 64 * 1024, timeout: chunkTimeout)
                if raw.isEmpty {
                    try await Task.sleep(for: .milliseconds(5))
                } else {
                    buffer.append(raw)
                }
            }
        } catch {
            failure = error
        }

        try? handle.close()

        if let failure {
            try? fm.removeItem(at: url)
            throw failure
        }
        guard received == file.lengthBytes else {
            try? fm.removeItem(at: url)
            throw JensenError.transferIncomplete(expected: file.lengthBytes, got: received)
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TransferTests`
Expected: PASS, 3 tests

- [ ] **Step 5: Add the `pull` command to the CLI**

Insert before `default:`:

```swift
case "pull":
    guard args.count >= 2 else { print("usage: hidock-cli pull <device-filename>"); exit(2) }
    let target = args[1]

    let transport = try IOUSBHostTransport.openFirstAvailable()
    let device = JensenDevice(transport: transport)
    try await device.open()
    defer { Task { await device.close() } }

    let files = try await device.listFiles()
    guard let file = files.first(where: { $0.name == target }) else {
        print("not found on device: \(target)"); exit(1)
    }

    let out = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(file.name)
    try await device.transferFile(file, to: out) { done, total in
        let pct = total > 0 ? done * 100 / total : 0
        FileHandle.standardError.write(Data("\r\(pct)% (\(done)/\(total))".utf8))
    }
    print("\nwrote \(out.path)")
    print("PULL OK")
```

Update the usage string to `[probe|info|list|pull <name>]`.

- [ ] **Step 6: Hardware check (manual, requires the P1 plugged in)**

Run:
```bash
swift run hidock-cli list                       # copy a filename
swift run hidock-cli pull <that-filename>
afplay <that-filename>                          # must be audible
```
Expected: `PULL OK`, and the file plays. Confirm the on-disk byte size matches the size `list` reported.

- [ ] **Step 7: Commit**

```bash
git add Sources/HiDockKit/JensenDevice.swift Sources/HiDockCLI Tests/HiDockKitTests/TransferTests.swift
git commit -m "feat(kit): streaming file transfer with verification and hidock-cli pull"
```

---

### Task 7: Library and index

**Files:**
- Modify: `Package.swift` (add the app target and its test target)
- Create: `Sources/HiDockMenubar/Sidecar.swift`
- Create: `Sources/HiDockMenubar/Library.swift`
- Create: `Sources/HiDockMenubar/LibraryIndex.swift`
- Test: `Tests/HiDockMenubarTests/LibraryTests.swift`
- Test: `Tests/HiDockMenubarTests/LibraryIndexTests.swift`

**Interfaces:**
- Consumes: `FileInfo` (HiDockKit)
- Produces: `struct Sidecar: Codable, Sendable`, `struct Library { init(root: URL); func destinationURL(for: FileInfo) -> URL; func incomingURL(for: FileInfo) -> URL; func commit(incoming: URL, file: FileInfo, deviceSerial: String) throws -> Sidecar; func scanSidecars() throws -> [Sidecar]; func hasFreeSpace(forBytes: Int) -> Bool; func isReachable() -> Bool }`, `final class LibraryIndex { init(url: URL) throws; func upsert(_: Sidecar) throws; func contains(signature: String) -> Bool; func recent(limit: Int) throws -> [Sidecar]; func all() throws -> [Sidecar]; func rebuild(from: [Sidecar]) throws }`

- [ ] **Step 1: Extend `Package.swift`**

Add to `targets:`:

```swift
        .executableTarget(
            name: "HiDockMenubar",
            dependencies: ["HiDockKit"],
            resources: [.copy("Info.plist")],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(name: "HiDockMenubarTests", dependencies: ["HiDockMenubar", "HiDockKit"]),
```

Add to `products:`:

```swift
        .executable(name: "HiDockMenubar", targets: ["HiDockMenubar"]),
```

- [ ] **Step 2: Write the failing tests**

```swift
// Tests/HiDockMenubarTests/LibraryTests.swift
import Foundation
import Testing
import HiDockKit
@testable import HiDockMenubar

private func tempRoot() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

private func sampleFile(name: String = "20260804143022REC001.mp3", length: Int = 4) -> FileInfo {
    FileInfo(name: name, lengthBytes: length, signature: "sig-\(name)",
             version: 1, recordedAt: ResponseParsers.recordedAt(fromFilename: name))
}

@Test func destinationIsDateFolderedWithDeviceExtension() {
    let lib = Library(root: URL(fileURLWithPath: "/tmp/x"))
    let url = lib.destinationURL(for: sampleFile())
    #expect(url.deletingLastPathComponent().lastPathComponent == "2026-08-04")
    #expect(url.lastPathComponent == "143022.mp3")
}

@Test func commitMovesFileAndWritesSidecar() throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let lib = Library(root: root)
    let file = sampleFile()

    let incoming = lib.incomingURL(for: file)
    try FileManager.default.createDirectory(
        at: incoming.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data([1, 2, 3, 4]).write(to: incoming)

    let sidecar = try lib.commit(incoming: incoming, file: file, deviceSerial: "SN1")

    let audio = lib.destinationURL(for: file)
    #expect(FileManager.default.fileExists(atPath: audio.path))
    #expect(FileManager.default.fileExists(atPath: incoming.path) == false)

    let json = audio.deletingPathExtension().appendingPathExtension("json")
    #expect(FileManager.default.fileExists(atPath: json.path))
    #expect(sidecar.signature == file.signature)
    #expect(sidecar.lengthBytes == 4)
    #expect(sidecar.deviceSerial == "SN1")
}

@Test func scanSidecarsFindsEveryCommittedRecording() throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let lib = Library(root: root)

    for name in ["20260804143022REC001.mp3", "20260805090000REC002.wav"] {
        let f = sampleFile(name: name)
        let incoming = lib.incomingURL(for: f)
        try FileManager.default.createDirectory(
            at: incoming.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3, 4]).write(to: incoming)
        _ = try lib.commit(incoming: incoming, file: f, deviceSerial: "SN1")
    }

    #expect(try lib.scanSidecars().count == 2)
}

@Test func reachabilityIsFalseForMissingRoot() {
    let lib = Library(root: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
    #expect(lib.isReachable() == false)
}
```

```swift
// Tests/HiDockMenubarTests/LibraryIndexTests.swift
import Foundation
import Testing
@testable import HiDockMenubar

private func tempDB() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
}

private func sidecar(_ sig: String, recordedAt: Date = Date(timeIntervalSince1970: 0)) -> Sidecar {
    Sidecar(signature: sig, deviceFilename: "\(sig).mp3", relativePath: "2026-08-04/\(sig).mp3",
            lengthBytes: 100, durationSeconds: 12.5, recordedAt: recordedAt,
            syncedAt: Date(timeIntervalSince1970: 10), deviceSerial: "SN1",
            deviceModel: "hidock-p1", timeZoneIdentifier: "Asia/Manila")
}

@Test func upsertThenContains() throws {
    let url = tempDB(); defer { try? FileManager.default.removeItem(at: url) }
    let index = try LibraryIndex(url: url)
    #expect(index.contains(signature: "a") == false)
    try index.upsert(sidecar("a"))
    #expect(index.contains(signature: "a"))
}

@Test func upsertIsIdempotent() throws {
    let url = tempDB(); defer { try? FileManager.default.removeItem(at: url) }
    let index = try LibraryIndex(url: url)
    try index.upsert(sidecar("a"))
    try index.upsert(sidecar("a"))
    #expect(try index.all().count == 1)
}

@Test func recentIsNewestFirstAndLimited() throws {
    let url = tempDB(); defer { try? FileManager.default.removeItem(at: url) }
    let index = try LibraryIndex(url: url)
    try index.upsert(sidecar("old", recordedAt: Date(timeIntervalSince1970: 100)))
    try index.upsert(sidecar("new", recordedAt: Date(timeIntervalSince1970: 900)))
    try index.upsert(sidecar("mid", recordedAt: Date(timeIntervalSince1970: 500)))

    #expect(try index.recent(limit: 2).map(\.signature) == ["new", "mid"])
}

@Test func rebuildReplacesEverything() throws {
    let url = tempDB(); defer { try? FileManager.default.removeItem(at: url) }
    let index = try LibraryIndex(url: url)
    try index.upsert(sidecar("stale"))
    try index.rebuild(from: [sidecar("x"), sidecar("y")])
    #expect(Set(try index.all().map(\.signature)) == ["x", "y"])
}

@Test func roundTripsAllSidecarFields() throws {
    let url = tempDB(); defer { try? FileManager.default.removeItem(at: url) }
    let index = try LibraryIndex(url: url)
    let s = sidecar("a")
    try index.upsert(s)
    let back = try #require(try index.all().first)
    #expect(back == s)
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter LibraryTests`
Expected: FAIL, `cannot find 'Library' in scope`

- [ ] **Step 4: Write `Sidecar.swift`**

```swift
import Foundation

/// The full record for one synced recording. Written next to the audio file.
/// Because sidecars hold everything, the SQLite index is disposable.
public struct Sidecar: Codable, Sendable, Equatable {
    public var signature: String
    public var deviceFilename: String
    /// Relative to the library root, so the library survives being moved.
    public var relativePath: String
    public var lengthBytes: Int
    public var durationSeconds: Double?
    public var recordedAt: Date?
    public var syncedAt: Date
    public var deviceSerial: String
    public var deviceModel: String
    /// The zone the device clock was interpreted in. The P1 has no timezone
    /// concept, so this records the assumption for later correction.
    public var timeZoneIdentifier: String
}
```

- [ ] **Step 5: Write `Library.swift`**

```swift
import AVFoundation
import Foundation
import HiDockKit

public struct Library: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    private static let incomingFolder = ".incoming"

    public func isReachable() -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir)
            && isDir.boolValue
    }

    public func hasFreeSpace(forBytes bytes: Int) -> Bool {
        guard let values = try? root.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage else {
            return true                                  // unknown, let the write decide
        }
        return available > Int64(bytes) + 50_000_000     // keep 50 MB headroom
    }

    public func incomingURL(for file: FileInfo) -> URL {
        root.appendingPathComponent(Self.incomingFolder)
            .appendingPathComponent("\(file.signature).part")
    }

    /// `<root>/YYYY-MM-DD/HHMMSS.<device extension>`
    public func destinationURL(for file: FileInfo) -> URL {
        let ext = (file.name as NSString).pathExtension
        let date = file.recordedAt ?? Date()
        let folder = Self.dayFormatter.string(from: date)
        let stem = Self.timeFormatter.string(from: date)
        return root.appendingPathComponent(folder)
            .appendingPathComponent(ext.isEmpty ? stem : "\(stem).\(ext)")
    }

    public func sidecarURL(for file: FileInfo) -> URL {
        destinationURL(for: file).deletingPathExtension().appendingPathExtension("json")
    }

    /// Moves a verified download into place and writes its sidecar.
    /// Duration is measured from the audio header, not inferred from bitrate.
    @discardableResult
    public func commit(incoming: URL, file: FileInfo, deviceSerial: String) throws -> Sidecar {
        let destination = destinationURL(for: file)
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: incoming, to: destination)

        let sidecar = Sidecar(
            signature: file.signature,
            deviceFilename: file.name,
            relativePath: destination.path.replacingOccurrences(
                of: root.path.hasSuffix("/") ? root.path : root.path + "/", with: ""),
            lengthBytes: file.lengthBytes,
            durationSeconds: Self.measureDuration(of: destination),
            recordedAt: file.recordedAt,
            syncedAt: Date(),
            deviceSerial: deviceSerial,
            deviceModel: "hidock-p1",
            timeZoneIdentifier: TimeZone.current.identifier)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(sidecar).write(to: sidecarURL(for: file))
        return sidecar
    }

    public func scanSidecars() throws -> [Sidecar] {
        guard isReachable() else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var results: [Sidecar] = []
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants])

        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "json" else { continue }
            guard let data = try? Data(contentsOf: url),
                  let sidecar = try? decoder.decode(Sidecar.self, from: data) else { continue }
            results.append(sidecar)
        }
        return results
    }

    private static func measureDuration(of url: URL) -> Double? {
        let asset = AVURLAsset(url: url)
        let seconds = CMTimeGetSeconds(asset.duration)
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HHmmss"
        return f
    }()
}
```

- [ ] **Step 6: Write `LibraryIndex.swift`**

```swift
import Foundation
import SQLite3

/// Derived cache over the sidecars. Safe to delete; `rebuild(from:)` restores it.
public final class LibraryIndex: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()

    private static let schemaVersion = 1
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            throw LibraryIndexError.cannotOpen(url.path)
        }
        try execute("PRAGMA journal_mode=WAL;")
        try migrate()
    }

    deinit { sqlite3_close(db) }

    private func migrate() throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS recordings (
                signature TEXT PRIMARY KEY,
                device_filename TEXT NOT NULL,
                relative_path TEXT NOT NULL,
                length_bytes INTEGER NOT NULL,
                duration_seconds REAL,
                recorded_at REAL,
                synced_at REAL NOT NULL,
                device_serial TEXT NOT NULL,
                device_model TEXT NOT NULL,
                timezone TEXT NOT NULL
            );
            """)
        try execute("CREATE INDEX IF NOT EXISTS idx_recorded_at ON recordings(recorded_at DESC);")
        try execute("PRAGMA user_version = \(Self.schemaVersion);")
    }

    public func contains(signature: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, "SELECT 1 FROM recordings WHERE signature = ? LIMIT 1;", -1, &stmt, nil) == SQLITE_OK
        else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, signature, -1, Self.transient)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    public func upsert(_ s: Sidecar) throws {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        let sql = """
            INSERT INTO recordings
              (signature, device_filename, relative_path, length_bytes, duration_seconds,
               recorded_at, synced_at, device_serial, device_model, timezone)
            VALUES (?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(signature) DO UPDATE SET
              device_filename=excluded.device_filename,
              relative_path=excluded.relative_path,
              length_bytes=excluded.length_bytes,
              duration_seconds=excluded.duration_seconds,
              recorded_at=excluded.recorded_at,
              synced_at=excluded.synced_at,
              device_serial=excluded.device_serial,
              device_model=excluded.device_model,
              timezone=excluded.timezone;
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw LibraryIndexError.prepareFailed(lastMessage())
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, s.signature, -1, Self.transient)
        sqlite3_bind_text(stmt, 2, s.deviceFilename, -1, Self.transient)
        sqlite3_bind_text(stmt, 3, s.relativePath, -1, Self.transient)
        sqlite3_bind_int64(stmt, 4, Int64(s.lengthBytes))
        if let d = s.durationSeconds { sqlite3_bind_double(stmt, 5, d) } else { sqlite3_bind_null(stmt, 5) }
        if let r = s.recordedAt { sqlite3_bind_double(stmt, 6, r.timeIntervalSince1970) } else { sqlite3_bind_null(stmt, 6) }
        sqlite3_bind_double(stmt, 7, s.syncedAt.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 8, s.deviceSerial, -1, Self.transient)
        sqlite3_bind_text(stmt, 9, s.deviceModel, -1, Self.transient)
        sqlite3_bind_text(stmt, 10, s.timeZoneIdentifier, -1, Self.transient)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw LibraryIndexError.writeFailed(lastMessage())
        }
    }

    public func recent(limit: Int) throws -> [Sidecar] {
        try query("SELECT * FROM recordings ORDER BY recorded_at DESC LIMIT \(limit);")
    }

    public func all() throws -> [Sidecar] {
        try query("SELECT * FROM recordings ORDER BY recorded_at DESC;")
    }

    public func rebuild(from sidecars: [Sidecar]) throws {
        lock.lock()
        let result = sqlite3_exec(db, "DELETE FROM recordings;", nil, nil, nil)
        lock.unlock()
        guard result == SQLITE_OK else { throw LibraryIndexError.writeFailed(lastMessage()) }
        for s in sidecars { try upsert(s) }
    }

    private func query(_ sql: String) throws -> [Sidecar] {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw LibraryIndexError.prepareFailed(lastMessage())
        }
        defer { sqlite3_finalize(stmt) }

        var out: [Sidecar] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            func text(_ i: Int32) -> String {
                guard let c = sqlite3_column_text(stmt, i) else { return "" }
                return String(cString: c)
            }
            func optionalDouble(_ i: Int32) -> Double? {
                sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, i)
            }
            out.append(Sidecar(
                signature: text(0),
                deviceFilename: text(1),
                relativePath: text(2),
                lengthBytes: Int(sqlite3_column_int64(stmt, 3)),
                durationSeconds: optionalDouble(4),
                recordedAt: optionalDouble(5).map(Date.init(timeIntervalSince1970:)),
                syncedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6)),
                deviceSerial: text(7),
                deviceModel: text(8),
                timeZoneIdentifier: text(9)))
        }
        return out
    }

    private func execute(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw LibraryIndexError.writeFailed(lastMessage())
        }
    }

    private func lastMessage() -> String {
        guard let c = sqlite3_errmsg(db) else { return "unknown sqlite error" }
        return String(cString: c)
    }
}

public enum LibraryIndexError: Error {
    case cannotOpen(String)
    case prepareFailed(String)
    case writeFailed(String)
}
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `swift test --filter LibraryTests && swift test --filter LibraryIndexTests`
Expected: PASS, 4 + 5 tests

- [ ] **Step 8: Commit**

```bash
git add Package.swift Sources/HiDockMenubar Tests/HiDockMenubarTests
git commit -m "feat(app): file-backed library with rebuildable SQLite index"
```

---

### Task 8: Sync engine

**Files:**
- Create: `Sources/HiDockMenubar/SyncEngine.swift`
- Test: `Tests/HiDockMenubarTests/FakeDevice.swift`
- Test: `Tests/HiDockMenubarTests/SyncEngineTests.swift`

**Interfaces:**
- Consumes: `Library`, `LibraryIndex`, `FileInfo`, `JensenError`
- Produces: `protocol SyncDevice: Sendable`, `actor SyncEngine`, `SyncEngine.init(library:index:)`, `SyncEngine.sync(device:serial:progress:) async throws -> SyncResult`, `struct SyncResult { downloaded: [Sidecar], skipped: Int, failed: [(String, any Error)] }`, `enum SyncProgress: Sendable`

- [ ] **Step 1: Write the fake device and failing tests**

```swift
// Tests/HiDockMenubarTests/FakeDevice.swift
import Foundation
import HiDockKit
@testable import HiDockMenubar

actor FakeDevice: SyncDevice {
    var files: [FileInfo]
    var payloads: [String: Data]
    var failTransfersFor: Set<String>
    private(set) var deletedNames: [String] = []

    init(files: [FileInfo], payloads: [String: Data], failTransfersFor: Set<String> = []) {
        self.files = files
        self.payloads = payloads
        self.failTransfersFor = failTransfersFor
    }

    func listFiles() async throws -> [FileInfo] { files }

    func transferFile(_ file: FileInfo, to url: URL, chunkTimeout: Duration,
                      progress: @Sendable (Int, Int) -> Void) async throws {
        if failTransfersFor.contains(file.name) {
            throw JensenError.transferIncomplete(expected: file.lengthBytes, got: 0)
        }
        let data = payloads[file.name] ?? Data()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        progress(data.count, file.lengthBytes)
    }

    func deleteFile(named name: String) async throws { deletedNames.append(name) }
}
```

```swift
// Tests/HiDockMenubarTests/SyncEngineTests.swift
import Foundation
import Testing
import HiDockKit
@testable import HiDockMenubar

private func tempRoot() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

private func makeEngine(root: URL) throws -> (SyncEngine, Library, LibraryIndex) {
    let library = Library(root: root)
    let index = try LibraryIndex(url: root.appendingPathComponent("index.sqlite"))
    return (SyncEngine(library: library, index: index), library, index)
}

private func file(_ name: String, _ bytes: Int, sig: String) -> FileInfo {
    FileInfo(name: name, lengthBytes: bytes, signature: sig, version: 1,
             recordedAt: ResponseParsers.recordedAt(fromFilename: name))
}

@Test func freshSyncDownloadsEverything() async throws {
    let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let (engine, library, _) = try makeEngine(root: root)

    let a = file("20260804143022REC001.mp3", 4, sig: "sa")
    let b = file("20260804150000REC002.mp3", 3, sig: "sb")
    let device = FakeDevice(files: [a, b],
                            payloads: [a.name: Data([1, 2, 3, 4]), b.name: Data([5, 6, 7])])

    let result = try await engine.sync(device: device, serial: "SN1") { _ in }
    #expect(result.downloaded.count == 2)
    #expect(result.failed.isEmpty)
    #expect(FileManager.default.fileExists(atPath: library.destinationURL(for: a).path))
}

@Test func resyncIsANoOp() async throws {
    let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let (engine, _, _) = try makeEngine(root: root)

    let a = file("20260804143022REC001.mp3", 4, sig: "sa")
    let device = FakeDevice(files: [a], payloads: [a.name: Data([1, 2, 3, 4])])

    _ = try await engine.sync(device: device, serial: "SN1") { _ in }
    let second = try await engine.sync(device: device, serial: "SN1") { _ in }

    #expect(second.downloaded.isEmpty)
    #expect(second.skipped == 1)
}

@Test func failedTransferIsReportedAndNotCommitted() async throws {
    let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let (engine, library, index) = try makeEngine(root: root)

    let a = file("20260804143022REC001.mp3", 4, sig: "sa")
    let device = FakeDevice(files: [a], payloads: [:], failTransfersFor: [a.name])

    let result = try await engine.sync(device: device, serial: "SN1") { _ in }
    #expect(result.downloaded.isEmpty)
    #expect(result.failed.count == 1)
    #expect(index.contains(signature: "sa") == false)
    #expect(FileManager.default.fileExists(atPath: library.destinationURL(for: a).path) == false)
}

@Test func oneFailureDoesNotStopTheRest() async throws {
    let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let (engine, _, _) = try makeEngine(root: root)

    let bad = file("20260804143022REC001.mp3", 4, sig: "sbad")
    let good = file("20260804150000REC002.mp3", 3, sig: "sgood")
    let device = FakeDevice(files: [bad, good],
                            payloads: [good.name: Data([5, 6, 7])],
                            failTransfersFor: [bad.name])

    let result = try await engine.sync(device: device, serial: "SN1") { _ in }
    #expect(result.downloaded.map(\.signature) == ["sgood"])
    #expect(result.failed.count == 1)
}

@Test func syncFailsFastWhenLibraryUnreachable() async throws {
    let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
    let index = try LibraryIndex(url: FileManager.default.temporaryDirectory
        .appendingPathComponent("\(UUID().uuidString).sqlite"))
    let engine = SyncEngine(library: Library(root: missing), index: index)
    let device = FakeDevice(files: [], payloads: [:])

    await #expect(throws: SyncError.libraryUnreachable) {
        _ = try await engine.sync(device: device, serial: "SN1") { _ in }
    }
}

@Test func progressReportsEachPhase() async throws {
    let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let (engine, _, _) = try makeEngine(root: root)

    let a = file("20260804143022REC001.mp3", 4, sig: "sa")
    let device = FakeDevice(files: [a], payloads: [a.name: Data([1, 2, 3, 4])])

    final class Box: @unchecked Sendable { var events: [SyncProgress] = [] }
    let box = Box()
    _ = try await engine.sync(device: device, serial: "SN1") { box.events.append($0) }

    #expect(box.events.contains { if case .listing = $0 { return true }; return false })
    #expect(box.events.contains { if case .finished = $0 { return true }; return false })
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SyncEngineTests`
Expected: FAIL, `cannot find 'SyncEngine' in scope`

- [ ] **Step 3: Write `SyncEngine.swift`**

```swift
import Foundation
import HiDockKit

/// The subset of JensenDevice the engine needs, so tests can fake it.
///
/// `chunkTimeout` is part of the requirement on purpose: Swift matches a
/// protocol witness on its full declaration name, and a default argument does
/// not synthesize the shorter form. Omitting it here makes
/// `extension JensenDevice: SyncDevice {}` fail to compile.
public protocol SyncDevice: Sendable, Actor {
    func listFiles() async throws -> [FileInfo]
    func transferFile(_ file: FileInfo, to url: URL, chunkTimeout: Duration,
                      progress: @Sendable (Int, Int) -> Void) async throws
    func deleteFile(named name: String) async throws
}

public enum SyncError: Error, Equatable {
    case libraryUnreachable
    case insufficientSpace(needed: Int)
}

public enum SyncProgress: Sendable {
    case listing
    case downloading(name: String, index: Int, of: Int, bytesDone: Int, bytesTotal: Int)
    case finished(downloaded: Int, skipped: Int, failed: Int)
}

public struct SyncResult: Sendable {
    public var downloaded: [Sidecar] = []
    public var skipped: Int = 0
    public var failed: [(name: String, error: any Error)] = []
}

public actor SyncEngine {
    private let library: Library
    private let index: LibraryIndex

    public init(library: Library, index: LibraryIndex) {
        self.library = library
        self.index = index
    }

    /// Copies every recording not already present. Never deletes from the device.
    public func sync(
        device: any SyncDevice,
        serial: String,
        progress: @Sendable (SyncProgress) -> Void
    ) async throws -> SyncResult {
        guard library.isReachable() else { throw SyncError.libraryUnreachable }

        progress(.listing)
        let files = try await device.listFiles()

        // Oldest first, so an interrupted sync still makes forward progress
        // through the backlog rather than repeatedly retrying the newest file.
        let ordered = files.sorted {
            ($0.recordedAt ?? .distantPast) < ($1.recordedAt ?? .distantPast)
        }

        var result = SyncResult()
        let pending = ordered.filter { !isAlreadySynced($0) }
        result.skipped = ordered.count - pending.count

        for (offset, file) in pending.enumerated() {
            do {
                guard library.hasFreeSpace(forBytes: file.lengthBytes) else {
                    throw SyncError.insufficientSpace(needed: file.lengthBytes)
                }

                let incoming = library.incomingURL(for: file)
                try FileManager.default.createDirectory(
                    at: incoming.deletingLastPathComponent(), withIntermediateDirectories: true)

                try await device.transferFile(
                    file, to: incoming, chunkTimeout: .seconds(30)
                ) { done, total in
                    progress(.downloading(name: file.name, index: offset + 1,
                                          of: pending.count, bytesDone: done, bytesTotal: total))
                }

                let sidecar = try library.commit(
                    incoming: incoming, file: file, deviceSerial: serial)
                try index.upsert(sidecar)
                result.downloaded.append(sidecar)
            } catch {
                try? FileManager.default.removeItem(at: library.incomingURL(for: file))
                result.failed.append((name: file.name, error: error))
            }
        }

        progress(.finished(downloaded: result.downloaded.count,
                           skipped: result.skipped,
                           failed: result.failed.count))
        return result
    }

    /// A recording counts as synced only if the index knows it *and* the bytes
    /// are still on disk at the expected length.
    private func isAlreadySynced(_ file: FileInfo) -> Bool {
        guard index.contains(signature: file.signature) else { return false }
        let url = library.destinationURL(for: file)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int else { return false }
        return size == file.lengthBytes
    }

    /// Reclaim. Only ever called from the explicit menubar action.
    /// Re-verifies on disk at call time rather than trusting the index.
    public func reclaimable(device: any SyncDevice) async throws -> [FileInfo] {
        try await device.listFiles().filter { isAlreadySynced($0) }
    }

    public func deleteFromDevice(_ files: [FileInfo], device: any SyncDevice) async throws -> Int {
        var deleted = 0
        for file in files where isAlreadySynced(file) {
            try await device.deleteFile(named: file.name)
            deleted += 1
        }
        return deleted
    }
}
```

- [ ] **Step 4: Conform `JensenDevice` to `SyncDevice`**

Add to `Sources/HiDockKit/JensenDevice.swift` inside the actor:

```swift
    public func deleteFile(named name: String) async throws {
        _ = try await send(.deleteFile, body: Data(name.utf8), timeout: .seconds(10))
    }
```

Add at the end of `Sources/HiDockMenubar/SyncEngine.swift`:

```swift
extension JensenDevice: SyncDevice {}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter SyncEngineTests`
Expected: PASS, 6 tests

- [ ] **Step 6: Run the whole suite**

Run: `swift test`
Expected: PASS, all tests, no hardware attached

- [ ] **Step 7: Commit**

```bash
git add Sources/HiDockKit/JensenDevice.swift Sources/HiDockMenubar/SyncEngine.swift Tests/HiDockMenubarTests
git commit -m "feat(app): sync engine with verify-before-commit and per-file failure isolation"
```

---

### Task 9: Device monitor

**Files:**
- Create: `Sources/HiDockMenubar/DeviceMonitor.swift`

**Interfaces:**
- Consumes: `HiDockDeviceMatching`
- Produces: `final class DeviceMonitor`, `DeviceMonitor.init(onChange: @escaping @Sendable (DeviceEvent) -> Void)`, `DeviceMonitor.start()`, `DeviceMonitor.stop()`, `enum DeviceEvent: Sendable { case attached, detached }`

- [ ] **Step 1: Write `DeviceMonitor.swift`**

Event-driven via IOKit matching notifications. No polling, so it costs nothing while idle.

```swift
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
    private func drain(_ iterator: io_iterator_t, event: DeviceEvent) {
        var sawAny = false
        while case let service = IOIteratorNext(iterator), service != 0 {
            sawAny = true
            IOObjectRelease(service)
        }
        if sawAny { onChange(event) }
    }

    public func rescan() {
        let services = HiDockDeviceMatching.copyMatchingServices()
        defer { services.forEach { IOObjectRelease($0) } }
        onChange(services.isEmpty ? .detached : .attached)
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build`
Expected: builds with no errors

- [ ] **Step 3: Commit**

```bash
git add Sources/HiDockMenubar/DeviceMonitor.swift
git commit -m "feat(app): event-driven IOKit device monitor with sleep/wake handling"
```

---

### Task 10: Menubar app

**Files:**
- Create: `Sources/HiDockMenubar/Info.plist`
- Create: `Sources/HiDockMenubar/AppModel.swift`
- Create: `Sources/HiDockMenubar/MenuBarView.swift`
- Create: `Sources/HiDockMenubar/HiDockApp.swift`
- Create: `Scripts/make-app.sh`

**Interfaces:**
- Consumes: `DeviceMonitor`, `SyncEngine`, `Library`, `LibraryIndex`, `JensenDevice`, `IOUSBHostTransport`
- Produces: `@MainActor @Observable final class AppModel`, `AppModel.status: DeviceStatus`, `AppModel.recent: [Sidecar]`, `AppModel.syncMessage: String?`, `AppModel.start()`, `enum DeviceStatus`

- [ ] **Step 1: Write `Info.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>HiDock</string>
    <key>CFBundleIdentifier</key><string>com.jiggsfoo.hidock</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>HiDockMenubar</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
```

- [ ] **Step 2: Write `AppModel.swift`**

```swift
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

@MainActor
@Observable
public final class AppModel {
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
                defer { Task { await device.close() } }

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

                _ = try await engine.sync(device: device, serial: info.serialNumber) { progress in
                    Task { @MainActor in self?.apply(progress) }
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
              body.count >= 7 else { return nil }
        let b = [UInt8](body)
        var c = DateComponents()
        c.year = Int(b[0]) << 8 | Int(b[1])
        c.month = Int(b[2]); c.day = Int(b[3])
        c.hour = Int(b[4]); c.minute = Int(b[5]); c.second = Int(b[6])

        // Reject an implausible parse rather than report nonsense drift.
        guard let year = c.year, (2020...2100).contains(year),
              let deviceTime = Calendar.current.date(from: c) else { return nil }
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
```

- [ ] **Step 3: Write `MenuBarView.swift`**

```swift
import HiDockKit
import SwiftUI

struct MenuBarView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            statusSection
            Divider()
            recentSection
            Divider()
            actionsSection
        }
        .padding(12)
        .frame(width: 260)
    }

    @ViewBuilder
    private var statusSection: some View {
        switch model.status {
        case .disconnected:
            Label("No device", systemImage: "circle")
                .foregroundStyle(.secondary)
        case let .connected(battery, freeMiB, capacityMiB):
            Label("P1 connected", systemImage: "circle.fill")
                .foregroundStyle(.green)
            Text("\(freeMiB / 1024) GB free of \(capacityMiB / 1024) GB")
                .font(.caption).foregroundStyle(.secondary)
            if let battery {
                Text("Battery \(battery)%").font(.caption).foregroundStyle(.secondary)
            }
        case let .syncing(done, total, percent):
            Label(total > 0 ? "Syncing \(done) of \(total)" : "Reading device",
                  systemImage: "arrow.down.circle")
            ProgressView(value: Double(percent), total: 100)
        case .busy:
            Label("P1 busy", systemImage: "exclamationmark.circle")
                .foregroundStyle(.orange)
            Text("Recording, or in Vibe Mic mode")
                .font(.caption).foregroundStyle(.secondary)
        case let .unavailable(detail):
            Label("P1 unavailable", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
    }

    @ViewBuilder
    private var recentSection: some View {
        Text("Recent").font(.caption).foregroundStyle(.secondary)
        if model.recent.isEmpty {
            Text("Nothing synced yet").font(.caption).foregroundStyle(.tertiary)
        } else {
            ForEach(model.recent, id: \.signature) { item in
                Button { reveal(item) } label: {
                    HStack {
                        Text(Self.dateLabel(item.recordedAt))
                        Spacer()
                        Text(Self.durationLabel(item.durationSeconds))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var actionsSection: some View {
        Button("Reveal in Finder") {
            NSWorkspace.shared.open(model.libraryRoot)
        }
        SettingsLink { Text("Settings...") }
        Button("Quit HiDock") { NSApplication.shared.terminate(nil) }
    }

    private func reveal(_ item: Sidecar) {
        let url = model.libraryRoot.appendingPathComponent(item.relativePath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private static func dateLabel(_ date: Date?) -> String {
        guard let date else { return "unknown" }
        let f = DateFormatter()
        f.dateFormat = "MMM d  HH:mm"
        return f.string(from: date)
    }

    private static func durationLabel(_ seconds: Double?) -> String {
        guard let seconds else { return "--:--" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
```

- [ ] **Step 4: Write `HiDockApp.swift`**

```swift
import SwiftUI

@main
struct HiDockApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("HiDock", systemImage: "waveform.circle") {
            MenuBarView(model: model)
                .task { model.start() }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
    }
}
```

- [ ] **Step 5: Write `Scripts/make-app.sh`**

```bash
#!/bin/bash
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$(swift build --configuration "$CONFIG" --show-bin-path)"
APP="$ROOT/build/HiDock.app"

swift build --configuration "$CONFIG" --product HiDockMenubar

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/HiDockMenubar" "$APP/Contents/MacOS/HiDockMenubar"
cp "$ROOT/Sources/HiDockMenubar/Info.plist" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"

echo "Built $APP"
echo "Run it with: open $APP"
```

- [ ] **Step 6: Build and run**

```bash
chmod +x Scripts/make-app.sh
./Scripts/make-app.sh
open build/HiDock.app
```

Expected: a waveform icon appears in the menubar and no Dock icon. With the P1 unplugged it reads `No device`.

- [ ] **Step 7: Hardware check (manual)**

Plug in the P1. Expected: status flips to `P1 connected` within a second or two, storage is shown, and any un-synced recordings download into `~/Recordings/HiDock/`. Unplug mid-sync and confirm the status returns to `No device` and no partial file is left outside `.incoming/`.

- [ ] **Step 8: Commit**

```bash
git add Sources/HiDockMenubar Scripts/make-app.sh
git commit -m "feat(app): menubar UI, app model, sync orchestration, bundle script"
```

---

### Task 11: Settings, login item, reclaim

**Files:**
- Create: `Sources/HiDockMenubar/SettingsView.swift`
- Create: `Sources/HiDockMenubar/ReclaimView.swift`
- Modify: `Sources/HiDockMenubar/AppModel.swift`
- Modify: `Sources/HiDockMenubar/MenuBarView.swift`

**Interfaces:**
- Consumes: `AppModel`, `SyncEngine.reclaimable`, `SyncEngine.deleteFromDevice`
- Produces: `struct SettingsView`, `struct ReclaimView`, `AppModel.loadReclaimable()`, `AppModel.reclaim(_:)`, `AppModel.reclaimCandidates: [FileInfo]`

- [ ] **Step 1: Add reclaim support to `AppModel.swift`**

Append to the class:

```swift
    public var reclaimCandidates: [FileInfo] = []
    public var isLoadingReclaim = false

    /// Lists only recordings verified present on disk at the expected byte
    /// length, checked at call time rather than trusted from the index.
    public func loadReclaimable() {
        guard let index, syncTask == nil else { return }
        isLoadingReclaim = true
        let engine = SyncEngine(library: Library(root: libraryRoot), index: index)

        Task { [weak self] in
            defer { Task { @MainActor in self?.isLoadingReclaim = false } }
            do {
                let transport = try IOUSBHostTransport.openFirstAvailable()
                let device = JensenDevice(transport: transport)
                try await device.open()
                defer { Task { await device.close() } }
                let candidates = try await engine.reclaimable(device: device)
                await MainActor.run { self?.reclaimCandidates = candidates }
            } catch {
                await MainActor.run { self?.lastError = error.localizedDescription }
            }
        }
    }

    public func reclaim(_ files: [FileInfo]) {
        guard let index, syncTask == nil, !files.isEmpty else { return }
        let engine = SyncEngine(library: Library(root: libraryRoot), index: index)

        Task { [weak self] in
            do {
                let transport = try IOUSBHostTransport.openFirstAvailable()
                let device = JensenDevice(transport: transport)
                try await device.open()
                defer { Task { await device.close() } }
                _ = try await engine.deleteFromDevice(files, device: device)
                await MainActor.run { self?.reclaimCandidates = [] }
            } catch {
                await MainActor.run { self?.lastError = error.localizedDescription }
            }
        }
    }
```

- [ ] **Step 2: Write `SettingsView.swift`**

```swift
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section("Library") {
                HStack {
                    Text(model.libraryRoot.path)
                        .truncationMode(.middle).lineLimit(1)
                    Spacer()
                    Button("Change...") { chooseFolder() }
                }
                Button("Rebuild index") { model.rebuildIndex() }
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        setLoginItem(enabled)
                    }
                if let loginItemError {
                    Text(loginItemError).font(.caption).foregroundStyle(.red)
                }
            }

            if let error = model.lastError {
                Section("Last error") {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = model.libraryRoot
        if panel.runModal() == .OK, let url = panel.url {
            model.libraryRoot = url
        }
    }

    private func setLoginItem(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
```

- [ ] **Step 3: Write `ReclaimView.swift`**

```swift
import HiDockKit
import SwiftUI

struct ReclaimView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Free up space on P1").font(.headline)
            Text("Only recordings verified present on this Mac are listed. "
                 + "Deleting removes them from the device, not from your library.")
                .font(.caption).foregroundStyle(.secondary)

            if model.isLoadingReclaim {
                ProgressView().frame(maxWidth: .infinity)
            } else if model.reclaimCandidates.isEmpty {
                Text("Nothing safe to delete.").foregroundStyle(.secondary)
            } else {
                List(model.reclaimCandidates, id: \.signature) { file in
                    Toggle(isOn: binding(for: file)) {
                        HStack {
                            Text(file.name).lineLimit(1)
                            Spacer()
                            Text("\(file.lengthBytes / 1_000_000) MB")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(height: 240)
            }

            HStack {
                Button("Select all") {
                    selected = Set(model.reclaimCandidates.map(\.signature))
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Delete \(selected.count) from device") {
                    model.reclaim(model.reclaimCandidates.filter { selected.contains($0.signature) })
                    dismiss()
                }
                .disabled(selected.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 460)
        .onAppear { model.loadReclaimable() }
    }

    private func binding(for file: FileInfo) -> Binding<Bool> {
        Binding(
            get: { selected.contains(file.signature) },
            set: { isOn in
                if isOn { selected.insert(file.signature) }
                else { selected.remove(file.signature) }
            })
    }
}
```

- [ ] **Step 4: Wire reclaim into `MenuBarView.swift`**

Add to the view:

```swift
    @State private var showReclaim = false
```

Add to `actionsSection`, between "Reveal in Finder" and `SettingsLink`:

```swift
        Button("Free up space on P1...") { showReclaim = true }
            .disabled(model.status == .disconnected)
            .sheet(isPresented: $showReclaim) { ReclaimView(model: model) }
```

- [ ] **Step 5: Build and verify the full suite**

Run:
```bash
swift build
swift test
./Scripts/make-app.sh
```
Expected: builds clean, all tests pass, app bundle produced

- [ ] **Step 6: Hardware check (manual)**

1. Open Settings, change the library folder, confirm the path updates and new syncs land there.
2. Toggle "Launch at login" on, then check System Settings > General > Login Items for HiDock.
3. Click "Rebuild index" and confirm Recent still lists the same recordings.
4. With the P1 attached, open "Free up space on P1...". Confirm it lists only already-synced recordings. Select one, delete it, then run `swift run hidock-cli list` and confirm it is gone from the device while the local copy remains.

- [ ] **Step 7: Commit**

```bash
git add Sources/HiDockMenubar
git commit -m "feat(app): settings, login item, and verified reclaim flow"
```

---

## Self-review

**Spec coverage:**

| Spec requirement | Task |
|---|---|
| Menubar reflects connect state | 10 |
| Auto-sync on attach | 10 (orchestration), 8 (engine) |
| Never lose a recording | 6 (verify), 8 (commit only on match) |
| Foundation for spec 2 | 7 (sidecars, signature identity) |
| Vendor/product matching | 1 |
| Frame codec | 2 |
| Actor, one command in flight | 3 |
| Drain after timeout | 3 |
| IOUSBHost transport | 4 |
| Clock drift detection | 10 (`readClockDrift`, read-only — see deviation 4) |
| File list, count, card info | 5 |
| Streaming transfer, no RAM buffering | 6 |
| Library layout + sidecars | 7 |
| Rebuildable SQLite index | 7 (`rebuild`), 11 (button) |
| Diff on signature | 8 |
| Disk-full pre-check | 7 (`hasFreeSpace`), 8 (call site) |
| Library unreachable | 7, 8 |
| Reclaim, re-verified at click | 8, 11 |
| Interrupted transfer restarts | 6 (partial deleted), 8 (per-file isolation) |
| Invalid header resets stream | 3 |
| Backoff, never busy-loop | 10 (`scheduleRetry`) |
| Multiple P1s: bind first | 4 (`openFirstAvailable`) |
| Sleep/wake | 9 |
| Timezone recorded in sidecar | 7 |
| Login item | 11 |
| No test needs hardware | 2, 3, 5, 6, 7, 8 |

**Known deviations from the spec, deliberate:**

1. Duration is measured with `AVURLAsset` after download rather than inferred from a `fileVersion` bitrate table. More accurate, and nothing before download needs a duration.
2. Battery (`GET_BATTERY_STATUS`, 4100) is plumbed through `DeviceStatus` but reported as `nil`. Its body format is not in the reference implementation. Task 5's hardware check should capture the raw bytes so it can be parsed in a follow-up. The menubar simply omits the battery line when `nil`, so nothing is broken by this.
3. The app is built by `Scripts/make-app.sh` rather than an Xcode project, so every step is scriptable.
4. **The spec's "correct clock drift" requirement ships as detect-and-warn, not correct.** The `GET_DEVICE_TIME`/`SET_DEVICE_TIME` body layout is documented in neither reference implementation, so the parse in `readClockDrift` is a guess. A wrong read is harmless; a wrong write would corrupt the clock that names every recording. Task 5's hardware check dumps the real bytes, and enabling the write is a small follow-up once they are known. Decided with Angelo before execution, 2026-08-04.

**Placeholder scan:** clean. Every code step contains complete, compiling code. The three hardware checks that can fail (Tasks 1, 4, 5) each specify a concrete fallback and an explicit stop-and-report instruction.

**Type consistency:** `FileInfo.lengthBytes` (not `length`), `FileInfo.signature`, `Sidecar.relativePath`, `LibraryIndex.contains(signature:)`, `Library.destinationURL(for:)`, `SyncEngine.sync(device:serial:progress:)` are used identically in every task that references them. `SyncDevice` is declared in Task 8 and `JensenDevice` is conformed to it in the same task, after `deleteFile(named:)` is added.
