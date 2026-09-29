import AppKit
import PencilKit
import SwiftMindCore

/// Sketch-node rendering and geometry helpers (the only PencilKit render path).
/// iOS port note: swap NSImage → UIImage; everything else is platform-neutral.
///
/// Stroke coordinates are always baked into the path points — never carried
/// as a `PKStroke` transform. macOS PencilKit corrupts composed transforms on
/// encode (trim → re-open → trim scattered strokes to negative coordinates,
/// which is what made thumbnails lose content and the editor drift).
@MainActor
enum SketchSupport {
    private static let cache = NSCache<NSString, NSImage>()

    static func emptyDrawingData() -> Data {
        PKDrawing().dataRepresentation()
    }

    /// Rasterized board image, memoized per (node, content hash, zoom bucket).
    /// Text elements are composited on top of the PencilKit rasterization.
    static func image(
        nodeID: NodeID,
        data: Data,
        texts: [SketchText],
        boardSize: CGSize,
        scale: CGFloat
    ) -> NSImage? {
        let bucket = max(1, (scale * 2).rounded())
        let key = "\(nodeID.rawValue)#\(data.hashValue)#\(texts.map(\.id).joined().hashValue)#\(texts.map(\.text).joined().hashValue)#\(Int(bucket))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let drawing = try? PKDrawing(data: data) else { return nil }
        let boardRect = CGRect(origin: .zero, size: boardSize)
        // Aqua-forced: under Dark appearance PKDrawing.image() inverts black
        // and white inks for legibility — thumbnails must show literal colors.
        var rendered: NSImage?
        if let aqua = NSAppearance(named: .aqua) {
            aqua.performAsCurrentDrawingAppearance {
                rendered = drawing.image(from: boardRect, scale: bucket)
            }
        }
        let rasterized = rendered ?? drawing.image(from: boardRect, scale: bucket)
        guard !texts.isEmpty else {
            cache.setObject(rasterized, forKey: key)
            return rasterized
        }
        // Compose text over the rasterized strokes in a flipped context
        // (content coordinates are y-down).
        let composed = NSImage(size: boardSize)
        composed.lockFocusFlipped(true)
        rasterized.draw(in: boardRect)
        for element in texts {
            SketchTextSupport.draw(element, in: boardRect)
        }
        composed.unlockFocus()
        cache.setObject(composed, forKey: key)
        return composed
    }

    /// Trim-to-content over strokes AND text elements: everything is
    /// translated so the union content sits at `padding` from the origin and
    /// the padded union size is returned. Returns nil when there is no
    /// content at all (no strokes, or an undecodable drawing with no texts).
    static func trim(
        _ data: Data,
        texts: [SketchText],
        padding: Double
    ) -> (data: Data, texts: [SketchText], size: CGSize)? {
        let pad = CGFloat(padding)
        let drawing = try? PKDrawing(data: data)
        let strokeBounds = drawing?.bounds ?? .null
        let hasStrokes = drawing != nil && !strokeBounds.isNull
            && !strokeBounds.isEmpty && !strokeBounds.isInfinite
        guard hasStrokes || !texts.isEmpty else { return nil }

        var union = CGRect.null
        if hasStrokes { union = strokeBounds }
        for text in texts {
            union = union.union(CGRect(x: text.x, y: text.y, width: text.width, height: text.height))
        }
        let shift = CGAffineTransform(translationX: -union.minX + pad, y: -union.minY + pad)
        let trimmedData: Data
        if let drawing, hasStrokes {
            trimmedData = PKDrawing(strokes: drawing.strokes.map { translated($0, by: shift) })
                .dataRepresentation()
        } else {
            trimmedData = emptyDrawingData()
        }
        let shiftedTexts = texts.map { text in
            var moved = text
            let origin = CGPoint(x: text.x, y: text.y).applying(shift)
            moved.x = Double(origin.x)
            moved.y = Double(origin.y)
            return moved
        }
        return (
            trimmedData,
            shiftedTexts,
            CGSize(width: union.width + pad * 2, height: union.height + pad * 2)
        )
    }

    /// A copy of the stroke with the affine translation baked into its path
    /// control points (width/opacity/force and creation date preserved).
    static func translated(_ stroke: PKStroke, by t: CGAffineTransform) -> PKStroke {
        let points = (0..<stroke.path.count).map { i -> PKStrokePoint in
            let p = stroke.path[i]
            return PKStrokePoint(
                location: p.location.applying(t),
                timeOffset: p.timeOffset,
                size: p.size,
                opacity: p.opacity,
                force: p.force,
                azimuth: p.azimuth,
                altitude: p.altitude
            )
        }
        return PKStroke(
            ink: stroke.ink,
            path: PKStrokePath(controlPoints: points, creationDate: stroke.path.creationDate)
        )
    }
}
