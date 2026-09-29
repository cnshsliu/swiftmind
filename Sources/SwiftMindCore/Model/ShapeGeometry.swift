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
}

private extension CGFloat {
    /// `magnitude` with the sign of `of` (zero counts as positive).
    static func sign(_ magnitude: CGFloat, of value: CGFloat) -> CGFloat {
        value < 0 ? -magnitude : magnitude
    }
}
