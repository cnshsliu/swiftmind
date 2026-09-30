import Foundation

/// An image element on a sketch board. Frame in content points; payload is
/// normalized PNG data (same pipeline as note images). Codable encodes the
/// Data as base64 automatically.
public struct SketchImageElement: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var text: String
    /// Top-left anchor in content points.
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    /// Normalized PNG payload.
    public var data: Data

    public init(
        id: String = UUID().uuidString,
        text: String = "",
        x: Double, y: Double, width: Double, height: Double,
        data: Data
    ) {
        self.id = id
        self.text = text
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.data = data
    }

    public var frame: Rect2D {
        Rect2D(x: x, y: y, width: width, height: height)
    }
}
