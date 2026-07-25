import SwiftUI
import AppKit
import SwiftMindCore

/// Semantic colors and spacing for a cohesive light/dark Mac mind-map chrome.
/// Prefer system semantic colors so Liquid Glass / materials stay native.
enum Theme {
    // MARK: - Canvas

    /// Map background — slight cool tint in light, deep neutral in dark.
    static var canvasBackground: Color {
        Color(nsColor: .textBackgroundColor)
    }

    /// Default edge stroke between nodes.
    static var edgeStroke: Color {
        Color.secondary.opacity(0.45)
    }

    /// Selection ring.
    static var selectionStroke: Color {
        Color.accentColor
    }

    /// Drop target during reparent.
    static var dropTarget: Color {
        Color.orange
    }

    /// Pin affordance.
    static var pinAccent: Color {
        Color.orange
    }

    /// Node fill when the model has no custom fill.
    static var nodeDefaultFill: Color {
        Color(nsColor: .controlBackgroundColor)
    }

    /// Soft elevated node surface (light cards / dark panels).
    static var nodeElevatedFill: Color {
        Color(nsColor: .windowBackgroundColor).opacity(0.92)
    }

    /// Default body text on canvas when style is pure black (legacy default).
    static var nodeDefaultText: Color {
        Color.primary
    }

    /// Secondary labels / badges on canvas.
    static var badgeMuted: Color {
        Color.secondary
    }

    // MARK: - Chrome

    static var sidebarCaption: Font { .caption.weight(.semibold) }
    static var sectionSpacing: CGFloat { 12 }
    static var controlRadius: CGFloat { 8 }

    static var hairline: Color {
        Color(nsColor: .separatorColor)
    }

    /// Toolbar / status strip material background.
    static var chromeMaterial: Material { .bar }
}

extension NodeStyle {
    /// Whether this style still uses the legacy pure-black default text color.
    var usesLegacyBlackText: Bool {
        textRed == 0 && textGreen == 0 && textBlue == 0
            && fillRed == nil && fillGreen == nil && fillBlue == nil
    }

    /// Resolved SwiftUI text color for canvas (theme-aware for defaults).
    var canvasTextColor: Color {
        if usesLegacyBlackText {
            return Theme.nodeDefaultText
        }
        return Color(red: textRed, green: textGreen, blue: textBlue)
    }

    /// Optional custom fill as Color.
    var canvasFillColor: Color? {
        guard let r = fillRed, let g = fillGreen, let b = fillBlue else { return nil }
        return Color(red: r, green: g, blue: b)
    }
}
