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

    var icon: String {
        switch self {
        case .pen: return "pencil.tip"
        case .eraser: return "eraser"
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
    /// Called after every committed stroke/erase (drives the debounced commit).
    let onStrokeChange: () -> Void
    let onDone: () -> Void

    @State private var drawing = PKDrawing()
    @State private var livePoints: [CGPoint] = []
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

    private static let strokeWidth: CGFloat = 3
    private static let eraserRadius: CGFloat = 8
    private static let toolbarHeight: CGFloat = 36
    /// Content-space margin kept around existing strokes when fitting.
    private static let fitPadding: CGFloat = 24

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            board
        }
        .onAppear { load(drawingData) }
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
                        width: Self.strokeWidth * fitScale
                    )
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
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

    /// Board (gesture) point → content (stroke) point.
    private func contentPoint(_ boardPoint: CGPoint) -> CGPoint {
        CGPoint(
            x: boardPoint.x / fitScale + contentRect.minX,
            y: boardPoint.y / fitScale + contentRect.minY
        )
    }

    private enum DragPhase { case changed, ended }

    private func handleDrag(_ location: CGPoint, phase: DragPhase) {
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
        }
    }

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
                size: CGSize(width: Self.strokeWidth, height: Self.strokeWidth),
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

    private static let inks: [NSColor] = [.black, .systemRed, .systemBlue]
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

/// In-progress pen stroke (approximates the committed PencilKit stroke).
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
