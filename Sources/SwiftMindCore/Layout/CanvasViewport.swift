import Foundation

public enum ZoomStep: Sendable {
    case `in`
    case `out`
}

public struct CanvasViewport: Equatable, Sendable {
    public static let minScale = 0.25
    public static let maxScale = 3.0
    public static let stepFactor = 1.25

    public var scale: Double
    public var offset: Point2D

    public init(scale: Double = 1, offset: Point2D = .zero) {
        self.scale = Self.clamped(scale)
        self.offset = offset
    }

    public var isAtMinScale: Bool { scale <= Self.minScale + 1e-12 }
    public var isAtMaxScale: Bool { scale >= Self.maxScale - 1e-12 }
    public var isActualSize: Bool { abs(scale - 1) < 1e-9 }

    public static func clamped(_ scale: Double) -> Double {
        min(maxScale, max(minScale, scale))
    }

    public func mapPoint(fromView p: Point2D, viewWidth: Double, viewHeight: Double) -> Point2D {
        let s = scale == 0 ? 1 : scale
        return Point2D(
            x: (p.x - viewWidth / 2 - offset.x) / s,
            y: (p.y - viewHeight / 2 - offset.y) / s
        )
    }

    public static func commandAnchor(
        pointerOverCanvas: Bool,
        lastAnchorView: Point2D?,
        viewWidth: Double,
        viewHeight: Double
    ) -> Point2D {
        if pointerOverCanvas, let lastAnchorView {
            return lastAnchorView
        }
        return Point2D(x: viewWidth / 2, y: viewHeight / 2)
    }

    public mutating func setScale(
        _ new: Double,
        anchorView: Point2D,
        viewWidth: Double,
        viewHeight: Double
    ) {
        let clamped = Self.clamped(new)
        if viewWidth <= 0 || viewHeight <= 0 {
            scale = clamped
            return
        }
        let map = mapPoint(fromView: anchorView, viewWidth: viewWidth, viewHeight: viewHeight)
        scale = clamped
        offset = Point2D(
            x: anchorView.x - viewWidth / 2 - map.x * scale,
            y: anchorView.y - viewHeight / 2 - map.y * scale
        )
    }

    public mutating func zoomByStepping(
        _ direction: ZoomStep,
        anchorView: Point2D,
        viewWidth: Double,
        viewHeight: Double
    ) {
        let next: Double
        switch direction {
        case .in: next = scale * Self.stepFactor
        case .out: next = scale / Self.stepFactor
        }
        setScale(next, anchorView: anchorView, viewWidth: viewWidth, viewHeight: viewHeight)
    }

    public mutating func resetToActualSize(
        anchorView: Point2D,
        viewWidth: Double,
        viewHeight: Double
    ) {
        setScale(1, anchorView: anchorView, viewWidth: viewWidth, viewHeight: viewHeight)
    }

    public mutating func pan(by delta: Point2D) {
        offset = Point2D(x: offset.x + delta.x, y: offset.y + delta.y)
    }

    /// Offset clamped so the content always keeps a visible strip on screen:
    /// the scaled content bounding box must intersect the viewport inset by
    /// 25% per axis. This is the interactive pan limit shared by dragging and
    /// scrolling — free inside the envelope, hard stop at the boundary.
    /// Zoom-aware because the bounds are scaled before comparison.
    public func visibleClampedOffset(
        contentBounds: Rect2D,
        viewWidth: Double,
        viewHeight: Double
    ) -> Point2D {
        let mx = viewWidth * 0.25
        let my = viewHeight * 0.25
        guard viewWidth > mx * 2, viewHeight > my * 2, scale > 0 else {
            return offset
        }
        // Content bbox in view coordinates: p_view = p_map*scale + viewSize/2 + offset;
        // it must overlap [margin, viewSize - margin] on each axis.
        let minXv = contentBounds.x * scale + viewWidth / 2
        let maxXv = (contentBounds.x + contentBounds.width) * scale + viewWidth / 2
        let minYv = contentBounds.y * scale + viewHeight / 2
        let maxYv = (contentBounds.y + contentBounds.height) * scale + viewHeight / 2
        return Point2D(
            x: min(viewWidth - mx - minXv, max(mx - maxXv, offset.x)),
            y: min(viewHeight - my - minYv, max(my - maxYv, offset.y))
        )
    }

    /// Offset clamped so the content cannot be stranded entirely offscreen.
    ///
    /// Defense against pathological pan/zoom input (a single glitched drag
    /// event, or a poisoned viewport restored from saved preferences): the
    /// center of the content bounding box — or, for content larger than the
    /// view, the center region sized to the view — must stay on screen.
    /// Normal panning/zooming never hits the limit.
    public func clampedOffset(
        contentBounds: Rect2D,
        viewWidth: Double,
        viewHeight: Double,
        margin: Double = 80
    ) -> Point2D {
        guard viewWidth > margin * 2, viewHeight > margin * 2, scale > 0 else {
            return offset
        }
        // View position of the content center = center*scale + viewSize/2 + offset;
        // it must land inside [margin, viewSize - margin].
        let cx = contentBounds.midX * scale + viewWidth / 2
        let cy = contentBounds.midY * scale + viewHeight / 2
        return Point2D(
            x: min(viewWidth - margin - cx, max(margin - cx, offset.x)),
            y: min(viewHeight - margin - cy, max(margin - cy, offset.y))
        )
    }
}
