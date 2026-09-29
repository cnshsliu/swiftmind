import XCTest
@testable import SwiftMindCore

/// Dense shape sampling for sketch strokes: a PKStrokePath is a spline through
/// its control points, so the committed points must lie ON the true geometry —
/// sparse samples (corners, a 9-point ring) render deformed.
final class ShapeGeometryTests: XCTestCase {
    private let a = CGPoint(x: 100, y: 80)
    private let b = CGPoint(x: 340, y: 260)

    // MARK: - Rectangle

    func testRectPointsAllLieOnPerimeter() {
        let points = ShapeGeometry.rectPoints(from: a, to: b)
        XCTAssertGreaterThan(points.count, 100, "rect sampling must be dense")
        let minX = min(a.x, b.x), maxX = max(a.x, b.x)
        let minY = min(a.y, b.y), maxY = max(a.y, b.y)
        for p in points {
            let onVertical = abs(p.x - minX) < 1e-6 || abs(p.x - maxX) < 1e-6
            let onHorizontal = abs(p.y - minY) < 1e-6 || abs(p.y - maxY) < 1e-6
            XCTAssertTrue(onVertical || onHorizontal,
                          "(\(p.x), \(p.y)) is off the rectangle perimeter")
        }
    }

    func testRectPointsIncludeAllCornersAndClose() {
        let points = ShapeGeometry.rectPoints(from: a, to: b)
        XCTAssertEqual(points.first, a, "sampling starts at the drag origin")
        XCTAssertEqual(points.last, a, "the loop closes back on the origin")
        let cornerSet = Set(points.map { "\(Int(round($0.x))),\(Int(round($0.y)))" })
        for corner in [a, b, CGPoint(x: b.x, y: a.y), CGPoint(x: a.x, y: b.y)] {
            XCTAssertTrue(
                cornerSet.contains("\(Int(corner.x)),\(Int(corner.y))"),
                "corner (\(corner.x), \(corner.y)) must be a control point"
            )
        }
    }

    func testRectSamplingSpacingStaysUnderBudget() {
        let points = ShapeGeometry.rectPoints(from: a, to: b)
        for (p, q) in zip(points, points.dropFirst()) {
            XCTAssertLessThanOrEqual(hypot(q.x - p.x, q.y - p.y),
                                     ShapeGeometry.sampleSpacing + 1e-6)
        }
    }

    func testRectHandlesReversedDrag() {
        // Drag up-left: same rectangle, traversal adapts, points still on edges.
        let points = ShapeGeometry.rectPoints(from: b, to: a)
        XCTAssertEqual(points.first, b)
        for p in points {
            let onVertical = abs(p.x - a.x) < 1e-6 || abs(p.x - b.x) < 1e-6
            let onHorizontal = abs(p.y - a.y) < 1e-6 || abs(p.y - b.y) < 1e-6
            XCTAssertTrue(onVertical || onHorizontal)
        }
    }

    // MARK: - Ellipse

    func testEllipsePointsSatisfyEllipseEquation() {
        let points = ShapeGeometry.ellipsePoints(from: a, to: b)
        XCTAssertGreaterThanOrEqual(points.count, ShapeGeometry.minEllipseSamples + 1)
        let mx = (a.x + b.x) / 2, my = (a.y + b.y) / 2
        let rx = abs(b.x - a.x) / 2, ry = abs(b.y - a.y) / 2
        for p in points {
            let term = pow((p.x - mx) / rx, 2) + pow((p.y - my) / ry, 2)
            XCTAssertEqual(term, 1, accuracy: 1e-9,
                           "(\(p.x), \(p.y)) is not on the ellipse")
        }
    }

    func testEllipseLoopClosesAndSpansFullCircle() {
        let points = ShapeGeometry.ellipsePoints(from: a, to: b)
        XCTAssertEqual(points.first, points.last, "the ring must close")
        // A full sweep touches all four extremes of the bounding box.
        let xs = points.map(\.x), ys = points.map(\.y)
        XCTAssertEqual((xs.max() ?? 0) - (xs.min() ?? 0), abs(b.x - a.x), accuracy: 1e-6)
        XCTAssertEqual((ys.max() ?? 0) - (ys.min() ?? 0), abs(b.y - a.y), accuracy: 1e-6)
    }

    func testCircleDragProducesTrueCircle() {
        // Square bounding box → every sample equidistant from the center.
        let squareB = CGPoint(x: a.x + 160, y: a.y + 160)
        let points = ShapeGeometry.ellipsePoints(from: a, to: squareB)
        let mx = (a.x + squareB.x) / 2, my = (a.y + squareB.y) / 2
        for p in points {
            XCTAssertEqual(hypot(p.x - mx, p.y - my), 80, accuracy: 1e-9)
        }
    }

    // MARK: - Shift constraint

    func testShiftConstraintEqualizesExtents() {
        let end = CGPoint(x: 200, y: 150) // 60 right, 100 down from a
        let constrained = ShapeGeometry.constrainedEnd(from: a, to: end, shift: true)
        XCTAssertEqual(abs(constrained.x - a.x), abs(constrained.y - a.y), accuracy: 1e-9)
        // The larger extent wins; direction is preserved.
        XCTAssertEqual(constrained.x - a.x, 100, accuracy: 1e-9)
        XCTAssertEqual(constrained.y - a.y, 100, accuracy: 1e-9)
    }

    func testShiftConstraintHandlesNegativeDirections() {
        let end = CGPoint(x: 40, y: 260) // 60 left, 180 down
        let constrained = ShapeGeometry.constrainedEnd(from: a, to: end, shift: true)
        XCTAssertEqual(constrained.x - a.x, -180, accuracy: 1e-9)
        XCTAssertEqual(constrained.y - a.y, 180, accuracy: 1e-9)
    }

    func testNoShiftLeavesEndUntouched() {
        let end = CGPoint(x: 200, y: 150)
        XCTAssertEqual(ShapeGeometry.constrainedEnd(from: a, to: end, shift: false), end)
    }
}
