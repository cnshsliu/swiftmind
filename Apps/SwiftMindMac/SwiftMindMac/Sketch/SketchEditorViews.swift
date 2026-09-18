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
struct SketchEditorView: View {
    @Binding var drawingData: Data
    @Binding var tool: SketchTool
    @Binding var inkColor: NSColor
    /// Called after every committed stroke/erase (drives the debounced commit).
    let onStrokeChange: () -> Void
    /// Auto-grow: stroke bounds (board coordinates) after each change.
    let onBoundsChange: (CGRect) -> Void
    let onDone: () -> Void

    @State private var drawing = PKDrawing()
    @State private var livePoints: [CGPoint] = []
    @State private var undoStack: [PKDrawing] = []
    @State private var redoStack: [PKDrawing] = []
    /// Drag-start snapshot for the erase gesture (one undo step per erase drag).
    @State private var eraseSnapshot: PKDrawing?
    @State private var loadedInitialDraft = false

    private static let strokeWidth: CGFloat = 3
    private static let eraserRadius: CGFloat = 8
    private static let toolbarHeight: CGFloat = 36

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            board
        }
        .onAppear {
            drawing = (try? PKDrawing(data: drawingData)) ?? PKDrawing()
            loadedInitialDraft = true
        }
        .onChange(of: drawingData) { _, newData in
            // External model change (undo, agent) — reload unless it echoes us.
            guard drawing.dataRepresentation() != newData else { return }
            drawing = (try? PKDrawing(data: newData)) ?? PKDrawing()
            undoStack.removeAll()
            redoStack.removeAll()
        }
    }

    // MARK: Board

    private var board: some View {
        GeometryReader { geo in
            ZStack {
                CommittedStrokesImage(drawing: drawing, size: geo.size)
                if tool == .pen, !livePoints.isEmpty {
                    StrokePreview(points: livePoints, color: Color(nsColor: inkColor))
                }
            }
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
        }
    }

    private enum DragPhase { case changed, ended }

    private func handleDrag(_ location: CGPoint, phase: DragPhase) {
        switch tool {
        case .pen:
            livePoints.append(location)
            if phase == .ended { commitPenStroke() }
        case .eraser:
            if phase == .changed {
                if eraseSnapshot == nil { eraseSnapshot = drawing }
                eraseStrokes(near: location)
            } else {
                finishErase()
            }
        }
    }

    private func commitPenStroke() {
        defer { livePoints.removeAll() }
        let points = livePoints
        guard points.count > 1 else { return }
        pushUndo()
        let now = Date().timeIntervalSinceReferenceDate
        let strokePoints = points.map { point in
            PKStrokePoint(
                location: point,
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
        let radius = Self.eraserRadius
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
        drawingData = drawing.dataRepresentation()
        onStrokeChange()
        onBoundsChange(drawing.bounds)
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
/// macOS and iOS). Isolated in its own view so live-preview updates do not
/// re-rasterize.
private struct CommittedStrokesImage: View {
    let drawing: PKDrawing
    let size: CGSize

    var body: some View {
        Image(
            nsImage: drawing.image(
                from: CGRect(origin: .zero, size: size.width > 0 && size.height > 0 ? size : CGSize(width: 1, height: 1)),
                scale: 2
            )
        )
    }
}

/// In-progress pen stroke (approximates the committed PencilKit stroke).
private struct StrokePreview: View {
    let points: [CGPoint]
    let color: Color

    var body: some View {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
        }
        .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
    }
}
