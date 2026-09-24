import AppKit
import SwiftUI

extension NSAttributedString.Key {
    /// Marks the key name of a `<kbd>` span so the editor can draw a cap behind it.
    static let swiftMindKeyCap = NSAttributedString.Key("swiftmind.kbd")
}

/// A small keyboard cap: rounded rectangle, hairline edge, the key name inside.
enum KeyCapChrome {
    static func draw(in rect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let box = rect.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    /// Cap height is the surrounding font's line box (ascender to descender),
    /// not the label's own line height plus padding.
    static func lineBox(fontSize: CGFloat) -> (height: CGFloat, baseline: CGFloat) {
        let body = NSFont.systemFont(ofSize: fontSize)
        return (body.ascender - body.descender, body.descender)
    }

    static func image(label: String, fontSize: CGFloat) -> NSImage {
        let key = "\(label)|\(String(format: "%.1f", fontSize))|\(NSApp.effectiveAppearance.name.rawValue)"
        if let cached = cache.object(forKey: key as NSString) { return cached }
        let line = lineBox(fontSize: fontSize)
        let height = line.height.rounded(.up)
        let font = NSFont.systemFont(ofSize: fontSize * 0.72, weight: .medium)
        let text = label as NSString
        let textSize = text.size(withAttributes: [.font: font])
        let width = max(ceil(textSize.width) + 6, height)
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            draw(in: rect)
            let labelRect = NSRect(
                x: (rect.width - textSize.width) / 2,
                y: (rect.height - textSize.height) / 2,
                width: textSize.width,
                height: textSize.height
            )
            text.draw(in: labelRect, withAttributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor,
            ])
            return true
        }
        cache.setObject(image, forKey: key as NSString)
        return image
    }

    private static let cache = NSCache<NSString, NSImage>()
}
