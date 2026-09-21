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

    /// Viewport that shows the whole content centered in the view.
    /// Never zooms in past 1:1 (a map smaller than the view stays at actual
    /// size, centered) and never below `minScale`.
    public func fittedToContent(
        contentBounds: Rect2D,
        viewWidth: Double,
        viewHeight: Double,
        padding: Double = 48
    ) -> CanvasViewport {
        guard viewWidth > padding * 2, viewHeight > padding * 2,
              contentBounds.width > 0, contentBounds.height > 0 else { return self }
        let fit = min(
            (viewWidth - padding * 2) / contentBounds.width,
            (viewHeight - padding * 2) / contentBounds.height
        )
        let s = Self.clamped(min(1, fit))
        // p_view = p_map*scale + viewSize/2 + offset; offset that puts the
        // content center at the view center is -contentCenter*scale.
        return CanvasViewport(
            scale: s,
            offset: Point2D(x: -contentBounds.midX * s, y: -contentBounds.midY * s)
        )
    }

    /// Offset clamped so the viewport never shows blank space beyond the
    /// content — the natural scroll-view rule, per axis:
    ///
    /// - Content (scaled) **larger than the view**: the content bounding box
    ///   must *cover* the whole viewport — panning stops flush at the content
    ///   edge, so even at the extreme the screen is full of content.
    /// - Content **smaller than the view**: the bounding box stays *inside*
    ///   the viewport — the map can be positioned anywhere in the window but
    ///   can never be pushed out.
    ///
    /// Shared by dragging and scrolling; zoom-aware because the bounds are
    /// scaled before comparison.
    public func panClampedOffset(
        contentBounds: Rect2D,
        viewWidth: Double,
        viewHeight: Double
    ) -> Point2D {
        guard viewWidth > 0, viewHeight > 0, scale > 0 else { return offset }
        // Content bbox in view coordinates: p_view = p_map*scale + viewSize/2 + offset.
        // Per axis the two candidate limits are "max edge flush at view end"
        // and "min edge flush at view start"; the feasible interval is always
        // [min(a,b), max(a,b)] — covering when content ≥ view, inside when smaller.
        let ax = viewWidth - (contentBounds.x + contentBounds.width) * scale - viewWidth / 2
        let bx = -(contentBounds.x * scale + viewWidth / 2)
        let ay = viewHeight - (contentBounds.y + contentBounds.height) * scale - viewHeight / 2
        let by = -(contentBounds.y * scale + viewHeight / 2)
        return Point2D(
            x: min(max(ax, bx), max(min(ax, bx), offset.x)),
            y: min(max(ay, by), max(min(ay, by), offset.y))
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
