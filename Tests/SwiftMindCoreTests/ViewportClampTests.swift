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
}
