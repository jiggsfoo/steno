import Foundation

public enum JensenError: Error, Equatable, Sendable {
    case deviceNotFound
    case interfaceUnavailable(String)
    case invalidHeader
    case timeout(command: UInt16)
    case shortBody(command: UInt16, expected: Int, got: Int)
    case transferIncomplete(expected: Int, got: Int)
    case fileWriteFailed(String)
    case notConnected
}

/// Without this, every case renders in the menubar as the generic Cocoa
/// fallback — "The operation couldn't be completed. (HiDockMenubar.JensenError
/// error 0.)" — meaningless to someone reading a status line, not a stack trace.
extension JensenError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .deviceNotFound:
            return "No HiDock P1 found. Make sure it's plugged in."
        case .interfaceUnavailable(let detail):
            return "Couldn't connect to the P1 (\(detail))."
        case .invalidHeader:
            return "The P1 sent a response HiDock didn't understand."
        case .timeout:
            return "The P1 didn't respond in time. It may be recording, or in Vibe Mic Bluetooth mode."
        case .shortBody:
            return "The P1 sent an incomplete response."
        case .transferIncomplete:
            return "A file transfer from the P1 was cut short. Try again."
        case .fileWriteFailed(let reason):
            return "Couldn't save the file to disk (\(reason))."
        case .notConnected:
            return "The P1 isn't connected."
        }
    }
}
