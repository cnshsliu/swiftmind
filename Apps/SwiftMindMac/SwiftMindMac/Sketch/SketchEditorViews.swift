import AppKit
import PencilKit
import SwiftUI
import SwiftMindCore

// MARK: - Event-monitor guard

/// State readable from the AppKit NSEvent monitors (which cannot see SwiftUI
/// @State). Only touched on the main thread; intentionally non-actor.
enum SketchEventGuard {
    static let canvasIdentifier = "sketchEditorCanvas"

    /// True while the in-place sketch editor owns input.
    static var editorIsActive = false

    /// Session of the key window's document (set by AppModel). Key-down
    /// monitors are installed per window — only the active session's
    /// monitor may eat keys; background windows' monitors pass through.
    static weak var activeSession: DocumentSession?

    static func isWithinEditor(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let candidate = current {
            if candidate.identifier?.rawValue == canvasIdentifier { return true }
            current = candidate.superview
        }
        return false
    }
}

// MARK: - Tool model

enum SketchTool: String, CaseIterable {
    case pen
    case eraser
    case line
    case arrow
    case rect
    case ellipse
    case select

    var icon: String {
        switch self {
        case .pen: return "pencil.tip"
        case .eraser: return "eraser"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .rect: return "rectangle"
        case .ellipse: return "circle"
        case .select: return "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left"
        }
    }

    var isShape: Bool {
        switch self {
        case .line, .arrow, .rect, .ellipse: return true
        default: return false
        }
    }
}

/// In-place sketch editor: a large borderless board plus a compact tool strip.
/// Native macOS PencilKit ships only the data model (PKCanvasView is
/// iOS/Catalyst-only), so strokes are captured with SwiftUI gestures and
/// written into a PKDrawing — the exact payload the iOS port will hand to a
/// real PKCanvasView. Trim/normalize/commit live in SketchSupport.
///
/// Coordinate contract: strokes ALWAYS live in content coordinates (the
/// committed payload's space) — the editor never rewrites stroke geometry.
/// Fitting the content into the board is a view-only transform computed once
/// per session, so the board is steady and reopening always shows every
/// stroke; commit (trim) therefore always contains all strokes.
struct SketchEditorView: View {
    @Binding var drawingData: Data
    @Binding var tool: SketchTool
    @Binding var inkColor: NSColor
    /// Pen/shape stroke width in content points.
    @Binding var inkWidth: CGFloat
    /// Called after every committed stroke/erase (drives the debounced commit).
    let onStrokeChange: () -> Void
    let onDone: () -> Void

    @State private var drawing = PKDrawing()
    @State private var livePoints: [CGPoint] = []
    /// Shape-tool drag in board points (start + current); nil while idle.
    @State private var shapeDrag: (start: CGPoint, current: CGPoint)?
    /// Indices of selected strokes (select tool).
    @State private var selectedIndices: Set<Int> = []
    /// Select-tool drag: nil = tap-pending, else (start, current) in content space.
    @State private var selectDrag: (start: CGPoint, current: CGPoint)?
    @State private var undoStack: [PKDrawing] = []
    @State private var redoStack: [PKDrawing] = []
    /// Drag-start snapshot for the erase gesture (one undo step per erase drag).
    @State private var eraseSnapshot: PKDrawing?
    /// Last payload we wrote to the binding — distinguishes our own echoes
    /// from external model changes (byte-stable, unlike dataRepresentation()).
    @State private var lastSyncedData: Data?
    /// View-only fit: board-sized rect in content space, fixed per session.
    @State private var contentRect = CGRect.zero
    @State private var fitScale: CGFloat = 1
    @State private var fitComputed = false
    /// Laid-out board size, captured from the GeometryReader so fit can be
    /// (re)computed from `load` regardless of onAppear ordering.
    @State private var boardSize: CGSize = .zero

