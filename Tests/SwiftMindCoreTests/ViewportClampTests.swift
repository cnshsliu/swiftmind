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

    // MARK: - visibleClampedOffset (interactive pan: drag + scroll)

    /// Content comfortably covering the view: offset passes through.
    func testVisibleClampKeepsFreeOffset() {
        var vp = CanvasViewport(scale: 1, offset: Point2D(x: 300, y: -120))
        vp.offset = vp.visibleClampedOffset(
            contentBounds: content, viewWidth: 1000, viewHeight: 800
        )
        XCTAssertEqual(vp.offset.x, 300)
        XCTAssertEqual(vp.offset.y, -120)
    }

    /// Dragging far right stops when the content's right edge hits the 25%
    /// safe-rect boundary — free until then, never blank beyond.
    func testVisibleClampStopsAtContentEdge() {
        var vp = CanvasViewport(scale: 1, offset: Point2D(x: -100_000, y: 0))
        vp.offset = vp.visibleClampedOffset(
            contentBounds: content, viewWidth: 1000, viewHeight: 800
        )
        // maxXv0 = 1000*1 + 500 = 1500; lower bound = 250 - 1500 = -1250.
        XCTAssertEqual(vp.offset.x, -1250, accuracy: 1e-9)
        // …and the opposite extreme pins the left edge at viewW - margin.
        vp.offset = Point2D(x: 100_000, y: 0)
        vp.offset = vp.visibleClampedOffset(
            contentBounds: content, viewWidth: 1000, viewHeight: 800
        )
        // minXv0 = -1000 + 500 = -500; upper bound = 750 + 500 = 1250.
        XCTAssertEqual(vp.offset.x, 1250, accuracy: 1e-9)
    }

    /// Tiny content zoomed out: it can be pushed to the safe-rect boundary
    /// but never out of it — at least a strip of content stays visible.
    func testVisibleClampTinyContentZoomedOut() {
        let tiny = Rect2D(x: 0, y: 0, width: 100, height: 80)
        var vp = CanvasViewport(scale: 0.25, offset: Point2D(x: 10_000, y: -10_000))
        vp.offset = vp.visibleClampedOffset(
            contentBounds: tiny, viewWidth: 1000, viewHeight: 800
        )
        // minXv0 = 0*0.25 + 500 = 500 → upper bound 750 - 500 = 250.
        // maxYv0 = 80*0.25 + 400 = 420 → lower bound 200 - 420 = -220.
        XCTAssertEqual(vp.offset.x, 250, accuracy: 1e-9)
        XCTAssertEqual(vp.offset.y, -220, accuracy: 1e-9)
    }

    /// Zoomed all the way in, the same rule still holds on the y axis.
    func testVisibleClampAtMaxScale() {
        var vp = CanvasViewport(scale: 3, offset: Point2D(x: 0, y: 100_000))
        vp.offset = vp.visibleClampedOffset(
            contentBounds: content, viewWidth: 1000, viewHeight: 800
        )
        // minYv0 = -700*3 + 400 = -1700; upper bound = 600 + 1700 = 2300.
        XCTAssertEqual(vp.offset.y, 2300, accuracy: 1e-9)
    }

    /// Degenerate view sizes leave the offset alone.
    func testVisibleClampDegenerateViewPassesThrough() {
        var vp = CanvasViewport(scale: 1, offset: Point2D(x: 9999, y: 9999))
        vp.offset = vp.visibleClampedOffset(
            contentBounds: content, viewWidth: 0, viewHeight: 0
        )
        XCTAssertEqual(vp.offset.x, 9999)
        XCTAssertEqual(vp.offset.y, 9999)
    }
}
