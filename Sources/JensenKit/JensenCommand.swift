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
    case getRecordingFile  = 18
    case getBatteryStatus  = 4100
}
