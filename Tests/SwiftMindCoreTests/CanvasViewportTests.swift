import XCTest
@testable import SwiftMindCore

final class CanvasViewportTests: XCTestCase {
    private let w = 800.0
    private let h = 600.0
    private let anchor = Point2D(x: 200, y: 150)

    private func mapUnderAnchor(_ v: CanvasViewport) -> Point2D {
        v.mapPoint(fromView: anchor, viewWidth: w, viewHeight: h)
    }

    func testDefaultIsActualSize() {
        let v = CanvasViewport()
        XCTAssertEqual(v.scale, 1)
        XCTAssertEqual(v.offset, .zero)
        XCTAssertTrue(v.isActualSize)
        XCTAssertFalse(v.isAtMinScale)
        XCTAssertFalse(v.isAtMaxScale)
    }

    func testZoomInStepsBy125AndClamps() {
        var v = CanvasViewport()
        v.zoomByStepping(.in, anchorView: anchor, viewWidth: w, viewHeight: h)
        XCTAssertEqual(v.scale, 1.25, accuracy: 1e-12)
        for _ in 0..<20 {
            v.zoomByStepping(.in, anchorView: anchor, viewWidth: w, viewHeight: h)
        }
        XCTAssertEqual(v.scale, CanvasViewport.maxScale)
        XCTAssertTrue(v.isAtMaxScale)
        let offsetAtMax = v.offset
        v.zoomByStepping(.in, anchorView: anchor, viewWidth: w, viewHeight: h)
        XCTAssertEqual(v.scale, CanvasViewport.maxScale)
        XCTAssertEqual(v.offset.x, offsetAtMax.x, accuracy: 1e-9)
        XCTAssertEqual(v.offset.y, offsetAtMax.y, accuracy: 1e-9)
    }

    func testZoomOutClampsToMin() {
        var v = CanvasViewport()
        for _ in 0..<20 {
            v.zoomByStepping(.out, anchorView: anchor, viewWidth: w, viewHeight: h)
        }
        XCTAssertEqual(v.scale, CanvasViewport.minScale)
        XCTAssertTrue(v.isAtMinScale)
        let offsetAtMin = v.offset
        v.zoomByStepping(.out, anchorView: anchor, viewWidth: w, viewHeight: h)
        XCTAssertEqual(v.scale, CanvasViewport.minScale)
        XCTAssertEqual(v.offset.x, offsetAtMin.x, accuracy: 1e-9)
        XCTAssertEqual(v.offset.y, offsetAtMin.y, accuracy: 1e-9)
    }

    func testSetScalePreservesMapPointUnderAnchor() {
        var v = CanvasViewport()
        v.pan(by: Point2D(x: 40, y: -15))
        let before = mapUnderAnchor(v)
        v.setScale(2, anchorView: anchor, viewWidth: w, viewHeight: h)
        XCTAssertEqual(mapUnderAnchor(v).x, before.x, accuracy: 1e-9)
        XCTAssertEqual(mapUnderAnchor(v).y, before.y, accuracy: 1e-9)
        let afterSet = mapUnderAnchor(v)
        v.zoomByStepping(.in, anchorView: anchor, viewWidth: w, viewHeight: h)
        XCTAssertEqual(mapUnderAnchor(v).x, afterSet.x, accuracy: 1e-9)
        XCTAssertEqual(mapUnderAnchor(v).y, afterSet.y, accuracy: 1e-9)
        let afterIn = mapUnderAnchor(v)
        v.zoomByStepping(.out, anchorView: anchor, viewWidth: w, viewHeight: h)
        XCTAssertEqual(mapUnderAnchor(v).x, afterIn.x, accuracy: 1e-9)
        XCTAssertEqual(mapUnderAnchor(v).y, afterIn.y, accuracy: 1e-9)
    }

    func testResetToActualSizePreservesAnchor() {
        var v = CanvasViewport()
        v.setScale(2.5, anchorView: anchor, viewWidth: w, viewHeight: h)
        XCTAssertFalse(v.isActualSize)
        let before = mapUnderAnchor(v)
        v.resetToActualSize(anchorView: anchor, viewWidth: w, viewHeight: h)
        XCTAssertEqual(v.scale, 1, accuracy: 1e-12)
        XCTAssertTrue(v.isActualSize)
        XCTAssertEqual(mapUnderAnchor(v).x, before.x, accuracy: 1e-9)
        XCTAssertEqual(mapUnderAnchor(v).y, before.y, accuracy: 1e-9)
    }

    func testPanDoesNotChangeScale() {
        var v = CanvasViewport()
        v.zoomByStepping(.in, anchorView: anchor, viewWidth: w, viewHeight: h)
        let s = v.scale
        let before = v.offset
        v.pan(by: Point2D(x: 10, y: 20))
        XCTAssertEqual(v.scale, s)
        XCTAssertEqual(v.offset.x, before.x + 10, accuracy: 1e-12)
        XCTAssertEqual(v.offset.y, before.y + 20, accuracy: 1e-12)
    }

    func testEmptyViewSizeChangesScaleOnly() {
        var v = CanvasViewport()
        v.pan(by: Point2D(x: 5, y: 6))
        v.setScale(2, anchorView: anchor, viewWidth: 0, viewHeight: 0)
        XCTAssertEqual(v.scale, 2)
        XCTAssertEqual(v.offset, Point2D(x: 5, y: 6))
        v.zoomByStepping(.in, anchorView: anchor, viewWidth: 0, viewHeight: h)
        XCTAssertEqual(v.scale, 2.5, accuracy: 1e-12)
        XCTAssertEqual(v.offset, Point2D(x: 5, y: 6))
    }

    func testCommandAnchor() {
        let hover = Point2D(x: 10, y: 20)
        XCTAssertEqual(
            CanvasViewport.commandAnchor(
                pointerOverCanvas: true, lastAnchorView: hover, viewWidth: w, viewHeight: h
            ),
            hover
        )
        XCTAssertEqual(
            CanvasViewport.commandAnchor(
                pointerOverCanvas: false, lastAnchorView: hover, viewWidth: w, viewHeight: h
            ),
            Point2D(x: w / 2, y: h / 2)
        )
        XCTAssertEqual(
            CanvasViewport.commandAnchor(
                pointerOverCanvas: true, lastAnchorView: nil, viewWidth: w, viewHeight: h
            ),
            Point2D(x: w / 2, y: h / 2)
        )
    }
}
