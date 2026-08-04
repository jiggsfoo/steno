import Foundation
import IOKit
@preconcurrency import IOUSBHost

/// `IOUSBHostPipe` and `NSMutableData` are reference types that are not
/// `Sendable`, but `transfer(pipe:buffer:...)` hands both to a detached
/// `DispatchQueue.global` closure and nothing else touches either value
/// until the continuation resumes — there is no concurrent access for the
/// compiler to protect against, just a single ownership handoff.
private struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
}

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
        let boxedPipe = UncheckedSendableBox(value: pipe)
        let boxedBuffer = UncheckedSendableBox(value: buffer)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var transferred = 0
                do {
                    try boxedPipe.value.__sendIORequest(
                        with: boxedBuffer.value, bytesTransferred: &transferred,
                        completionTimeout: timeout)
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
