import Foundation

public protocol USBTransport: Sendable, Actor {
    func open() async throws
    func close() async
    func write(_ data: Data) async throws
    /// Returns an empty Data when nothing arrived before the timeout.
    /// Empty means "nothing in this window", NOT "the endpoint is empty".
    func read(maxLength: Int, timeout: Duration) async throws -> Data
}
