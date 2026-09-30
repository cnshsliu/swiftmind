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
        shapes: [SketchShape] = [],
        images: [SketchImageElement] = [],
        background: String? = nil,
        boardSize: CGSize,
        scale: CGFloat
    ) -> NSImage? {
        let bucket = max(1, (scale * 2).rounded())
        let key = "\(nodeID.rawValue)#\(data.hashValue)#\(texts.map(\.id).joined().hashValue)#\(texts.map(\.text).joined().hashValue)#\(shapes.count)#\(shapes.map { $0.text ?? "" }.joined().hashValue)#\(images.count)#\(images.map { $0.data.hashValue }.reduce(0, &+))#\(Int(bucket))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let drawing = try? PKDrawing(data: data) else { return nil }
        let boardRect = CGRect(origin: .zero, size: boardSize)

        // Frame the FULL content (strokes ∪ texts). The model's boardSize can
        // lag the data mid-session (frames are pinned while the editor is open
        // so the map doesn't relayout under it), and rendering the stale
        // (0,0,w,h) region cropped the thumbnail to a corner of the drawing.
        var region = drawing.bounds
        if drawing.strokes.isEmpty || region.isNull || region.isEmpty || region.isInfinite {
            region = .null
        }
        for text in texts {
            region = region.union(CGRect(
                x: text.x, y: text.y, width: text.width, height: text.height
            ))
        }
        for shape in shapes {
            region = region.union(CGRect(
                x: min(shape.x, shape.x + shape.width),
                y: min(shape.y, shape.y + shape.height),
                width: abs(shape.width), height: abs(shape.height)
            ))
        }
        for image in images {
            region = region.union(CGRect(
                x: image.x, y: image.y, width: image.width, height: image.height
            ))
        }
        if region.isNull || region.isEmpty || region.isInfinite {
            region = boardRect
        } else {
            region = region.insetBy(dx: -2, dy: -2) // don't shave stroke edges
        }

        // Aqua-forced: under Dark appearance PKDrawing.image() inverts black
        // and white inks for legibility — thumbnails must show literal colors.
        var rendered: NSImage?
        if let aqua = NSAppearance(named: .aqua) {
            aqua.performAsCurrentDrawingAppearance {
                rendered = drawing.image(from: region, scale: bucket)
            }
        }
        let rasterized = rendered ?? drawing.image(from: region, scale: bucket)

        // Aspect-fit the content region into the board frame, centered. With
        // the frame matching the trimmed content (post-close steady state)
        // the fit is ~1:1 and this is a no-op visually.
        let fit = min(boardSize.width / max(region.width, 1),
                      boardSize.height / max(region.height, 1))
        let dest = CGRect(
            x: (boardSize.width - region.width * fit) / 2,
            y: (boardSize.height - region.height * fit) / 2,
            width: region.width * fit,
            height: region.height * fit
        )
        let composed = NSImage(size: boardSize)
        composed.lockFocusFlipped(true)
        if let background {
            SketchTextSupport.hexColor(background).setFill()
            boardRect.fill()
        }
        rasterized.draw(in: dest)
        if !shapes.isEmpty || !texts.isEmpty {
            let cg = NSGraphicsContext.current?.cgContext
            cg?.saveGState()
            cg?.translateBy(x: dest.minX, y: dest.minY)
            cg?.scaleBy(x: fit, y: fit)
            cg?.translateBy(x: -region.minX, y: -region.minY)
            for image in images {
                if let nsImage = NSImage(data: image.data) {
                    nsImage.draw(in: CGRect(
                        x: image.x, y: image.y, width: image.width, height: image.height
                    ))
                }
            }
            for shape in shapes {
                Self.draw(shape)
            }
            for element in texts {
                SketchTextSupport.draw(element, in: region)
            }
            cg?.restoreGState()
        }
        composed.unlockFocus()
        cache.setObject(composed, forKey: key)
        return composed
    }

    /// Draw one shape element into the current (already transformed) graphics
    /// context: outline via dense ShapeGeometry samples, optional fill,
    /// arrowhead for .arrow, centered label via the shared text path.
    private static func draw(_ shape: SketchShape) {
        guard let kind = shape.shapeKind else { return }
        let a = CGPoint(x: shape.x, y: shape.y)
        let b = CGPoint(x: shape.x + shape.width, y: shape.y + shape.height)
        var cgPath = CGMutablePath()
        let samples = ShapeGeometry.points(for: kind, from: a, to: b)
        guard let first = samples.first else { return }
        cgPath.move(to: first, transform: .identity)
        for sample in samples.dropFirst() {
            cgPath.addLine(to: sample, transform: .identity)
        }
        if kind == .arrow {
            let angle = atan2(b.y - a.y, b.x - a.x)
            let head = max(CGFloat(10), CGFloat(shape.strokeWidth) * 4)
            for sign in [CGFloat.pi * 0.82, -CGFloat.pi * 0.82] {
                let tip = CGPoint(x: b.x + head * cos(angle + sign),
                                  y: b.y + head * sin(angle + sign))
                cgPath.move(to: b, transform: .identity)
                cgPath.addLine(to: tip, transform: .identity)
            }
        }
        if let fill = shape.fillColor {
            let fillPath = NSBezierPath(cgPath: cgPath)
            SketchTextSupport.hexColor(fill).setFill()
            fillPath.fill()
        }
        SketchTextSupport.hexColor(shape.strokeColor).setStroke()
        let line = NSBezierPath(cgPath: cgPath)
        line.lineWidth = CGFloat(shape.strokeWidth)
        line.lineCapStyle = .round
        line.lineJoinStyle = .round
        line.stroke()
        if let label = shape.text, !label.isEmpty {
            let box = CGRect(
                x: min(shape.x, shape.x + shape.width),
                y: min(shape.y, shape.y + shape.height),
                width: abs(shape.width), height: abs(shape.height)
            ).insetBy(dx: 8, dy: 6)
            let attributed = SketchTextSupport.attributed(
                text: label, family: shape.fontFamily,
                size: CGFloat(shape.fontSize), color: shape.textColor
            )
            let bounds = attributed.boundingRect(
                with: CGSize(width: max(box.width, 10), height: max(box.height, 10)),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            let origin = CGPoint(
                x: box.midX - bounds.midX,
                y: box.midY - bounds.midY
            )
            attributed.draw(at: origin)
        }
    }

    /// Trim-to-content over strokes AND text elements: everything is
    /// translated so the union content sits at `padding` from the origin and
    /// the padded union size is returned. Returns nil when there is no
    /// content at all (no strokes, or an undecodable drawing with no texts).
    static func trim(
        _ data: Data,
        texts: [SketchText],
        shapes: [SketchShape] = [],
        images: [SketchImageElement] = [],
        padding: Double
    ) -> (data: Data, texts: [SketchText], shapes: [SketchShape], images: [SketchImageElement], size: CGSize)? {
        let pad = CGFloat(padding)
        let drawing = try? PKDrawing(data: data)
        let strokeBounds = drawing?.bounds ?? .null
        let hasStrokes = drawing != nil && !strokeBounds.isNull
            && !strokeBounds.isEmpty && !strokeBounds.isInfinite
        guard hasStrokes || !texts.isEmpty || !shapes.isEmpty || !images.isEmpty else { return nil }

        var union = CGRect.null
        if hasStrokes { union = strokeBounds }
        for text in texts {
            union = union.union(CGRect(x: text.x, y: text.y, width: text.width, height: text.height))
        }
        for shape in shapes {
            union = union.union(CGRect(
                x: min(shape.x, shape.x + shape.width),
                y: min(shape.y, shape.y + shape.height),
                width: abs(shape.width), height: abs(shape.height)
            ))
        }
        for image in images {
            union = union.union(CGRect(
                x: image.x, y: image.y, width: image.width, height: image.height
            ))
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
        let shiftedImages = images.map { image in
            var moved = image
            let origin = CGPoint(x: image.x, y: image.y).applying(shift)
            moved.x = Double(origin.x)
            moved.y = Double(origin.y)
            return moved
        }
        let shiftedShapes = shapes.map { shape in
            var moved = shape
            let origin = CGPoint(x: shape.x, y: shape.y).applying(shift)
            moved.x = Double(origin.x)
            moved.y = Double(origin.y)
            return moved
        }
        return (
            trimmedData,
            shiftedTexts,
            shiftedShapes,
            shiftedImages,
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
