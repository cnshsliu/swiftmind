import Foundation

/// Named styles on a map (Freeplane-inspired, simplified).
public struct StyleSheet: Equatable, Sendable, Codable {
    /// name → style template
    public var styles: [String: NodeStyle]

    public init(styles: [String: NodeStyle] = [:]) {
        self.styles = styles
    }

    public static let defaultSheet: StyleSheet = {
        var sheet = StyleSheet()
        sheet.styles["topic"] = NodeStyle(
            fontSize: 16,
            isBold: true,
            textRed: 0.1,
            textGreen: 0.2,
            textBlue: 0.45
        )
        sheet.styles["important"] = NodeStyle(
            fontSize: 14,
            isBold: true,
            textRed: 0.7,
            textGreen: 0.15,
            textBlue: 0.1,
            fillRed: 1.0,
            fillGreen: 0.95,
            fillBlue: 0.9
        )
        sheet.styles["note"] = NodeStyle(
            fontSize: 12,
            isBold: false,
            textRed: 0.35,
            textGreen: 0.35,
            textBlue: 0.4
        )
        return sheet
    }()

    public func style(named name: String?) -> NodeStyle? {
        guard let name, !name.isEmpty else { return nil }
        return styles[name]
    }
}

/// Merges named style + local overrides (local non-default fields win simply by using local as base if no name).
public enum StyleResolver {
    /// Effective style for display: named template merged with local node.style.
    /// Local style wins on a field-by-field basis when it differs from `.default`.
    public static func resolve(node: Node, sheet: StyleSheet) -> NodeStyle {
        let named = sheet.style(named: node.styleName) ?? NodeStyle.default
        return merge(base: named, overlay: node.style)
    }

    private static func merge(base: NodeStyle, overlay: NodeStyle) -> NodeStyle {
        let def = NodeStyle.default
        return NodeStyle(
            fontSize: overlay.fontSize != def.fontSize ? overlay.fontSize : base.fontSize,
            isBold: overlay.isBold != def.isBold ? overlay.isBold : base.isBold,
            textRed: overlayText(overlay, base, def, \.textRed),
            textGreen: overlayText(overlay, base, def, \.textGreen),
            textBlue: overlayText(overlay, base, def, \.textBlue),
            fillRed: overlay.fillRed ?? base.fillRed,
            fillGreen: overlay.fillGreen ?? base.fillGreen,
            fillBlue: overlay.fillBlue ?? base.fillBlue
        )
    }

    private static func overlayText(
        _ overlay: NodeStyle,
        _ base: NodeStyle,
        _ def: NodeStyle,
        _ key: KeyPath<NodeStyle, Double>
    ) -> Double {
        // If overlay still looks like default black body text and base has custom, prefer base
        // when all three text channels are default.
        let overlayIsDefaultText =
            overlay.textRed == def.textRed
            && overlay.textGreen == def.textGreen
            && overlay.textBlue == def.textBlue
        if overlayIsDefaultText {
            return base[keyPath: key]
        }
        return overlay[keyPath: key]
    }
}
