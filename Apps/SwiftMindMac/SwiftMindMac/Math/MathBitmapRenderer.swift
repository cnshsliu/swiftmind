import AppKit
import SwiftUI

/// Renders inline math to a bitmap and MEASURES the fraction-bar position
/// from the rendered pixels (the bar is dyed pure red in the measurement
/// pass). The paragraph embeds the image in a `Text` with an exact
/// `baselineOffset`, so '=' aligns with the bar by construction — no
/// metric estimation in the alignment path.
///
/// Bitmaps are cached per (latex, size, colorScheme): notes re-render on
/// every keystroke while the floating editor is open, but only the formula
/// being edited changes.
enum MathBitmapRenderer {
    struct Rendered {
        let image: NSImage
        /// Points from the image TOP to the math baseline (bar row, or the
        /// estimated text baseline when the formula has no bar).
        let baseline: CGFloat
        let height: CGFloat
        let width: CGFloat
    }

    private static let cache = NSCache<NSString, RenderedBox>()
    private static let scale: CGFloat = 3

    private final class RenderedBox {
        let value: Rendered?
        init(_ v: Rendered?) { value = v }
    }

    static func rendered(
        latex: String, fontSize: CGFloat, dark: Bool
    ) -> Rendered? {
        let key = "\(latex)|\(fontSize)|\(dark ? 1 : 0)" as NSString
        if let hit = cache.object(forKey: key) { return hit.value }
        let value = render(latex: latex, fontSize: fontSize, dark: dark)
        cache.setObject(RenderedBox(value), forKey: key)
        return value
    }

    private static func render(
        latex: String, fontSize: CGFloat, dark: Bool
    ) -> Rendered? {
        let measurement = bitmap(
            latex: latex, fontSize: fontSize, dark: dark, measure: true
        )
        let display = bitmap(
            latex: latex, fontSize: fontSize, dark: dark, measure: false
        )
        guard let display else { return nil }

        let baseline: CGFloat
        if let m = measurement,
           let barRow = redBarRow(
            m.rep, width: Int(m.pixels.width), height: Int(m.pixels.height)
           ) {
            // Bar goes on the MATH AXIS (~0.25em above the text baseline),
            // level with where '=' is centered — not on the baseline itself.
            baseline = (barRow + 0.5) / scale + fontSize * 0.25
        } else {
            // No bar (plain runs/scripts): estimated text baseline plus the
            // padding bleed around the rendered view.
            let est = LaTeXMetrics.box(latex: latex, fontSize: fontSize).baseline
            baseline = est + display.size.height - LaTeXMetrics.box(
                latex: latex, fontSize: fontSize
            ).height
        }
        return Rendered(
            image: display.image,
            baseline: baseline,
            height: display.size.height,
            width: display.size.width
        )
    }

    private struct Bitmap {
        let image: NSImage
        let rep: NSBitmapImageRep
        let size: CGSize
        let pixels: CGSize
    }

    private static func bitmap(
        latex: String, fontSize: CGFloat, dark: Bool, measure: Bool
    ) -> Bitmap? {
        let view = LaTeXMathView(latex: latex, fontSize: fontSize, measure: measure)
            .fixedSize()
            .padding(2) // bleed so strokes aren't clipped at the bitmap edge
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.setFrameSize(NSSize(width: 4096, height: 4096))
        host.layoutSubtreeIfNeeded()
        let fit = host.fittingSize
        guard fit.width > 0, fit.height > 0,
              fit.width.isFinite, fit.height.isFinite,
              fit.width < 4000, fit.height < 4000 else { return nil }
        host.setFrameSize(fit)
        host.layoutSubtreeIfNeeded()
        let pxW = Int((fit.width * scale).rounded())
        let pxH = Int((fit.height * scale).rounded())
        guard pxW > 0, pxH > 0, pxW < 12000, pxH < 12000 else { return nil }
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pxW, pixelsHigh: pxH,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = fit
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        host.cacheDisplay(in: host.bounds, to: rep)
        NSGraphicsContext.current = nil
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]),
              let image = NSImage(data: data) else { return nil }
        image.size = fit
        return Bitmap(
            image: image, rep: rep, size: fit,
            pixels: CGSize(width: pxW, height: pxH)
        )
    }

    /// Finds the vertical center of the red measurement bar, in bitmap
    /// pixels from the TOP.
    private static func redBarRow(
        _ rep: NSBitmapImageRep, width: Int, height: Int
    ) -> CGFloat? {
        var rows: [Int: Int] = [:] // y -> red pixel count
        for y in 0..<height {
            var count = 0
            for x in 0..<width {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let r = c.redComponent, g = c.greenComponent, b = c.blueComponent
                if c.alphaComponent > 0.3, r > 0.75, g < 0.25, b < 0.25 {
                    count += 1
                }
            }
            if count > 0 { rows[y] = count }
        }
        guard !rows.isEmpty else { return nil }
        // The bar is the row band with the most red; average weighted by count.
        let best = rows.max { $0.value < $1.value }!
        let band = rows.filter { abs($0.key - best.key) <= 3 }
        let total = band.reduce(0) { $0 + $1.value }
        let weighted = band.reduce(0.0) { $0 + Double($1.key) * Double($1.value) }
        return CGFloat(weighted / Double(total))
    }
}
