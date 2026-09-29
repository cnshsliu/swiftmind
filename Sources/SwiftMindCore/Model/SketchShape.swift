import Foundation

/// A shape element on a sketch board — the PPT-style building block: geometry
/// (kind + frame), outline/fill styling, and an optional centered label.
/// Model-layer element like SketchText (not ink): it stays editable (label,
/// fill, later resize) and is removed with the select tool, not the eraser.
public struct SketchShape: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: Kind
    /// Top-left anchor + size in content points.
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    /// Outline color "#RRGGBB".
    public var strokeColor: String
    /// Outline width in content points.
    public var strokeWidth: Double
    /// Fill color "#RRGGBB"; nil = transparent.
    public var fillColor: String?
    /// Centered label (markdown-free plain text); nil = no label.
    public var text: String?
    public var fontFamily: String
    public var fontSize: Double
    /// Label color "#RRGGBB".
    public var textColor: String

    public enum Kind: String, Codable, Sendable, CaseIterable {
        case line, arrow, rect, roundedRect, ellipse, triangle, diamond, star, bubble
    }

    public init(
        id: String = UUID().uuidString,
        kind: Kind,
        x: Double, y: Double, width: Double, height: Double,
        strokeColor: String = "#000000",
        strokeWidth: Double = 3,
        fillColor: String? = nil,
        text: String? = nil,
        fontFamily: String = "Helvetica",
        fontSize: Double = 16,
        textColor: String = "#000000"
    ) {
        self.id = id
        self.kind = kind
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.strokeColor = strokeColor
        self.strokeWidth = strokeWidth
        self.fillColor = fillColor
        self.text = text
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.textColor = textColor
    }

    /// Frame in content points (kind .line/.arrow treat it as the endpoint
    /// pair: (x,y) → (x+width, y+height)).
    public var frame: Rect2D {
        Rect2D(x: x, y: y, width: width, height: height)
    }

    public var isEmpty: Bool {
        width < 1 || height < 1
    }

    /// The geometry vocabulary shared with ShapeGeometry (app-side rendering
    /// maps Kind → ShapeKind 1:1).
    public var shapeKind: ShapeGeometry.ShapeKind? {
        ShapeGeometry.ShapeKind(rawValue: kind.rawValue)
    }
}
