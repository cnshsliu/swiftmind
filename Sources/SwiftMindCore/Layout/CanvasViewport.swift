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
}
