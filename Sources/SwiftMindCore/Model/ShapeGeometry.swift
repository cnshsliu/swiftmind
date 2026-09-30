import CoreGraphics

/// Dense, geometrically exact control-point sampling for the sketch shape
/// tools. PencilKit strokes are splines through the control points, so sparse
/// samples (rect corners, a 9-point ellipse ring) render visibly deformed:
/// corners round off and the ellipse sags into its chords. Sampling the true
/// perimeter at ~2pt makes the spline deviation sub-pixel, so committed
/// rectangles stay rectangles and ellipses stay ellipses.
public enum ShapeGeometry {
    /// Max spacing between neighboring samples along the perimeter (points).
    public static let sampleSpacing: CGFloat = 2
    /// Fewest samples around an ellipse, whatever its size.
    public static let minEllipseSamples = 64

    /// Shift-constrained shape drag: the square/circle uses the LARGER extent
    /// of the drag, preserving direction. Without Shift the end is unchanged.
    public static func constrainedEnd(from start: CGPoint, to end: CGPoint, shift: Bool) -> CGPoint {
        guard shift else { return end }
        let dx = end.x - start.x
        let dy = end.y - start.y
        let extent = max(abs(dx), abs(dy))
        return CGPoint(
            x: start.x + CGFloat.sign(extent, of: dx),
            y: start.y + CGFloat.sign(extent, of: dy)
        )
    }

    /// Dense samples around the rectangle whose diagonal is a→b, starting at
    /// `a` and traversing the edges (a → (b.x,a.y) → b → (a.x,b.y) → a).
    /// Every point lies exactly on the perimeter; corners are included so the
    /// spline's corner rounding stays below the stroke width.
    public static func rectPoints(from a: CGPoint, to b: CGPoint) -> [CGPoint] {
        let corners = [a, CGPoint(x: b.x, y: a.y), b, CGPoint(x: a.x, y: b.y), a]
        var points: [CGPoint] = []
        for i in 0..<4 {
            points.append(contentsOf: samples(alongLineFrom: corners[i], to: corners[i + 1]))
        }
        points.append(a) // close the loop
        return points
    }

    /// Dense samples exactly ON the ellipse inscribed in the a→b drag rect,
    /// starting at angle 0 (3 o'clock) and closing the loop.
    public static func ellipsePoints(from a: CGPoint, to b: CGPoint) -> [CGPoint] {
        let mx = (a.x + b.x) / 2
        let my = (a.y + b.y) / 2
        let rx = abs(b.x - a.x) / 2
        let ry = abs(b.y - a.y) / 2
        // Rough circumference (Ramanujan's first approximation) only picks the
        // sample count — the points themselves use the exact parametric form.
        let h = ((rx - ry) * (rx - ry)) / ((rx + ry) * (rx + ry))
        let circumference = .pi * (rx + ry) * (1 + 3 * h / (10 + sqrt(4 - 3 * h)))
        let count = max(minEllipseSamples, Int((circumference / sampleSpacing).rounded(.up)))
        var points: [CGPoint] = []
        points.reserveCapacity(count + 1)
        for i in 0..<count {
            let t = CGFloat(i) / CGFloat(count) * 2 * .pi
            points.append(CGPoint(x: mx + rx * cos(t), y: my + ry * sin(t)))
        }
        points.append(points[0]) // close the loop EXACTLY (cos(2π) ≠ 1 in FP)
        return points
    }

    /// Uniform samples along a→b INCLUDING `from` but NOT `to` (the caller's
    /// next edge starts there), each ≤ `sampleSpacing` apart.
    private static func samples(alongLineFrom from: CGPoint, to to: CGPoint) -> [CGPoint] {
        let length = hypot(to.x - from.x, to.y - from.y)
        let steps = max(1, Int((length / sampleSpacing).rounded(.up)))
        return (0..<steps).map { i in
            let t = CGFloat(i) / CGFloat(steps)
            return CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
        }
    }

    // MARK: - Shape library (bbox-based, drag-direction agnostic)

    /// One piece of a shape outline: a straight run or a circular arc.
    private enum Outline {
        case line(CGPoint, CGPoint)
        /// Angles in radians; the sweep must be < 2π.
        case arc(center: CGPoint, radius: CGFloat, start: CGFloat, end: CGFloat)
    }

    /// Dense samples around an outline built from lines and arcs, closing the
    /// loop exactly at the first point.
    private static func points(outlining outline: [Outline]) -> [CGPoint] {
        var points: [CGPoint] = []
        for piece in outline {
            switch piece {
            case .line(let a, let b):
                points.append(contentsOf: samples(alongLineFrom: a, to: b))
            case .arc(let center, let radius, let start, let end):
                let sweep = end - start
                let length = abs(sweep) * radius
                let steps = max(2, Int((length / sampleSpacing).rounded(.up)))
                for i in 0..<steps {
                    let t = CGFloat(i) / CGFloat(steps)
                    let angle = start + sweep * t
                    points.append(CGPoint(
                        x: center.x + radius * cos(angle),
                        y: center.y + radius * sin(angle)
                    ))
                }
            }
        }
        points.append(points[0]) // close the loop EXACTLY
        return points
    }

