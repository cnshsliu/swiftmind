import AppKit
import PencilKit
import SwiftMindCore

/// Sketch-node rendering and geometry helpers (the only PencilKit render path).
/// iOS port note: swap NSImage → UIImage; everything else is platform-neutral.
@MainActor
enum SketchSupport {
    private static let cache = NSCache<NSString, NSImage>()

    /// Translates strokes so the content center lands at `size`'s center —
    /// used when loading a committed (origin-normalized) sketch into the
    /// large editor. Trim on commit re-normalizes, so the offset is view-only.
    static func centered(_ data: Data, in size: CGSize) -> Data {
        guard let drawing = try? PKDrawing(data: data) else { return data }
        let bounds = drawing.bounds
        guard !bounds.isNull, !bounds.isEmpty, !bounds.isInfinite else { return data }
        let transform = CGAffineTransform(
            translationX: size.width / 2 - bounds.midX,
            y: size.height / 2 - bounds.midY
        )
        let strokes = drawing.strokes.map { stroke in
            PKStroke(ink: stroke.ink, path: stroke.path, transform: transform)
        }
        return PKDrawing(strokes: strokes).dataRepresentation()
    }


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

    /// Trim-to-content: translates strokes so content sits at `padding` from the
    /// origin and returns the new payload plus the padded content size.
    /// Returns nil for an empty (or undecodable) drawing.
    static func trim(_ data: Data, padding: Double) -> (data: Data, size: CGSize)? {
        guard let drawing = try? PKDrawing(data: data) else { return nil }
        let bounds = drawing.bounds
        guard !bounds.isNull, !bounds.isEmpty, !bounds.isInfinite else { return nil }
        let pad = CGFloat(padding)
        let transform = CGAffineTransform(
            translationX: -bounds.minX + pad,
            y: -bounds.minY + pad
        )
        let strokes = drawing.strokes.map { stroke in
            PKStroke(ink: stroke.ink, path: stroke.path, transform: transform)
        }
        let trimmed = PKDrawing(strokes: strokes)
        return (
            trimmed.dataRepresentation(),
            CGSize(width: bounds.width + pad * 2, height: bounds.height + pad * 2)
        )
    }
}
