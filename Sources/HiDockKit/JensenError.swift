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
