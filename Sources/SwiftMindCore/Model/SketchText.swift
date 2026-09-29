import Foundation

/// A text element on a sketch board — a plain text box, or a sticky note
/// when `background` is set. Positions and sizes are CONTENT points (the same
/// space as stroke geometry), with the top-left anchor. `width`/`height` are
/// measured at commit time and persisted (the sketchWidth/Height pattern), so
/// hit-testing, trimming, and thumbnails never need font metrics.
public struct SketchText: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var text: String
    /// Top-left anchor in content points.
    public var x: Double
    public var y: Double
    public var fontFamily: String
    public var fontSize: Double
    /// Foreground ink as "#RRGGBB".
    public var color: String
    /// Sticky-note background as "#RRGGBB"; nil = plain text box.
    public var background: String?
    /// Rendered size in content points (measured at commit, persisted).
    public var width: Double
    public var height: Double

    public init(
        id: String = UUID().uuidString,
        text: String,
        x: Double,
        y: Double,
        fontFamily: String,
        fontSize: Double,
        color: String = "#000000",
        background: String? = nil,
        width: Double,
        height: Double
    ) {
        self.id = id
        self.text = text
        self.x = x
        self.y = y
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.color = color
        self.background = background
        self.width = width
        self.height = height
    }

    /// Frame in content points.
    public var frame: Rect2D {
        Rect2D(x: x, y: y, width: width, height: height)
    }

    /// True when the text carries visible content worth persisting.
    public var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
