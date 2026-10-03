import Foundation

extension Notification.Name {
    /// userInfo: `path` (String), `move` (Bool). My Brain shows the sheet.
    static let swiftMindTransferMap = Notification.Name("swiftMind.transferMap")
    /// userInfo: `path` (String). Removes the vault listing only.
    static let swiftMindDetachVault = Notification.Name("swiftMind.detachVault")
    /// userInfo: `old` and `new` absolute paths. The open window follows the file.
    static let swiftMindMapFileRenamed = Notification.Name("swiftMind.mapFileRenamed")
}
