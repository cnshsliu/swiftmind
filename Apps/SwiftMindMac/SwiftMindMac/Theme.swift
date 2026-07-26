import SwiftUI
import AppKit
import SwiftMindCore

/// Semantic colors and spacing for a cohesive light/dark Mac mind-map chrome.
enum Theme {
    // MARK: - Canvas

    static var canvasBackground: Color {
        Color(nsColor: .textBackgroundColor)
    }

    /// Soft stage tint so the map reads as a surface, not the window itself.
    static func canvasStageFill(for scheme: ColorScheme) -> Color {
        switch scheme {
        case .dark:
            return Color(nsColor: .underPageBackgroundColor)
        default:
            return Color(nsColor: .controlBackgroundColor).opacity(0.35)
        }
    }

    static func edgeStroke(for scheme: ColorScheme) -> Color {
        switch scheme {
        case .dark:
            return Color.secondary.opacity(0.55)
        default:
            return Color.secondary.opacity(0.40)
        }
    }

    static var selectionStroke: Color { Color.accentColor }

    /// Reparent drop target — accent (not orange; pin owns orange).
    static var dropTarget: Color { Color.accentColor }

    /// Pin affordance — distinct from drop/selection.
    static var pinAccent: Color { Color.orange }

    static var nodeDefaultFill: Color {
        Color(nsColor: .controlBackgroundColor)
    }

    static var nodeDefaultText: Color { Color.primary }

    static var badgeMuted: Color { Color.secondary }

    // MARK: - Chrome

    static var sidebarCaption: Font { .caption.weight(.semibold) }
    static var sectionSpacing: CGFloat { 12 }
    static var controlRadius: CGFloat { 8 }

    static var hairline: Color {
        Color(nsColor: .separatorColor)
    }

    static var chromeMaterial: Material { .bar }
}

extension NodeStyle {
    /// Legacy pure-black text with no fill → theme-adaptive on canvas.
    var usesLegacyBlackText: Bool {
        textRed == 0 && textGreen == 0 && textBlue == 0
            && fillRed == nil && fillGreen == nil && fillBlue == nil
    }

    /// Root accent style: light text (fill comes from system accent at draw time).
    var isRootAccentStyle: Bool {
        textRed > 0.9 && textGreen > 0.9 && textBlue > 0.9
            && (fillRed != nil || fillBlue != nil)
    }

    var canvasTextColor: Color {
        if usesLegacyBlackText {
            return Theme.nodeDefaultText
        }
        return Color(red: textRed, green: textGreen, blue: textBlue)
    }

    var canvasFillColor: Color? {
        guard let r = fillRed, let g = fillGreen, let b = fillBlue else { return nil }
        // Stored root blue is a sentinel — prefer live system accent.
        if isRootAccentStyle {
            return Color.accentColor
        }
        return Color(red: r, green: g, blue: b)
    }
}
