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
    static func image(nodeID: NodeID, data: Data, boardSize: CGSize, scale: CGFloat) -> NSImage? {
        let bucket = max(1, (scale * 2).rounded())
        let key = "\(nodeID.rawValue)#\(data.hashValue)#\(Int(bucket))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let drawing = try? PKDrawing(data: data) else { return nil }
        let rendered = drawing.image(from: CGRect(origin: .zero, size: boardSize), scale: bucket)
        cache.setObject(rendered, forKey: key)
        return rendered
    }

    /// Trim-to-content: translates strokes so content sits at `padding` from
    /// the origin (baked into the path points) and returns the new payload
    /// plus the padded content size. Returns nil for an empty (or
    /// undecodable) drawing.
    static func trim(_ data: Data, padding: Double) -> (data: Data, size: CGSize)? {
        guard let drawing = try? PKDrawing(data: data) else { return nil }
        let bounds = drawing.bounds
        guard !bounds.isNull, !bounds.isEmpty, !bounds.isInfinite else { return nil }
        let pad = CGFloat(padding)
        let shift = CGAffineTransform(
            translationX: -bounds.minX + pad,
            y: -bounds.minY + pad
        )
        let trimmed = PKDrawing(strokes: drawing.strokes.map { translated($0, by: shift) })
        return (
            trimmed.dataRepresentation(),
            CGSize(width: bounds.width + pad * 2, height: bounds.height + pad * 2)
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