    private static let eraserRadius: CGFloat = 8
    static let widths: [CGFloat] = [1.5, 3, 6]
    private static let toolbarHeight: CGFloat = 36
    /// Content-space margin kept around existing strokes when fitting.
    private static let fitPadding: CGFloat = 24

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            board
        }
        .onAppear { load(drawingData) }
        .onKeyPress { press in
            guard press.modifiers.subtracting(.shift).intersection([.command, .option, .control]).isEmpty
                    || press.modifiers == .command else {
                return .ignored
            }
            if press.characters == "z", press.modifiers.contains(.command) {
                if press.modifiers.contains(.shift) { redo() } else { undo() }
                return .handled
            }
            if press.key == .delete, tool == .select, !selectedIndices.isEmpty {
                deleteSelection()
                return .handled
            }
            return .ignored
        }
        .onChange(of: drawingData) { _, newData in
            // External model change (undo, agent) — reload unless it echoes us.
            guard newData != lastSyncedData else { return }
            load(newData)
        }
    }

    private func load(_ data: Data) {
        drawing = (try? PKDrawing(data: data)) ?? PKDrawing()
        lastSyncedData = data
        undoStack.removeAll()
        redoStack.removeAll()
        fitComputed = false
        computeFitIfNeeded()
    }

    // MARK: Board

    private var board: some View {
        GeometryReader { geo in
            ZStack {
                if fitComputed {
                    CommittedStrokesImage(drawing: drawing, rect: contentRect)
                }
                if tool == .pen, !livePoints.isEmpty {
                    StrokePreview(
                        points: livePoints,
                        color: Color(nsColor: inkColor),
                        width: inkWidth * fitScale
                    )
                }
                if let drag = shapeDrag, tool.isShape {
                    ShapePreview(
                        tool: tool,
                        start: drag.start,
                        end: drag.current,
                        color: Color(nsColor: inkColor),
                        width: inkWidth * fitScale
                    )
                }
                if tool == .select, !selectedIndices.isEmpty, fitComputed {
                    selectionChrome
                }
                if let drag = selectDrag, tool == .select {
                    Rectangle()
                        .strokeBorder(Color.accentColor.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .frame(width: abs(drag.current.x - drag.start.x) * fitScale,
                               height: abs(drag.current.y - drag.start.y) * fitScale)
                        .position(
                            x: (drag.start.x + drag.current.x) / 2 * fitScale
                                - (contentRect.minX * fitScale),
                            y: (drag.start.y + drag.current.y) / 2 * fitScale
                                - (contentRect.minY * fitScale)
                        )
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .overlay {
                SketchRightPanCatcher { delta in
                    panBoard(by: delta)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        handleDrag(value.location, phase: .changed)
                    }
                    .onEnded { value in
                        handleDrag(value.location, phase: .ended)
                    }
            )
            .onAppear {
                boardSize = geo.size
                computeFitIfNeeded()
            }
            .onChange(of: geo.size) { _, newSize in
                boardSize = newSize
                computeFitIfNeeded()
            }
        }
    }

    /// Fit the existing content into the board — once per session (or after an
    /// external reload), so the board never shifts under the pen. Never
    /// upscales: tiny content shows 1:1 centered in a board-sized content rect.
    private func computeFitIfNeeded() {
        guard !fitComputed, boardSize.width > 40, boardSize.height > 40 else { return }
        let bounds = drawing.bounds
        if drawing.strokes.isEmpty || bounds.isNull || bounds.isEmpty || bounds.isInfinite {
            fitScale = 1
            contentRect = CGRect(origin: .zero, size: boardSize)
        } else {
            let w = bounds.width + Self.fitPadding * 2
            let h = bounds.height + Self.fitPadding * 2
            let scale = min(1, boardSize.width / w, boardSize.height / h)
            fitScale = scale
            contentRect = CGRect(
                x: bounds.midX - boardSize.width / (2 * scale),
                y: bounds.midY - boardSize.height / (2 * scale),
                width: boardSize.width / scale,
                height: boardSize.height / scale
            )
        }
        fitComputed = true
    }

    /// Right-drag (and, later, a two-finger pan) moves the paper. `delta` is
    /// in board points, y down. Strokes stay in content space.
    private func panBoard(by delta: CGSize) {
        guard fitComputed, fitScale > 0 else { return }
        contentRect.origin.x -= delta.width / fitScale
        contentRect.origin.y -= delta.height / fitScale
    }

    /// Board (gesture) point → content (stroke) point.
    private func contentPoint(_ boardPoint: CGPoint) -> CGPoint {
        CGPoint(
            x: boardPoint.x / fitScale + contentRect.minX,
            y: boardPoint.y / fitScale + contentRect.minY
        )
    }

    private enum DragPhase { case changed, ended }

    private func handleDrag(_ location: CGPoint, phase: DragPhase) {
        if tool.isShape {
            guard fitComputed else { return }
            switch phase {
            case .changed:
                if shapeDrag == nil { shapeDrag = (start: location, current: location) }
                else { shapeDrag?.current = location }
            case .ended:
                shapeDrag?.current = location
                commitShapeStroke()
            }
            return
        }
        if tool == .select {
            guard fitComputed else { return }
            let content = contentPoint(location)
            switch phase {
            case .changed:
                if selectDrag == nil {
                    selectDrag = (start: content, current: content)
                    // Dragging FROM a selected stroke moves it; otherwise marquee.
                    draggingSelection = hitSelected(at: content)
                    if draggingSelection { pushUndo() }
                } else if draggingSelection {
                    guard var drag = selectDrag else { return }
                    drag.current = content
                    let delta = CGPoint(
                        x: drag.current.x - selectDrag!.current.x,
                        y: drag.current.y - selectDrag!.current.y
                    )
                    moveSelected(by: delta)
                    selectDrag?.current = content
                    movedOnce = true
                } else {
                    selectDrag?.current = content
                }
            case .ended:
                defer {
                    selectDrag = nil
                    draggingSelection = false
                    movedOnce = false
                }
                guard var drag = selectDrag else { return }
                drag.current = content
                let moved = hypot(drag.current.x - drag.start.x, drag.current.y - drag.start.y)
                if moved < 4 {
                    tapSelect(at: drag.start)
                } else if !movedOnce {
                    marqueeSelect(from: drag.start, to: drag.current)
                }
                if movedOnce { syncToModel() }
            }
            return
        }
        switch tool {
        case .pen:
            // Record raw board points even before the fit lands (first frames
            // of a session) — conversion happens at stroke commit, when the
            // fit is necessarily computed. Gating input on the fit race
            // dropped whole drags on slow layouts.
            livePoints.append(location)
            if phase == .ended { commitPenStroke() }
        case .eraser:
            guard fitComputed else { return }
            if phase == .changed {
                if eraseSnapshot == nil { eraseSnapshot = drawing }
                eraseStrokes(near: contentPoint(location))
            } else {
                finishErase()
            }
        default:
            break
        }
    }

    /// True once a select-drag began ON a selected stroke (move gesture);
    /// false while it is a marquee (fresh selection).
    @State private var draggingSelection = false
    @State private var movedOnce = false

    private func commitPenStroke() {
        defer { livePoints.removeAll() }
        let points = livePoints
        computeFitIfNeeded() // last chance: the drag hit the board, so it exists
        guard points.count > 1, fitComputed else { return }
        pushUndo()
        let now = Date().timeIntervalSinceReferenceDate
        let strokePoints = points.map { boardPoint in
            PKStrokePoint(
                location: contentPoint(boardPoint),
                timeOffset: now,
                size: CGSize(width: inkWidth, height: inkWidth),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            )
        }
        let path = PKStrokePath(controlPoints: strokePoints, creationDate: Date())
        drawing.strokes.append(PKStroke(ink: PKInk(.pen, color: inkColor), path: path))
        syncToModel()
    }

    /// Commit the shape drag as one PKStroke in content coordinates.
    private func commitShapeStroke() {
        defer { shapeDrag = nil }
        guard let drag = shapeDrag else { return }
        let a = contentPoint(drag.start)
        let b = contentPoint(drag.current)
        guard hypot(b.x - a.x, b.y - a.y) > 3 else { return }
        pushUndo()
        let now = Date().timeIntervalSinceReferenceDate
        func point(_ p: CGPoint) -> PKStrokePoint {
            PKStrokePoint(location: p, timeOffset: now,
                          size: CGSize(width: inkWidth, height: inkWidth),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        var pts: [PKStrokePoint]
        switch tool {
        case .line, .arrow:
            pts = [point(a), point(b)]
        case .rect:
            let c = CGPoint(x: a.x, y: b.y), d = CGPoint(x: b.x, y: a.y)
            pts = [point(a), point(d), point(b), point(c), point(a)]
        case .ellipse:
            let mx = (a.x + b.x) / 2, my = (a.y + b.y) / 2
            let rx = abs(b.x - a.x) / 2, ry = abs(b.y - a.y) / 2
            // 8 control points around the ellipse (PKStrokePath interpolates).
            var ring: [PKStrokePoint] = []
            for i in 0...8 {
                let t = CGFloat(i) / 8 * 2 * .pi
                ring.append(point(CGPoint(x: mx + rx * cos(t), y: my + ry * sin(t))))
            }
            pts = ring
        default:
            pts = [point(a), point(b)]
        }
        let path = PKStrokePath(controlPoints: pts, creationDate: Date())
        drawing.strokes.append(PKStroke(ink: PKInk(.pen, color: inkColor), path: path))
        // Arrowhead: two short strokes at the tip.
        if tool == .arrow {
            let angle = atan2(b.y - a.y, b.x - a.x)
            let head: CGFloat = max(10, inkWidth * 4)
            for sign in [CGFloat.pi * 0.82, -CGFloat.pi * 0.82] {
                let tip = CGPoint(
                    x: b.x + head * cos(angle + sign),
                    y: b.y + head * sin(angle + sign)
                )
                let hp = [point(b), point(tip)]
                drawing.strokes.append(PKStroke(
                    ink: PKInk(.pen, color: inkColor),
                    path: PKStrokePath(controlPoints: hp, creationDate: Date())
                ))
            }
        }
        syncToModel()
    }

    /// Bounds of one stroke in content space (PKStroke exposes no bounds).
    private static func bounds(of stroke: PKStroke) -> CGRect {
        var rect: CGRect?
        for point in stroke.path.interpolatedPoints(in: nil, by: .distance(8)) {
            let p = point.location
            if rect == nil { rect = CGRect(origin: p, size: .zero) }
            else { rect = rect!.union(CGRect(origin: p, size: .zero)) }
        }
        return rect ?? .null
    }

    /// Tap with the select tool: pick the topmost stroke under the point.
    private func tapSelect(at content: CGPoint) {
        var best: (index: Int, dist: CGFloat)?
        for (index, stroke) in drawing.strokes.enumerated() {
            let b = Self.bounds(of: stroke)
            guard !b.isNull else { continue }
            let pad: CGFloat = 6
            guard content.x >= b.minX - pad, content.x <= b.maxX + pad,
                  content.y >= b.minY - pad, content.y <= b.maxY + pad else { continue }
            let center = CGPoint(x: b.midX, y: b.midY)
            let dist = hypot(content.x - center.x, content.y - center.y)
            if best == nil || dist < best!.dist { best = (index, dist) }
        }
        selectedIndices = best.map { [$0.index] } ?? []
    }

    /// True when a content point sits inside a selected stroke's bounds.
    private func hitSelected(at content: CGPoint) -> Bool {
        selectedIndices.contains { index in
            guard index < drawing.strokes.count else { return false }
            let b = Self.bounds(of: drawing.strokes[index])
            return !b.isNull
                && content.x >= b.minX - 6 && content.x <= b.maxX + 6
                && content.y >= b.minY - 6 && content.y <= b.maxY + 6
        }
    }

    /// Marquee: select every stroke whose bounds intersect the drag rect.
    private func marqueeSelect(from a: CGPoint, to b: CGPoint) {
        let rect = CGRect(
            x: min(a.x, b.x), y: min(a.y, b.y),
            width: abs(b.x - a.x), height: abs(b.y - a.y)
        )
        selectedIndices = Set(drawing.strokes.indices.filter { index in
            let bounds = Self.bounds(of: drawing.strokes[index])
            return !bounds.isNull && bounds.insetBy(dx: -4, dy: -4).intersects(rect)
        })
    }

    /// Move the selected strokes by a content-space delta (no undo push —
    /// the caller pushes once at drag start).
    private func moveSelected(by delta: CGPoint) {
        guard !selectedIndices.isEmpty else { return }
        drawing.strokes = drawing.strokes.enumerated().map { index, stroke in
            guard selectedIndices.contains(index) else { return stroke }
            let moved = stroke.path.interpolatedPoints(in: nil, by: .distance(4)).map { pt in
                PKStrokePoint(
                    location: CGPoint(x: pt.location.x + delta.x, y: pt.location.y + delta.y),
                    timeOffset: pt.timeOffset,
                    size: pt.size,
                    opacity: pt.opacity,
                    force: pt.force,
                    azimuth: pt.azimuth,
                    altitude: pt.altitude
                )
            }
            let path = moved.count > 1
                ? PKStrokePath(controlPoints: moved, creationDate: Date())
                : stroke.path
            return PKStroke(ink: stroke.ink, path: path)
        }
    }

    /// Delete the selected strokes (one undo step).
    private func deleteSelection() {
        guard !selectedIndices.isEmpty else { return }
        pushUndo()
        drawing.strokes = drawing.strokes.enumerated()
            .filter { !selectedIndices.contains($0.offset) }
            .map(\.element)
        selectedIndices.removeAll()
        syncToModel()
    }

    /// Bounding box chrome around the selected strokes (content → board).
    @ViewBuilder
    private var selectionChrome: some View {
        let boxes = selectedIndices.compactMap { index -> CGRect? in
            guard index < drawing.strokes.count else { return nil }
            let b = Self.bounds(of: drawing.strokes[index])
            return b.isNull ? nil : b
        }
        if let union = boxes.dropFirst().reduce(boxes.first, { acc, next in
            acc.map { $0.union(next) } ?? next
        }) {
            Rectangle()
                .strokeBorder(Color.accentColor.opacity(0.9),
                              style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                .frame(width: union.width * fitScale + 8,
                       height: union.height * fitScale + 8)
                .position(
                    x: (union.midX - contentRect.minX) * fitScale,
                    y: (union.midY - contentRect.minY) * fitScale
                )
        }
    }

    /// Stroke eraser: removes any stroke passing near the pointer.
    private func eraseStrokes(near location: CGPoint) {
        let radius = Self.eraserRadius / fitScale
        let kept = drawing.strokes.filter { stroke in
            !stroke.path.interpolatedPoints(in: nil, by: .distance(radius)).contains { point in
                abs(point.location.x - location.x) < radius
                    && abs(point.location.y - location.y) < radius
            }
        }
        if kept.count != drawing.strokes.count {
            drawing.strokes = kept
            syncToModel()
        }
    }

    private func finishErase() {
        eraseSnapshot = nil
    }

    // MARK: Model sync / undo

    private func pushUndo() {
        undoStack.append(drawing)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func syncToModel() {
        let data = drawing.dataRepresentation()
        lastSyncedData = data
        drawingData = data
        onStrokeChange()
    }

    private func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(drawing)
        drawing = previous
        syncToModel()
    }

    private func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(drawing)
        drawing = next
        syncToModel()
    }

    private func clear() {
        guard !drawing.strokes.isEmpty else { return }
        pushUndo()
        drawing = PKDrawing()
        syncToModel()
    }

    // MARK: Toolbar (PKToolPicker is UIKit-only; custom chrome is cross-platform)

    private var toolbar: some View {
        HStack(spacing: 10) {
            ForEach(SketchTool.allCases, id: \.self) { candidate in
                Button {
                    tool = candidate
                } label: {
                    Image(systemName: candidate.icon)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(tool == candidate ? Color.accentColor : Color.secondary)
                .accessibilityIdentifier(candidate == .pen ? "sketchToolPen" : "sketchToolEraser")
            }

            Divider().frame(height: 14)

            ForEach(Array(Self.widths.enumerated()), id: \.offset) { _, width in
                Button {
                    inkWidth = width
                } label: {
                    Circle()
                        .fill(Color.primary.opacity(0.75))
                        .frame(width: 4 + width, height: 4 + width)
                        .overlay(
                            Circle().strokeBorder(
                                inkWidth == width ? Color.accentColor : Color.clear,
                                lineWidth: 2
                            )
                    )
                }
                .buttonStyle(.borderless)
                .help("Stroke width")
            }

            Divider().frame(height: 14)

            ForEach(Array(Self.inks.enumerated()), id: \.offset) { _, ink in
                Button {
                    tool = .pen
                    inkColor = ink
                } label: {
                    Circle()
                        .fill(Color(nsColor: ink))
                        .frame(width: 12, height: 12)
                        .overlay(
                            Circle().strokeBorder(
                                inkColor == ink ? Color.accentColor : Color.clear,
                                lineWidth: 2
                            )
                        )
                }
                .buttonStyle(.borderless)
            }

            Divider().frame(height: 14)

            Button(action: undo) {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .disabled(undoStack.isEmpty)
            .accessibilityIdentifier("sketchUndo")

            Button(action: redo) {
                Image(systemName: "arrow.uturn.forward")
            }
            .buttonStyle(.borderless)
            .disabled(redoStack.isEmpty)

            Button(action: clear) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("sketchClear")

            Spacer(minLength: 0)

            Button("Done", action: onDone)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(height: Self.toolbarHeight)
    }

    private static let inks: [NSColor] = [.black, .darkGray, .white, .systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue]
}

// MARK: - Rendering pieces

/// Committed strokes rasterized through PencilKit (identical ink rendering on
/// macOS and iOS) from the session's fixed content rect — the board never
/// reframes, so strokes stay put while drawing. Isolated in its own view so
/// live-preview updates do not re-rasterize.
private struct CommittedStrokesImage: View {
    let drawing: PKDrawing
    let rect: CGRect

    var body: some View {
        Image(
            nsImage: drawing.image(
                from: rect.width > 0 && rect.height > 0 ? rect : CGRect(x: 0, y: 0, width: 1, height: 1),
                scale: 2
            )
        )
        .resizable()
    }
}

/// Right-mouse pan catcher. Left clicks pass through so the pen and eraser
/// still draw. A later two-finger pan calls the same delta callback.
private struct SketchRightPanCatcher: NSViewRepresentable {
    var onPan: (CGSize) -> Void

    func makeNSView(context: Context) -> RightPanView {
        let view = RightPanView()
        view.onPan = onPan
        return view
    }

    func updateNSView(_ view: RightPanView, context: Context) {
        view.onPan = onPan
    }

    final class RightPanView: NSView {
        var onPan: ((CGSize) -> Void)?
        private var last: CGPoint = .zero

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            switch event.type {
            case .rightMouseDown, .rightMouseDragged, .rightMouseUp:
                return super.hitTest(point)
            default:
                return nil
            }
        }

        override func rightMouseDown(with event: NSEvent) {
            last = convert(event.locationInWindow, from: nil)
        }

        override func rightMouseDragged(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            // AppKit y grows up; the board's y grows down.
            let delta = CGSize(width: point.x - last.x, height: last.y - point.y)
            last = point
            onPan?(delta)
        }

        override func rightMouseUp(with event: NSEvent) {}
    }
}

/// In-progress pen stroke (approximates the committed PencilKit stroke).
/// Live drag preview for the shape tools (board coordinates).
private struct ShapePreview: View {
    let tool: SketchTool
    let start: CGPoint
    let end: CGPoint
    let color: Color
    var width: CGFloat = 3

    private var rect: CGRect {
        CGRect(
            x: min(start.x, end.x), y: min(start.y, end.y),
            width: abs(end.x - start.x), height: abs(end.y - start.y)
        )
    }

    var body: some View {
        switch tool {
        case .line, .arrow:
            Path { path in
                path.move(to: start)
                path.addLine(to: end)
            }
            .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round))
        case .rect:
            Path(rect)
                .stroke(color, style: StrokeStyle(lineWidth: width, lineJoin: .round))
        case .ellipse:
            Path(ellipseIn: rect)
                .stroke(color, style: StrokeStyle(lineWidth: width))
        default:
            EmptyView()
        }
    }
}

private struct StrokePreview: View {
    let points: [CGPoint]
    let color: Color
    var width: CGFloat = 3

    var body: some View {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
        }
        .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }
}
