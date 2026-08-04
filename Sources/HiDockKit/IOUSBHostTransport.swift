import Foundation
import IOKit
@preconcurrency import IOUSBHost

public actor IOUSBHostTransport: USBTransport {
    private let service: io_service_t
    private var interface: IOUSBHostInterface?
    private var outPipe: IOUSBHostPipe?
    private var inPipe: IOUSBHostPipe?

    private static let endpointOut: Int = 0x01
    private static let endpointIn: Int = 0x82

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

    /// Correct and required, not a double-release. IOUSBHostObject's header
    /// states it "will keep a reference to the io_service_t and release it
    /// after the IOUSBHostObject has been released" — the init borrows, it
    /// does not consume. The caller's own reference is still the caller's to
    /// free. Verified against the SDK header 2026-08-04. Do not remove.
    deinit {
        IOObjectRelease(service)
    }

    public func open() async throws {
        guard interface == nil else { return }
        var claimed: IOUSBHostInterface?
        do {
            let iface = try IOUSBHostInterface(
                __ioService: service, options: [], queue: nil, interestHandler: nil)
            claimed = iface
            try iface.selectAlternateSetting(0)
            self.outPipe = try iface.copyPipe(withAddress: Self.endpointOut)
            self.inPipe = try iface.copyPipe(withAddress: Self.endpointIn)
            self.interface = iface
        } catch {
            // A pipe holds a STRONG reference to its interface. An orphaned pipe
            // therefore keeps the exclusive IOService claim alive, and every
            // later open() fails with "user client already created" for the rest
            // of the process lifetime. Tear it down explicitly.
            outPipe = nil
            inPipe = nil
            claimed?.destroy()
            interface = nil
            throw JensenError.interfaceUnavailable(String(describing: error))
        }
    }

    public func close() async {
        // Abort synchronously BEFORE destroy. destroy() tears down the user
        // client, and a blocking __sendIORequest outstanding against these pipes
        // would then be operating on a connection that no longer exists.
        if let outPipe { try? outPipe.__abort(with: .synchronous) }
        if let inPipe { try? inPipe.__abort(with: .synchronous) }
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

    /// Carries the pipe and buffer into the detached closure.
    ///
    /// The `buffer` is genuinely exclusive: a fresh `NSMutableData` is allocated
    /// per call, never stored in actor state, and read only after the
    /// continuation resumes. The `pipe` is NOT exclusive — it is actor state
    /// that `close()` also reaches. Safety therefore rests on `close()` aborting
    /// both pipes before `destroy()`, and on `JensenDevice.close()` holding the
    /// FIFO gate so no transfer is in flight when it runs.
    private struct UncheckedSendableBox: @unchecked Sendable {
        let pipe: IOUSBHostPipe
        let buffer: NSMutableData
    }

    /// `__sendIORequest` blocks the calling thread, so it runs off the actor.
    @discardableResult
    private static func transfer(
        pipe: IOUSBHostPipe,
        buffer: NSMutableData,
        timeout: TimeInterval,
        toleratesTimeout: Bool = false
    ) async throws -> Int {
        let box = UncheckedSendableBox(pipe: pipe, buffer: buffer)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var transferred = 0
                do {
                    try box.pipe.__sendIORequest(
                        with: box.buffer, bytesTransferred: &transferred,
                        completionTimeout: timeout)
                    continuation.resume(returning: transferred)
                } catch {
                    // ONLY a genuine timeout means "nothing arrived". Anything
                    // else — kIOReturnNoDevice on unplug, a stalled pipe — must
                    // propagate, or an absent device reads as a merely idle one
                    // and every command spins out its full budget before failing.
                    guard toleratesTimeout,
                          (error as NSError).code == kIOReturnTimeout else {
                        continuation.resume(throwing: error)
                        return
                    }
                    // Bytes already moved off the endpoint are consumed even on a
                    // timeout. Reporting 0 would silently discard them and desync
                    // the stream.
                    continuation.resume(returning: transferred)
                }
            }
        }
    }
}
