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

    // MARK: - Shape library (Freeform parity)

    private var dragBox: CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    /// Min distance from a point to a segment.
    private func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let abx = b.x - a.x, aby = b.y - a.y
        let t = min(max(((p.x - a.x) * abx + (p.y - a.y) * aby) / (abx * abx + aby * aby), 0), 1)
        return hypot(p.x - a.x - abx * t, p.y - a.y - aby * t)
    }

    private func assertDenseClosed(_ points: [CGPoint], spacing: CGFloat = 2.5,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(points.count, 20, file: file, line: line)
        XCTAssertEqual(points.first, points.last, "loop must close", file: file, line: line)
        for (p, q) in zip(points, points.dropFirst()) {
            XCTAssertLessThanOrEqual(hypot(q.x - p.x, q.y - p.y), spacing,
                                     "sampling must stay dense", file: file, line: line)
        }
    }

    private func assertOnPolyline(_ points: [CGPoint], _ vertices: [CGPoint],
                                  file: StaticString = #filePath, line: UInt = #line) {
        for p in points {
            let best = zip(vertices, vertices.dropFirst() + [vertices[0]])
                .map { distance(from: p, toSegment: $0.0, $0.1) }
                .min()!
            XCTAssertLessThanOrEqual(best, 1e-6,
                                     "(\(p.x), \(p.y)) is off the expected polyline",
                                     file: file, line: line)
        }
    }

    func testTriangleOnExpectedEdges() {
        let points = ShapeGeometry.trianglePoints(from: a, to: b)
        assertDenseClosed(points)
        let box = dragBox
        assertOnPolyline(points, [
            CGPoint(x: box.midX, y: box.minY),
            CGPoint(x: box.maxX, y: box.maxY),
            CGPoint(x: box.minX, y: box.maxY),
        ])
    }

    func testDiamondOnExpectedEdges() {
        let points = ShapeGeometry.diamondPoints(from: a, to: b)
        assertDenseClosed(points)
        let box = dragBox
        assertOnPolyline(points, [
            CGPoint(x: box.midX, y: box.minY),
            CGPoint(x: box.maxX, y: box.midY),
            CGPoint(x: box.midX, y: box.maxY),
            CGPoint(x: box.minX, y: box.midY),
        ])
    }

    func testStarOnTenVertexPolyline() {
        let points = ShapeGeometry.starPoints(from: a, to: b)
        assertDenseClosed(points)
        let box = dragBox
        let rx = box.width / (2 * cos(CGFloat.pi / 10))
        let ry = box.height / (1 + sin(CGFloat.pi * 0.3))
        let cx = box.midX, cy = box.minY + ry
        var vertices: [CGPoint] = []
        for i in 0..<10 {
            let angle = -CGFloat.pi / 2 + CGFloat(i) * .pi / 5
            let factor: CGFloat = i.isMultiple(of: 2) ? 1 : 0.45
            vertices.append(CGPoint(x: cx + rx * factor * cos(angle),
                                    y: cy + ry * factor * sin(angle)))
        }
        assertOnPolyline(points, vertices)
        // The star fills the drag box: spikes touch all four edges.
        XCTAssertEqual(points.map(\.x).min()!, box.minX, accuracy: 1e-6)
        XCTAssertEqual(points.map(\.x).max()!, box.maxX, accuracy: 1e-6)
        XCTAssertEqual(points.map(\.y).min()!, box.minY, accuracy: 1e-6)
        XCTAssertEqual(points.map(\.y).max()!, box.maxY, accuracy: 1e-6)
    }

    func testRoundedRectPointsOnTrueOutline() {
        let points = ShapeGeometry.roundedRectPoints(from: a, to: b)
        assertDenseClosed(points)
        let box = dragBox
        // Rounded outlines never leave their drag box (regression: the
        // top-left arc once swept 3/4 of its corner circle, bulging outside).
        for p in points {
            XCTAssertTrue(box.insetBy(dx: -1e-6, dy: -1e-6).contains(p),
                          "(\(p.x), \(p.y)) escapes the rounded rect box")
        }
        let r = min(max(min(box.width, box.height) * 0.2, 4), 28)
        // (center, outward signs) per corner — a corner-circle sample must sit
        // in ITS quarter (regression: the top-left arc once swept 3/4 of its
        // circle, denting into the box while still "on" the circle).
        let corners: [(center: CGPoint, sx: CGFloat, sy: CGFloat)] = [
            (CGPoint(x: box.minX + r, y: box.minY + r), -1, -1),
            (CGPoint(x: box.maxX - r, y: box.minY + r), 1, -1),
            (CGPoint(x: box.maxX - r, y: box.maxY - r), 1, 1),
            (CGPoint(x: box.minX + r, y: box.maxY - r), -1, 1),
        ]
        for p in points {
            // On the outline = on one of the 4 straight edges (inset by r)
            // or in the correct quarter of one of the 4 corner circles.
            let onEdge =
                (abs(p.y - box.minY) < 1e-6 && p.x >= box.minX + r && p.x <= box.maxX - r)
                || (abs(p.y - box.maxY) < 1e-6 && p.x >= box.minX + r && p.x <= box.maxX - r)
                || (abs(p.x - box.minX) < 1e-6 && p.y >= box.minY + r && p.y <= box.maxY - r)
                || (abs(p.x - box.maxX) < 1e-6 && p.y >= box.minY + r && p.y <= box.maxY - r)
            let inCornerQuarter = corners.contains { corner in
                guard abs(hypot(p.x - corner.center.x, p.y - corner.center.y) - r) < 1e-6 else {
                    return false
                }
                return (p.x - corner.center.x) * corner.sx >= -1e-6
                    && (p.y - corner.center.y) * corner.sy >= -1e-6
            }
            XCTAssertTrue(onEdge || inCornerQuarter,
                          "(\(p.x), \(p.y)) is off the rounded rect outline")
        }
        // Bounding box spans the drag box (corners touch at 45° diagonals).
        XCTAssertEqual(points.map(\.x).min()!, box.minX, accuracy: 1e-6)
        XCTAssertEqual(points.map(\.y).min()!, box.minY, accuracy: 1e-6)
    }

    func testBubbleHasTailBelowBottomEdge() {
        let points = ShapeGeometry.bubblePoints(from: a, to: b)
        assertDenseClosed(points)
        let box = dragBox
        let boxWithTail = box.insetBy(dx: -1e-6, dy: -1e-6)
            .union(CGRect(x: box.minX, y: box.maxY, width: box.width, height: box.height * 0.2))
        for p in points {
            XCTAssertTrue(boxWithTail.contains(p),
                          "(\(p.x), \(p.y)) escapes the bubble outline")
        }
        let tipY = box.maxY + box.height * 0.18
        XCTAssertEqual(points.map(\.y).max()!, tipY, accuracy: 1e-6,
                       "the tail tip must be the lowest point")
        // The tail is real ink: some point sits clearly below the box.
        XCTAssertGreaterThan(points.map(\.y).max()!, box.maxY + 5)
    }

    func testAllShapesRespectDragBoundingBox() {
        let box = dragBox
        let shapes = [
            ShapeGeometry.roundedRectPoints(from: a, to: b),
            ShapeGeometry.trianglePoints(from: a, to: b),
            ShapeGeometry.diamondPoints(from: a, to: b),
            ShapeGeometry.starPoints(from: a, to: b),
        ]
        for points in shapes {
            XCTAssertEqual(points.map(\.x).min()!, box.minX, accuracy: 1e-6)
            XCTAssertEqual(points.map(\.x).max()!, box.maxX, accuracy: 1e-6)
            XCTAssertEqual(points.map(\.y).min()!, box.minY, accuracy: 1e-6)
            XCTAssertEqual(points.map(\.y).max()!, box.maxY, accuracy: 1e-6)
        }
    }
}
