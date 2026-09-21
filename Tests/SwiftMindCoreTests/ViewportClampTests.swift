import XCTest
@testable import SwiftMindCore

/// Viewport offset clamping: content must stay reachable no matter what
/// gesture glitch or poisoned saved state throws at the offset.
final class ViewportClampTests: XCTestCase {
    private let content = Rect2D(x: -1000, y: -700, width: 2000, height: 1400)

    private func contentViewRect(_ vp: CanvasViewport) -> Rect2D {
        Rect2D(
            x: content.x * vp.scale + vp.offset.x,
            y: content.y * vp.scale + vp.offset.y,
            width: content.width * vp.scale,
            height: content.height * vp.scale
        )
    }

    func testClampPullsExtremeOffsetBackToContent() {
        // The real-world poison: scale 3, offset-y 206745 (the user's
        // persisted Welcome-map viewport — window rendered empty).
        var vp = CanvasViewport(scale: 3, offset: Point2D(x: 732, y: 206_745))
        vp.offset = vp.clampedOffset(
            contentBounds: content, viewWidth: 1000, viewHeight: 800
        )
        let c = contentViewRect(vp)
        XCTAssertTrue(
            c.x < 1000 && c.x + c.width > 0 && c.y < 800 && c.y + c.height > 0,
            "clamped offset must bring content back into view, got \(vp.offset)"
        )
    }

    func testClampKeepsNormalOffset() {
        var vp = CanvasViewport(scale: 1, offset: Point2D(x: 100, y: -50))
        vp.offset = vp.clampedOffset(
            contentBounds: content, viewWidth: 1000, viewHeight: 800
        )
        XCTAssertEqual(vp.offset.x, 100)
        XCTAssertEqual(vp.offset.y, -50)
    }

    /// Zoomed far out (0.25) on big content: panning anywhere reasonable stays.
    func testClampAllowsGenerousPanAtMinScale() {
        var vp = CanvasViewport(scale: 0.25, offset: Point2D(x: 0, y: 0))
        vp.offset = vp.clampedOffset(
            contentBounds: content, viewWidth: 1000, viewHeight: 800
        )
        XCTAssertEqual(vp.offset.x, 0)
        XCTAssertEqual(vp.offset.y, 0)
    }

    // MARK: - panClampedOffset (interactive pan: drag + scroll)

    /// Coverage rule: content larger than the view must cover it; content
    /// smaller than the view stays inside it. View math for these tests:
    /// p_view = p_map*scale + viewSize/2 + offset; view 1000×800.

    /// Offset inside the feasible interval passes through untouched.
    func testPanClampKeepsFreeOffset() {
        var vp = CanvasViewport(scale: 1, offset: Point2D(x: 300, y: -120))
        vp.offset = vp.panClampedOffset(
            contentBounds: content, viewWidth: 1000, viewHeight: 800
        )
        XCTAssertEqual(vp.offset.x, 300)
        XCTAssertEqual(vp.offset.y, -120)
    }

    /// Big content, pan far right: stops with the content's right edge flush
    /// at the viewport's right edge — screen still 100% content, zero blank.
    func testPanClampStopsFlushAtContentEdges() {
        var vp = CanvasViewport(scale: 1, offset: Point2D(x: -100_000, y: 0))
        vp.offset = vp.panClampedOffset(
            contentBounds: content, viewWidth: 1000, viewHeight: 800
        )
        // maxXv0 = 1000 + 500 = 1500; flush right edge → ox = 1000 - 1500 = -500.
        XCTAssertEqual(vp.offset.x, -500, accuracy: 1e-9)
        // Opposite extreme: left edge flush at view x = 0.
        vp.offset = Point2D(x: 100_000, y: 0)
        vp.offset = vp.panClampedOffset(
            contentBounds: content, viewWidth: 1000, viewHeight: 800
        )
        // minXv0 = -1000 + 500 = -500 → ox = 500.
        XCTAssertEqual(vp.offset.x, 500, accuracy: 1e-9)
    }

    /// Tiny content zoomed out: it stays fully inside the viewport — freely
    /// positionable, but never partially pushed out.
    func testPanClampTinyContentStaysInside() {
        let tiny = Rect2D(x: 0, y: 0, width: 100, height: 80)
        var vp = CanvasViewport(scale: 0.25, offset: Point2D(x: 10_000, y: -10_000))
        vp.offset = vp.panClampedOffset(
            contentBounds: tiny, viewWidth: 1000, viewHeight: 800
        )
        // maxXv0 = 100*0.25 + 500 = 525 → flush at right edge: ox = 1000-525 = 475.
        // minYv0 = 400 → flush at top edge: oy = -400.
        XCTAssertEqual(vp.offset.x, 475, accuracy: 1e-9)
        XCTAssertEqual(vp.offset.y, -400, accuracy: 1e-9)
    }

    /// Zoomed all the way in, the y axis still stops flush at the edge.
    func testPanClampAtMaxScale() {
        var vp = CanvasViewport(scale: 3, offset: Point2D(x: 0, y: 100_000))
        vp.offset = vp.panClampedOffset(
            contentBounds: content, viewWidth: 1000, viewHeight: 800
        )
        // minYv0 = -700*3 + 400 = -1700 → top edge flush at 0: oy = 1700.
        XCTAssertEqual(vp.offset.y, 1700, accuracy: 1e-9)
    }

    /// Degenerate view sizes leave the offset alone.
    func testPanClampDegenerateViewPassesThrough() {
        var vp = CanvasViewport(scale: 1, offset: Point2D(x: 9999, y: 9999))
        vp.offset = vp.panClampedOffset(
            contentBounds: content, viewWidth: 0, viewHeight: 0
        )
        XCTAssertEqual(vp.offset.x, 9999)
        XCTAssertEqual(vp.offset.y, 9999)
    }
}
