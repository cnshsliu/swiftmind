import AppKit
import SwiftMindCore

/// Sketch-board text support: font discovery + recents, measurement, and
/// rasterization shared by the editor overlay and the canvas thumbnail.
/// Measurement and drawing go through the SAME NSAttributedString path so a
/// committed frame always matches what renders.
@MainActor
enum SketchTextSupport {
    /// Inner padding of a sticky note (content points).
    static let stickyPadding: CGFloat = 8
    /// Sticky-note background palette (Freeform-ish defaults).
    static let stickyColors: [String] = [
        "#FFF685", // yellow
        "#FFD1E8", // pink
        "#C8E6FF", // blue
        "#D6F5D0", // green
        "#E8E8ED", // gray
    ]

    // MARK: - Fonts

    static let recentFontsKey = "swiftmind.sketchRecentFonts"
    static let recentFontLimit = 8
    static let defaultFontFamily = "Helvetica"
    static let fontSizes: [CGFloat] = [12, 14, 16, 18, 24, 32, 48]
    static let defaultFontSize: CGFloat = 18

    /// All installed font families, sorted for the font menu.
    static var fontFamilies: [String] {
        NSFontManager.shared.availableFontFamilies.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Recently used families, most recent first (UserDefaults-backed).
    static var recentFontFamilies: [String] {
        UserDefaults.standard.stringArray(forKey: recentFontsKey) ?? []
    }

    /// Move `family` to the front of the recents list (capped).
    static func noteFontUsed(_ family: String) {
        var recents = recentFontFamilies.filter { $0 != family }
        recents.insert(family, at: 0)
        if recents.count > recentFontLimit {
            recents = Array(recents.prefix(recentFontLimit))
        }
        UserDefaults.standard.set(recents, forKey: recentFontsKey)
    }

    static func font(family: String, size: CGFloat) -> NSFont {
        NSFont(name: family, size: size) ?? NSFont.systemFont(ofSize: size)
    }

    /// NSColor → "#RRGGBB" (persisted form).
    static func hex(from color: NSColor) -> String {
        let srgb = color.usingColorSpace(.sRGB) ?? .black
        func channel(_ v: CGFloat) -> Int { Int(round(min(max(v, 0), 1) * 255)) }
        return String(
            format: "#%02X%02X%02X",
            channel(srgb.redComponent),
            channel(srgb.greenComponent),
            channel(srgb.blueComponent)
        )
    }

    // MARK: - Measurement / drawing

    static func hexColor(_ hex: String) -> NSColor {
        var value: UInt64 = 0
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        Scanner(string: cleaned).scanHexInt64(&value)
        return NSColor(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    /// Attributed string used for BOTH measuring and drawing (single source).
    static func attributed(text: String, family: String, size: CGFloat, color: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: font(family: family, size: size),
            .foregroundColor: hexColor(color),
        ])
    }

    /// Rendered size of a text element, including sticky padding + border
    /// allowance when a background is set.
    static func measuredSize(text: String, family: String, size: CGFloat, sticky: Bool) -> CGSize {
        let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let probe = empty ? " " : text
        let base = attributed(text: probe, family: family, size: size, color: "#000000")
            .boundingRect(
                with: CGSize(width: 10_000, height: 10_000),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
        let pad = sticky ? stickyPadding * 2 : 0
        return CGSize(width: ceil(base.width) + pad, height: ceil(base.height) + pad)
    }

    /// Draw one text element into the current graphics context (flipped,
    /// origin top-left — the content-coordinate convention).
    static func draw(_ element: SketchText, in rect: CGRect) {
        let frame = CGRect(x: element.x, y: element.y,
                           width: element.width, height: element.height)
        guard rect.intersects(frame) else { return }
        if element.background != nil {
            hexColor(element.background!).setFill()
            NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6).fill()
            attributed(
                text: element.text,
                family: element.fontFamily,
                size: element.fontSize,
                color: element.color
            ).draw(in: frame.insetBy(dx: stickyPadding, dy: stickyPadding))
        } else {
            attributed(
                text: element.text,
                family: element.fontFamily,
                size: element.fontSize,
                color: element.color
            ).draw(at: CGPoint(x: element.x, y: element.y))
        }
    }
}