    /// Circle-likeness of a pen stroke: closed (endpoints near), round
    /// enough bbox, low radial variance around the bbox center, and a near
    /// full angular sweep. Conservative thresholds — accidental conversion
    /// is worse than no conversion.
    public static func recognizesEllipse(_ points: [CGPoint]) -> Bool {
        guard points.count > 24 else { return false }
        let xs = points.map(\.x), ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return false }
        let w = maxX - minX, h = maxY - minY
        guard max(w, h) > 24, min(w, h) / max(w, h) > 0.55 else { return false }
        let diag = hypot(w, h)
        guard let first = points.first, let last = points.last,
              hypot(last.x - first.x, last.y - first.y) < diag * 0.2 else { return false }
        let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
        let radii = points.map { hypot($0.x - cx, $0.y - cy) }
        let mean = radii.reduce(0, +) / CGFloat(radii.count)
        let stdDev = sqrt(radii.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / CGFloat(radii.count))
        guard mean > 0, stdDev / mean < 0.22 else { return false }
        // Angular sweep (unwrapped) must cover ≥ ~315°.
        let angles = points.map { atan2($0.y - cy, $0.x - cx) }
        var total: CGFloat = 0
        for (a, b) in zip(angles, angles.dropFirst()) {
            var d = b - a
            while d > .pi { d -= 2 * .pi }
            while d < -.pi { d += 2 * .pi }
            total += d
        }
        return abs(total) > 5.5
    }

    /// The sketch board's shape vocabulary (the app's SketchTool maps onto it).
    public enum ShapeKind: String, Equatable, Sendable {
        case line, arrow, rect, roundedRect, ellipse, triangle, diamond, star, bubble
    }

    /// Dense samples for any shape kind. Line/arrow are the two endpoints
    /// (arrowheads are added by the caller).
    public static func points(for kind: ShapeKind, from a: CGPoint, to b: CGPoint) -> [CGPoint] {
        switch kind {
        case .line, .arrow: return [a, b]
        case .rect: return rectPoints(from: a, to: b)
        case .roundedRect: return roundedRectPoints(from: a, to: b)
        case .ellipse: return ellipsePoints(from: a, to: b)
        case .triangle: return trianglePoints(from: a, to: b)
        case .diamond: return diamondPoints(from: a, to: b)
        case .star: return starPoints(from: a, to: b)
        case .bubble: return bubblePoints(from: a, to: b)
        }
    }

    /// Corner radius for rounded outlines, clamped to a sane band.
    private static func cornerRadius(of box: CGRect) -> CGFloat {
        min(max(min(box.width, box.height) * 0.2, 4), 28)
    }

    private static func box(of a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x), y: min(a.y, b.y),
            width: abs(b.x - a.x), height: abs(b.y - a.y)
        )
    }

    private static let rightAngle = CGFloat.pi / 2

    /// Rounded rectangle outline: four quarter-circle corners + four edges.
    /// Each piece ends exactly where the next begins (arc endpoints and line
    /// endpoints coincide — a gap here shows up as a straight-line chord in
    /// the committed stroke).
    private static func roundedRectOutline(of box: CGRect) -> [Outline] {
        let r = cornerRadius(of: box)
        let tl = CGPoint(x: box.minX + r, y: box.minY + r)
        let tr = CGPoint(x: box.maxX - r, y: box.minY + r)
        let br = CGPoint(x: box.maxX - r, y: box.maxY - r)
        let bl = CGPoint(x: box.minX + r, y: box.maxY - r)
        return [
            .arc(center: tl, radius: r, start: .pi, end: 3 * rightAngle), // ends (minX+r, minY)
            .line(CGPoint(x: tl.x, y: box.minY), CGPoint(x: tr.x, y: box.minY)),
            .arc(center: tr, radius: r, start: -rightAngle, end: 0),     // ends (maxX, minY+r)
            .line(CGPoint(x: box.maxX, y: tr.y), CGPoint(x: box.maxX, y: br.y)),
            .arc(center: br, radius: r, start: 0, end: rightAngle),      // ends (maxX-r, maxY)
            .line(CGPoint(x: br.x, y: box.maxY), CGPoint(x: bl.x, y: box.maxY)),
            .arc(center: bl, radius: r, start: rightAngle, end: .pi),    // ends (minX, maxY-r)
            .line(CGPoint(x: box.minX, y: bl.y), CGPoint(x: box.minX, y: tl.y)),
        ]
    }

    /// Rounded rectangle (Freeform's soft rectangle).
    public static func roundedRectPoints(from a: CGPoint, to b: CGPoint) -> [CGPoint] {
        points(outlining: roundedRectOutline(of: box(of: a, b)))
    }

    /// Triangle with the apex at the top-center of the drag box.
    public static func trianglePoints(from a: CGPoint, to b: CGPoint) -> [CGPoint] {
        let box = box(of: a, b)
        let apex = CGPoint(x: box.midX, y: box.minY)
        let right = CGPoint(x: box.maxX, y: box.maxY)
        let left = CGPoint(x: box.minX, y: box.maxY)
        return points(outlining: [
            .line(apex, right), .line(right, left), .line(left, apex),
        ])
    }

    /// Diamond through the midpoints of the drag box's edges.
    public static func diamondPoints(from a: CGPoint, to b: CGPoint) -> [CGPoint] {
        let box = box(of: a, b)
        let top = CGPoint(x: box.midX, y: box.minY)
        let right = CGPoint(x: box.maxX, y: box.midY)
        let bottom = CGPoint(x: box.midX, y: box.maxY)
        let left = CGPoint(x: box.minX, y: box.midY)
        return points(outlining: [
            .line(top, right), .line(right, bottom), .line(bottom, left), .line(left, top),
        ])
    }

    /// Five-point star filling the drag box, inner radius 0.45 of outer. The
    /// outer vertices sit at -90°/±18°/±54°+180°, so the radii are scaled by
    /// cos(18°)/sin(54°) to make the spikes touch all four box edges.
    public static func starPoints(from a: CGPoint, to b: CGPoint) -> [CGPoint] {
        let box = box(of: a, b)
        let rx = box.width / (2 * cos(.pi / 10))
        let ry = box.height / (1 + sin(.pi * 0.3))   // top spike + bottom spike pair
        let cx = box.midX
        let cy = box.minY + ry                       // top spike lands on minY
        let inner: CGFloat = 0.45
        var vertices: [CGPoint] = []
        for i in 0..<10 {
            let angle = -.pi / 2 + CGFloat(i) * .pi / 5
            let factor: CGFloat = i.isMultiple(of: 2) ? 1 : inner
            vertices.append(CGPoint(
                x: cx + rx * factor * cos(angle),
                y: cy + ry * factor * sin(angle)
            ))
        }
        var outline: [Outline] = []
        for i in 0..<vertices.count {
            outline.append(.line(vertices[i], vertices[(i + 1) % vertices.count]))
        }
        return points(outlining: outline)
    }

    /// Speech bubble: rounded rectangle with a tail on the bottom-left.
    public static func bubblePoints(from a: CGPoint, to b: CGPoint) -> [CGPoint] {
        let box = box(of: a, b)
        let r = cornerRadius(of: box)
        let tailBase2 = CGPoint(x: box.minX + box.width * 0.30, y: box.maxY)
        let tailTip = CGPoint(x: box.minX + box.width * 0.22, y: box.maxY + box.height * 0.18)
        let tailBase1 = CGPoint(x: box.minX + box.width * 0.16, y: box.maxY)
        let br = CGPoint(x: box.maxX - r, y: box.maxY - r)
        let bl = CGPoint(x: box.minX + r, y: box.maxY - r)
        return points(outlining: [
            .arc(center: CGPoint(x: box.minX + r, y: box.minY + r), radius: r, start: .pi, end: 3 * rightAngle),
            .line(CGPoint(x: box.minX + r, y: box.minY), CGPoint(x: box.maxX - r, y: box.minY)),
            .arc(center: CGPoint(x: box.maxX - r, y: box.minY + r), radius: r, start: -rightAngle, end: 0),
            .line(CGPoint(x: box.maxX, y: box.minY + r), CGPoint(x: box.maxX, y: br.y)),
            .arc(center: br, radius: r, start: 0, end: rightAngle),
            .line(CGPoint(x: br.x, y: box.maxY), tailBase2),   // bottom edge → tail
            .line(tailBase2, tailTip),                         // tail right side
            .line(tailTip, tailBase1),                         // tail left side
            .line(tailBase1, CGPoint(x: bl.x, y: box.maxY)),   // back to the bottom edge
            .arc(center: bl, radius: r, start: rightAngle, end: .pi),
            .line(CGPoint(x: box.minX, y: bl.y), CGPoint(x: box.minX, y: box.minY + r)),
        ])
    }
}

private extension CGFloat {
    /// `magnitude` with the sign of `of` (zero counts as positive).
    static func sign(_ magnitude: CGFloat, of value: CGFloat) -> CGFloat {
        value < 0 ? -magnitude : magnitude
    }
}
