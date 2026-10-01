import AppKit
import PencilKit
import SwiftUI
import SwiftMindCore

// Shared with MapCanvasView's AppKit key monitor (board tool shortcuts).
extension Notification.Name {
    static let swiftMindSketchToolShortcut = Notification.Name("swiftMind.canvas.sketchToolShortcut")
    static let swiftMindSketchBoardCopy = Notification.Name("swiftMind.canvas.sketchBoardCopy")
    static let swiftMindSketchBoardPaste = Notification.Name("swiftMind.canvas.sketchBoardPaste")
}

// MARK: - Event-monitor guard

/// State readable from the AppKit NSEvent monitors (which cannot see SwiftUI
/// @State). Only touched on the main thread; intentionally non-actor.
enum SketchEventGuard {
    static let canvasIdentifier = "sketchEditorCanvas"

    /// True while the in-place sketch editor owns input.
    static var editorIsActive = false

    /// True while a TEXT session is open on the sketch board — keystrokes
    /// (especially "d") belong to the text field, never the canvas shortcuts.
    static var textEditingActive = false

    /// True while Space is physically held — event-tracked (keyDown/keyUp
    /// monitors in MapCanvasView); CGEventSource polling proved unreliable.
    static var spaceHeld = false

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
    case marker
    case eraser
    case line
    case arrow
    case rect
    case roundedRect
    case ellipse
    case triangle
    case diamond
    case star
    case bubble
    case text
    case select

    var icon: String {
        switch self {
        case .pen: return "pencil.tip"
        case .marker: return "highlighter"
        case .eraser: return "eraser"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .rect: return "rectangle"
        case .roundedRect: return "rectangle.rounded"
        case .ellipse: return "circle"
        case .triangle: return "triangle"
        case .diamond: return "diamond"
        case .star: return "star"
        case .bubble: return "bubble.left"
        case .text: return "character.cursor.ibeam"
        case .select: return "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left"
        }
    }

    /// Human title for the shapes menu.
    var title: String {
        switch self {
        case .pen: return "Pen"
        case .marker: return "Marker"
        case .eraser: return "Eraser"
        case .line: return "Line"
        case .arrow: return "Arrow"
        case .rect: return "Rectangle"
        case .roundedRect: return "Rounded Rectangle"
        case .ellipse: return "Ellipse"
        case .triangle: return "Triangle"
        case .diamond: return "Diamond"
        case .star: return "Star"
        case .bubble: return "Speech Bubble"
        case .text: return "Text"
        case .select: return "Select"
        }
    }

    var isShape: Bool {
        switch self {
        case .line, .arrow, .rect, .roundedRect, .ellipse, .triangle, .diamond, .star, .bubble:
            return true
        default:
            return false
        }
    }

    /// All shape tools, in menu order.
    static var shapes: [SketchTool] {
        [.line, .arrow, .rect, .roundedRect, .ellipse, .triangle, .diamond, .star, .bubble]
    }

    /// Geometry vocabulary for commit/preview; nil for non-shape tools.
    var shapeKind: ShapeGeometry.ShapeKind? {
        switch self {
        case .line: return .line
        case .arrow: return .arrow
        case .rect: return .rect
        case .roundedRect: return .roundedRect
        case .ellipse: return .ellipse
        case .triangle: return .triangle
        case .diamond: return .diamond
        case .star: return .star
        case .bubble: return .bubble
        default: return nil
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
    /// Text elements on the board (text boxes / sticky notes), content coords.
    @Binding var texts: [SketchText]
    /// Shape elements on the board (PPT-style), content coords.
    @Binding var shapes: [SketchShape]
    /// Image elements on the board, content coords.
    @Binding var images: [SketchImageElement]
    /// Board background hex ("#RRGGBB"); nil = system default.
    @Binding var boardBackground: String?
    @Binding var tool: SketchTool
    @Binding var inkColor: NSColor
    /// Pen/shape stroke width in content points.
    @Binding var inkWidth: CGFloat
    /// Called after every committed stroke/text/erase (drives the debounced commit).
    let onStrokeChange: () -> Void
    let onDone: () -> Void

    @State private var drawing = PKDrawing()
    /// In-progress pen/marker stroke, CONTENT points (recorded at arrival so
    /// auto-pan during the drag can never bend the stroke).
    @State private var livePoints: [CGPoint] = []
    /// Points captured before the fit landed (raw board points, converted at
    /// commit when the fit necessarily exists).
    @State private var liveRawPoints: [CGPoint] = []
    /// Shape-tool drag in CONTENT points (start + current); nil while idle.
    @State private var shapeDrag: (start: CGPoint, current: CGPoint)?
    /// Board-space pointer while a drawing drag is active (auto-pan reads it
    /// between drag events); nil while idle.
    @State private var dragPointer: CGPoint?
    /// Running edge auto-pan (see updateAutoPan).
    @State private var autoPanTask: Task<Void, Never>?
    /// Indices of selected strokes (select tool).
    @State private var selectedIndices: Set<Int> = []
    /// Ids of selected text elements (select tool).
    @State private var selectedTextIDs: Set<String> = []
    /// Ids of selected shape elements (select tool).
    @State private var selectedShapeIDs: Set<String> = []
    /// Ids of selected image elements (select tool).
    @State private var selectedImageIDs: Set<String> = []
    /// Select-tool drag: nil = tap-pending, else (start, current) in content space.
    @State private var selectDrag: (start: CGPoint, current: CGPoint)?
    @State private var undoStack: [(drawing: PKDrawing, texts: [SketchText], shapes: [SketchShape], images: [SketchImageElement])] = []
    @State private var redoStack: [(drawing: PKDrawing, texts: [SketchText], shapes: [SketchShape], images: [SketchImageElement])] = []

    // MARK: Text tool state

    /// Active text editing session (nil = none).
    @State private var textEditing: TextEditingSession?
    struct TextEditingSession: Identifiable {
        let id: String
        /// False while composing a brand-new text (Esc discards it).
        var isExisting: Bool
        /// Anchor (top-left) in content coordinates.
        var x: Double
        var y: Double
    }
    @State private var textDraft = ""
    @State private var textFontFamily = SketchTextSupport.defaultFontFamily
    @State private var textFontSize = SketchTextSupport.defaultFontSize
    /// Sticky background; nil = plain text box.
    @State private var textSticky: String? = nil
    /// Active corner-resize of the single selected ELEMENT (shape, text,
    /// image, or stroke — driven by the board's MAIN gesture; child gestures
    /// on handle views froze mid-drag).
    @State private var resizeActive: ResizeSession?

    fileprivate struct ResizeSession {
        enum Target {
            case shape(id: String)
            case text(id: String)
            case image(id: String)
            case stroke(index: Int)
        }
        var target: Target
        var corner: ResizeCorner
        /// Fixed opposite corner (bbox kinds) — content coords.
        var anchor: CGPoint
        /// Frame at drag START (scale ratios for texts/strokes reference it).
        var originalFrame: CGRect
        /// Stroke control points at drag START.
        var originalPoints: [PKStrokePoint]?
        /// Text font size at drag START.
        var originalFontSize: CGFloat?
    }
    /// In-board clipboard for ⌘C/⌘V.
    @State private var boardClipboard: (shapes: [SketchShape], texts: [SketchText], strokes: [PKStroke]) =
        ([], [], [])
    /// True while Space is physically held (temporary select — see
    /// handleDrag). Refreshed on pointer/drag events.
    @State private var spaceSelectActive = false
    @State private var pastedImages: [SketchImageElement] = []
    /// Last fill applied to a shape — new fillable shapes inherit it
    /// (PPT behavior). nil = outline only. Line/arrow are never filled.
    @State private var lastShapeFill: String? = nil
    /// Shape whose LABEL is being edited (the same overlay UI, sticky hidden);
    /// nil while editing a free text box.
    @State private var labelShapeID: String? = nil
    /// Keyboard focus for the open text session's editor.
    @FocusState private var textEditorFocused: Bool
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
    /// Edge band (board points) that triggers auto-pan while drawing.
    private static let autoPanMargin: CGFloat = 36
    /// Max auto-pan speed (board points per tick).
    private static let autoPanSpeed: CGFloat = 14

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            board
        }
        .onAppear { load(drawingData) }
        .onDisappear { stopAutoPan() }
        .onKeyPress { press in
            guard press.modifiers.subtracting(.shift).intersection([.command, .option, .control]).isEmpty
                    || press.modifiers == .command else {
                return .ignored
            }
            if press.characters == "z", press.modifiers.contains(.command) {
                if press.modifiers.contains(.shift) { redo() } else { undo() }
                return .handled
            }
            // ⌘Return commits the open text session (plain Return is a newline).
            if press.key == .return, press.modifiers == .command, textEditing != nil {
                commitTextEditing()
                return .handled
            }
            if press.key == .delete, tool == .select,
               !selectedIndices.isEmpty || !selectedTextIDs.isEmpty
                || !selectedShapeIDs.isEmpty || !selectedImageIDs.isEmpty {
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
        // Tool shortcuts from the AppKit monitor (see MapCanvasView): the
        // board itself is not focusable, so .onKeyPress alone misses them.
        .onReceive(NotificationCenter.default.publisher(for: .swiftMindSketchToolShortcut)) { note in
            guard textEditing == nil,
                  let ch = note.object as? String else { return }
            applyToolShortcut(ch)
        }
        .onReceive(NotificationCenter.default.publisher(for: .swiftMindSketchBoardCopy)) { _ in
            guard textEditing == nil else { return }
            copyBoardSelection()
        }
        .onReceive(NotificationCenter.default.publisher(for: .swiftMindSketchBoardPaste)) { _ in
            guard textEditing == nil else { return }
            pasteBoardClipboard()
        }
    }

    /// Photoshop-convention single-letter tools: V select, B pen, H marker,
    /// E eraser, T text, U cycles the shape library.
    private func applyToolShortcut(_ ch: String) {
        switch ch {
        case "v": tool = .select
        case "b": tool = .pen
        case "h": tool = .marker
        case "e": tool = .eraser
        case "t": tool = .text
        case "u":
            if let index = SketchTool.shapes.firstIndex(of: tool) {
                tool = SketchTool.shapes[(index + 1) % SketchTool.shapes.count]
            } else {
                tool = .rect
            }
        default:
            break
        }
    }

    private func load(_ data: Data) {
        drawing = (try? PKDrawing(data: data)) ?? PKDrawing()
        lastSyncedData = data
        undoStack.removeAll()
        redoStack.removeAll()
        selectedIndices.removeAll()
        selectedTextIDs.removeAll()
        selectedShapeIDs.removeAll()
        textEditing = nil
        labelShapeID = nil
        fitComputed = false
        computeFitIfNeeded()
    }

    // MARK: Board

    private var board: some View {
        GeometryReader { geo in
            ZStack {
                if let boardBackground {
                    Color(nsColor: SketchTextSupport.hexColor(boardBackground))
                }
                if fitComputed {
                    CommittedStrokesImage(drawing: drawing, rect: contentRect)
                }
                if fitComputed, !shapes.isEmpty {
                    ForEach(shapes) { shape in
                        shapeChrome(shape)
                    }
                }
                if fitComputed, !images.isEmpty {
                    ForEach(images) { image in
                        imageChrome(image)
                    }
                }
                if fitComputed, !texts.isEmpty {
                    ForEach(texts) { element in
                        committedTextChrome(element)
                    }
                }
                if let session = textEditing {
                    textEditingOverlay(session)
                }
                if tool == .pen || tool == .marker, !livePoints.isEmpty || !liveRawPoints.isEmpty {
                    StrokePreview(
                        points: livePoints.map { boardPoint(from: $0) } + liveRawPoints,
                        color: markerPreviewColor,
                        width: effectiveInkWidth * fitScale
                    )
                    .drawingGroup()
                }
                if let drag = shapeDrag, tool.isShape {
                    ShapePreview(
                        tool: tool,
                        start: boardPoint(from: drag.start),
                        end: boardPoint(from: shiftConstrainedEnd(of: drag)),
                        color: Color(nsColor: inkColor),
                        width: inkWidth * fitScale
                    )
                }
                if tool == .select,
                   (!selectedIndices.isEmpty || !selectedTextIDs.isEmpty || !selectedShapeIDs.isEmpty), fitComputed {
                    selectionChrome
                }
                if tool == .select, fitComputed, let frame = singleSelectionFrame {
                    resizeHandles(at: frame)
                }
                if spaceSelectActive, tool != .select {
                    VStack {
                        Label("Select", systemImage: "cursorarrow.rays")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.regularMaterial, in: Capsule())
                            .foregroundStyle(.secondary)
                            .padding(8)
                        Spacer()
                    }
                    .allowsHitTesting(false)
                }
                // Marquee rect — only for a REAL marquee (drag on empty
                // space); a move-drag already shows the selection chrome.
                if let drag = selectDrag, tool == .select, !draggingSelection {
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

    /// Fit the existing content (strokes AND text elements) into the board —
    /// once per session (or after an external reload), so the board never
    /// shifts under the pen. Never upscales: tiny content shows 1:1 centered
    /// in a board-sized content rect.
    private func computeFitIfNeeded() {
        guard !fitComputed, boardSize.width > 40, boardSize.height > 40 else { return }
        var bounds = drawing.bounds
        if drawing.strokes.isEmpty || bounds.isNull || bounds.isEmpty || bounds.isInfinite {
            bounds = .null
        }
        for text in texts {
            bounds = bounds.union(CGRect(
                x: text.x, y: text.y, width: text.width, height: text.height
            ))
        }
        for shape in shapes {
            bounds = bounds.union(Self.contentFrame(of: shape))
        }
        if bounds.isNull || bounds.isEmpty || bounds.isInfinite {
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

    // MARK: Edge auto-pan while drawing

    /// Auto-pan delta for the current pointer (board points per tick),
    /// proportional to how deep it sits in the edge band. Zero outside.
    private func autoPanDelta(for pointer: CGPoint) -> CGSize {
        guard boardSize.width > 80, boardSize.height > 80 else { return .zero }
        let m = Self.autoPanMargin
        func axis(_ p: CGFloat, _ max: CGFloat) -> CGFloat {
            if max - p < m {
                let depth = min(1, (m - (max - p)) / m + 0.25)
                return -Self.autoPanSpeed * depth
            }
            if p < m {
                let depth = min(1, (m - p) / m + 0.25)
                return Self.autoPanSpeed * depth
            }
            return 0
        }
        let dx = axis(pointer.x, boardSize.width)
        let dy = axis(pointer.y, boardSize.height)
        return CGSize(width: dx, height: dy)
    }

    /// Start/refresh the auto-pan task for an active drawing drag. The task
    /// ticks ~20×/s, sliding the paper while the pointer sits in the edge
    /// band — pen drags ALSO get a point per tick so the ink keeps flowing
    /// while the paper slides (the pen holds still on screen).
    private func updateAutoPan() {
        guard let pointer = dragPointer else { return }
        if autoPanTask != nil { return }
        guard autoPanDelta(for: pointer) != .zero else { return }
        autoPanTask = Task { @MainActor in
            while !Task.isCancelled {
                guard let pointer = dragPointer else { break }
                let delta = autoPanDelta(for: pointer)
                guard delta != .zero else { break }
                panBoard(by: delta)
                if tool == .pen || tool == .marker, fitComputed {
                    livePoints.append(contentPoint(pointer))
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            await MainActor.run { autoPanTask = nil }
        }
    }

    private func stopAutoPan() {
        autoPanTask?.cancel()
        autoPanTask = nil
    }

    /// Board (gesture) point → content (stroke) point.
    private func contentPoint(_ boardPoint: CGPoint) -> CGPoint {
        CGPoint(
            x: boardPoint.x / fitScale + contentRect.minX,
            y: boardPoint.y / fitScale + contentRect.minY
        )
    }

    /// True while space is physically held: event-tracked flag OR the HID
    /// poll (belt and suspenders).
    private func isSpaceKeyDown() -> Bool {
        SketchEventGuard.spaceHeld
            || CGEventSource.keyState(.combinedSessionState, key: 0x31)
    }

    /// Preview color for the current tool. The marker pre-blends its 45%
    /// translucency with the board background into an OPAQUE color — visually
    /// identical, but no per-frame alpha compositing of the growing path
    /// (that was the marker's perceptible lag).
    private var markerPreviewColor: Color {
        guard tool == .marker else { return Color(nsColor: inkColor) }
        let ink = (try? inkColor.usingColorSpace(.sRGB)) ?? inkColor
        let baseHex = boardBackground ?? "#FFFFFF"
        let scanner = Scanner(string: String(baseHex.dropFirst()))
        var value: UInt64 = 0
        scanner.scanHexInt64(&value)
        let bg = (
            CGFloat((value >> 16) & 0xFF) / 255,
            CGFloat((value >> 8) & 0xFF) / 255,
            CGFloat(value & 0xFF) / 255
        )
        func blend(_ fg: CGFloat, _ b: CGFloat) -> CGFloat { fg * 0.45 + b * 0.55 }
        return Color(red: Double(blend(ink.redComponent, bg.0)),
                     green: Double(blend(ink.greenComponent, bg.1)),
                     blue: Double(blend(ink.blueComponent, bg.2)))
    }

    /// Width for the current tool — the marker is always 4× the pen width
    /// (same slider, highlighter scale).
    private var effectiveInkWidth: CGFloat {
        tool == .marker ? inkWidth * 4 : inkWidth
    }

    /// Ink color in sRGB for PKInK. Grayscale catalog colors (.black/.white/
    /// .darkGray) break PKDrawing.image() rasterization — the renderer reads
    /// the single gray channel as ALPHA: black strokes vanish (they show the
    /// card behind) and white strokes render black. Converting to sRGB first
    /// renders every swatch literally.
    private var inkColorForPencilKit: NSColor {
        inkColor.usingColorSpace(.sRGB) ?? inkColor
    }

    /// Content (stroke) point → board (view) point — the exact inverse.
    private func boardPoint(from content: CGPoint) -> CGPoint {
        CGPoint(
            x: (content.x - contentRect.minX) * fitScale,
            y: (content.y - contentRect.minY) * fitScale
        )
    }

    private enum DragPhase { case changed, ended }

    /// Shape-drag end with the Shift constraint applied (square/circle takes
    /// the larger drag extent). DragGesture values carry no modifier flags,
    /// so Shift is read from the live NSEvent state — preview and commit both
    /// route through here, so what the user sees is what gets committed.
    private func shiftConstrainedEnd(of drag: (start: CGPoint, current: CGPoint)) -> CGPoint {
        ShapeGeometry.constrainedEnd(
            from: drag.start,
            to: drag.current,
            shift: NSEvent.modifierFlags.contains(.shift)
        )
    }

    private func handleDrag(_ location: CGPoint, phase: DragPhase) {
        // While a text session is open, any board click commits it first
        // (the editing overlay consumes clicks inside itself).
        if textEditing != nil {
            if phase == .ended { commitTextEditing() }
            return
        }
        // Space-hold = temporary SELECT (Photoshop convention): select, move,
        // and resize without leaving the drawing tool; release restores it.
        spaceSelectActive = isSpaceKeyDown()
        let tool = spaceSelectActive ? SketchTool.select : self.tool
        if tool == .text {
            guard fitComputed else { return }
            if phase == .ended { beginTextEditing(at: contentPoint(location)) }
            return
        }
        // Drawing drags feed the edge auto-pan (the paper slides while the
        // pointer holds still near an edge, like right-drag panning).
        let drawingDrag = tool.isShape || tool == .pen || tool == .marker
        if drawingDrag {
            if phase == .changed {
                dragPointer = location
                updateAutoPan()
            } else {
                dragPointer = nil
                stopAutoPan()
            }
        }
        if tool.isShape {
            guard fitComputed else { return }
            let content = contentPoint(location)
            switch phase {
            case .changed:
                if shapeDrag == nil { shapeDrag = (start: content, current: content) }
                else { shapeDrag?.current = content }
            case .ended:
                shapeDrag?.current = content
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
                    if let corner = grabbedResizeCorner(at: content),
                       let target = selectionTarget(),
                       let frame = singleSelectionFrame {
                        // Corner grab resizes the single selected element.
                        var session = ResizeSession(
                            target: target, corner: corner,
                            anchor: anchorFor(corner, of: frame),
                            originalFrame: frame,
                            originalPoints: nil, originalFontSize: nil
                        )
                        switch target {
                        case .stroke(let index):
                            let stroke = drawing.strokes[index]
                            session.originalPoints = (0..<stroke.path.count).map {
                                stroke.path[$0]
                            }
                        case .text(let id):
                            session.originalFontSize = texts
                                .first { $0.id == id }.map { CGFloat($0.fontSize) }
                        default:
                            break
                        }
                        resizeActive = session
                        pushUndo()
                    } else {
                        // Dragging FROM a selected stroke moves it; otherwise marquee.
                        draggingSelection = hitSelected(at: content)
                        if draggingSelection { pushUndo() }
                    }
                } else if resizeActive != nil {
                    selectDrag?.current = content
                    applyResize(pointer: content)
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
                    spaceSelectActive = isSpaceKeyDown()
                }
                if resizeActive != nil {
                    resizeActive = nil
                    syncToModel()
                    return
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
        case .pen, .marker:
            // Record CONTENT points at arrival so a mid-drag auto-pan (content
            // rect shift) can never bend the stroke. Before the fit lands the
            // point goes to the raw tail, converted at commit when the fit
            // necessarily exists (gating input on the fit race dropped whole
            // drags on slow layouts).
            if fitComputed {
                livePoints.append(contentPoint(location))
            } else {
                computeFitIfNeeded()
                if fitComputed {
                    livePoints.append(contentPoint(location))
                } else {
                    liveRawPoints.append(location)
                }
            }
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
        defer {
            livePoints.removeAll()
            liveRawPoints.removeAll()
        }
        computeFitIfNeeded() // last chance: the drag hit the board, so it exists
        let points = livePoints + liveRawPoints.map(contentPoint)
        guard points.count > 1, fitComputed else { return }

        // Hand-drawn recognition: a confident circle-ish pen stroke snaps to
        // a true ellipse MODEL SHAPE (editable: fill, label, move).
        if tool == .pen, ShapeGeometry.recognizesEllipse(points) {
            pushUndo()
            let xs = points.map(\.x), ys = points.map(\.y)
            let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
            shapes.append(SketchShape(
                kind: .ellipse,
                x: Double(minX), y: Double(minY),
                width: Double(maxX - minX), height: Double(maxY - minY),
                strokeColor: SketchTextSupport.hex(from: inkColorForPencilKit),
                strokeWidth: Double(inkWidth),
                fillColor: lastShapeFill
            ))
            syncToModel()
            return
        }

        pushUndo()
        let now = Date().timeIntervalSinceReferenceDate
        let strokePoints = points.map { location in
            PKStrokePoint(
                location: location,
                timeOffset: now,
                size: CGSize(width: effectiveInkWidth, height: effectiveInkWidth),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            )
        }
        let path = PKStrokePath(controlPoints: strokePoints, creationDate: Date())
        // Highlighter = round pen ink + translucent color: uniform width in
        // every direction (marker ink renders a chisel nib — wide across,
        // narrow along) and true translucency that survives rasterization.
        let inkColor: NSColor = tool == .marker
            ? inkColorForPencilKit.withAlphaComponent(0.45)
            : inkColorForPencilKit
        drawing.strokes.append(PKStroke(
            ink: PKInk(.pen, color: inkColor),
            path: path
        ))
        syncToModel()
    }

    /// Commit the shape drag as a MODEL element (PPT-style): geometry +
    /// outline styling; label/fill come later via the text tool. Line/arrow
    /// store the endpoint pair as the frame (possibly negative extents).
    private func commitShapeStroke() {
        defer { shapeDrag = nil }
        guard let drag = shapeDrag, let kind = tool.shapeKind else { return }
        let a = drag.start
        let b = shiftConstrainedEnd(of: drag)
        pushUndo()
        // Fillable shapes (everything except line/arrow) inherit the last
        // fill the user applied — drawing a series of filled shapes just
        // works, PPT-style.
        let fillable = kind != .line && kind != .arrow
        let shape = SketchShape(
            kind: SketchShape.Kind(rawValue: kind.rawValue)!,
            x: Double(a.x), y: Double(a.y),
            width: Double(b.x - a.x), height: Double(b.y - a.y),
            strokeColor: SketchTextSupport.hex(from: inkColor),
            strokeWidth: Double(inkWidth),
            fillColor: fillable ? lastShapeFill : nil
        )
        shapes.append(shape)
        syncToModel()
    }

    /// Shape frame in content coords (bounding box for line kinds too).
    static func contentFrame(of shape: SketchShape) -> CGRect {
        CGRect(
            x: min(shape.x, shape.x + shape.width), y: min(shape.y, shape.y + shape.height),
            width: abs(shape.width), height: abs(shape.height)
        )
    }

    // MARK: - Text tool

    /// Tap with the text tool: edit the text under the point, or start a new
    /// one anchored there.
    private func beginTextEditing(at content: CGPoint) {
        SketchEventGuard.textEditingActive = true
        // Clicking a SHAPE with the text tool edits its centered label.
        if let index = shapes.lastIndex(where: { Self.shapeHit($0, contains: content) }) {
            let shape = shapes[index]
            labelShapeID = shape.id
            let frame = Self.contentFrame(of: shape)
            textEditing = TextEditingSession(
                id: shape.id, isExisting: true,
                x: Double(frame.minX), y: Double(frame.minY)
            )
            textDraft = shape.text ?? ""
            textFontFamily = shape.fontFamily
            textFontSize = CGFloat(shape.fontSize)
            inkColor = SketchTextSupport.hexColor(shape.textColor)
            textSticky = nil
            selectedIndices.removeAll()
            selectedTextIDs.removeAll()
            selectedShapeIDs.removeAll()
            return
        }
        if let index = texts.lastIndex(where: {
            CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
                .insetBy(dx: -4, dy: -4).contains(content)
        }) {
            labelShapeID = nil
            let element = texts[index]
            textEditing = TextEditingSession(id: element.id, isExisting: true, x: element.x, y: element.y)
            textDraft = element.text
            textFontFamily = element.fontFamily
            textFontSize = CGFloat(element.fontSize)
            textSticky = element.background
            inkColor = SketchTextSupport.hexColor(element.color)
        } else {
            labelShapeID = nil
            textEditing = TextEditingSession(
                id: UUID().uuidString, isExisting: false,
                x: Double(content.x), y: Double(content.y)
            )
            textDraft = ""
            textSticky = nil
        }
        selectedIndices.removeAll()
        selectedTextIDs.removeAll()
    }

    /// Commit the open text session into `texts` (measured frame, current
    /// font/ink). Empty text (or `discard`) keeps the previous element, so
    /// Esc on a new box discards it and Esc on an existing one reverts edits.
    private func commitTextEditing(discard: Bool = false) {
        guard let session = textEditing else { return }
        textEditing = nil
        SketchEventGuard.textEditingActive = false
        let trimmed = textDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !discard, !trimmed.isEmpty else { return }

        // Shape label: write text/font/color and grow the frame around the
        // label (keeping the center) so long text never overflows the shape.
        if let shapeID = labelShapeID,
           let index = shapes.firstIndex(where: { $0.id == shapeID }) {
            pushUndo()
            let measured = SketchTextSupport.measuredSize(
                text: textDraft, family: textFontFamily, size: textFontSize, sticky: false
            )
            var shape = shapes[index]
            shape.text = textDraft
            shape.fontFamily = textFontFamily
            shape.fontSize = Double(textFontSize)
            shape.textColor = SketchTextSupport.hex(from: inkColor)
            let frame = Self.contentFrame(of: shape)
            let newW = max(frame.width, measured.width + 16)
            let newH = max(frame.height, measured.height + 12)
            shape.x = Double(frame.midX - newW / 2)
            shape.y = Double(frame.midY - newH / 2)
            shape.width = Double(newW)
            shape.height = Double(newH)
            shapes[index] = shape
            labelShapeID = nil
            SketchTextSupport.noteFontUsed(textFontFamily)
            syncToModel()
            return
        }
        labelShapeID = nil
        pushUndo()
        let size = SketchTextSupport.measuredSize(
            text: textDraft, family: textFontFamily,
            size: textFontSize, sticky: textSticky != nil
        )
        let element = SketchText(
            id: session.id,
            text: textDraft,
            x: session.x, y: session.y,
            fontFamily: textFontFamily,
            fontSize: Double(textFontSize),
            color: SketchTextSupport.hex(from: inkColor),
            background: textSticky,
            width: Double(size.width), height: Double(size.height)
        )
        if let index = texts.firstIndex(where: { $0.id == session.id }) {
            texts[index] = element
        } else {
            texts.append(element)
        }
        SketchTextSupport.noteFontUsed(textFontFamily)
        syncToModel()
    }

    /// Four visual corner grips for the single selected ELEMENT. Hit-testing
    /// happens in the board's MAIN gesture (grabbedResizeCorner); gestures on
    /// these child views froze mid-drag on re-render.
    @ViewBuilder
    private func resizeHandles(at frame: CGRect) -> some View {
        let corners: [(CGPoint, ResizeCorner)] = [
            (CGPoint(x: frame.minX, y: frame.minY), .tl),
            (CGPoint(x: frame.maxX, y: frame.minY), .tr),
            (CGPoint(x: frame.maxX, y: frame.maxY), .br),
            (CGPoint(x: frame.minX, y: frame.maxY), .bl),
        ]
        ForEach(corners, id: \.1) { corner, _ in
            ResizeHandle()
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .position(x: (corner.x - contentRect.minX) * fitScale,
                          y: (corner.y - contentRect.minY) * fitScale)
                .allowsHitTesting(false)
        }
    }

    /// Four visual corner grips for the single selected shape. Hit-testing
    /// happens in the board's MAIN gesture (grabbedResizeCorner); gestures on
    /// these child views froze mid-drag on re-render.
    @ViewBuilder
    private func resizeHandles(for shape: SketchShape) -> some View {
        let frame = Self.contentFrame(of: shape)
        let corners: [(CGPoint, ResizeCorner)] = [
            (CGPoint(x: frame.minX, y: frame.minY), .tl),
            (CGPoint(x: frame.maxX, y: frame.minY), .tr),
            (CGPoint(x: frame.maxX, y: frame.maxY), .br),
            (CGPoint(x: frame.minX, y: frame.maxY), .bl),
        ]
        ForEach(corners, id: \.1) { corner, _ in
            ResizeHandle()
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .position(x: (corner.x - contentRect.minX) * fitScale,
                          y: (corner.y - contentRect.minY) * fitScale)
                .allowsHitTesting(false)
        }
    }

    /// PPT-style fill bar for the selected shapes (bottom of the board).
    private var shapeFillBar: some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                Text("Fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SketchColorPicker(
                    title: "Shape Fill",
                    supportsNone: true,
                    selection: Binding(
                        get: { shapes.last { selectedShapeIDs.contains($0.id) }?.fillColor },
                        set: { applyShapeFill($0) }
                    ),
                    identifier: "sketchShapeFill"
                )
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding(10)
        }
    }

    enum ResizeCorner: Hashable { case tl, tr, br, bl }

    /// The bbox of the SINGLE selected element, whatever its type.
    private var singleSelectionFrame: CGRect? {
        if selectedIndices.count == 1,
           let index = selectedIndices.first, index < drawing.strokes.count {
            return Self.bounds(of: drawing.strokes[index])
        }
        if selectedTextIDs.count == 1,
           let element = texts.first(where: { $0.id == selectedTextIDs.first! }) {
            return Self.textFrame(of: element)
        }
        if selectedImageIDs.count == 1,
           let image = images.first(where: { $0.id == selectedImageIDs.first! }) {
            return CGRect(x: image.x, y: image.y, width: image.width, height: image.height)
        }
        if selectedShapeIDs.count == 1,
           let shape = shapes.first(where: { $0.id == selectedShapeIDs.first! }) {
            return Self.contentFrame(of: shape)
        }
        return nil
    }

    private func selectionTarget() -> ResizeSession.Target? {
        if selectedIndices.count == 1, let index = selectedIndices.first,
           index < drawing.strokes.count {
            return .stroke(index: index)
        }
        if selectedTextIDs.count == 1, let id = selectedTextIDs.first {
            return .text(id: id)
        }
        if selectedImageIDs.count == 1, let id = selectedImageIDs.first {
            return .image(id: id)
        }
        if selectedShapeIDs.count == 1, let id = selectedShapeIDs.first {
            return .shape(id: id)
        }
        return nil
    }

    /// True when the content point sits within a corner's grab radius of the
    /// single selected element (resize beats select/marquee).
    private func grabbedResizeCorner(at content: CGPoint) -> ResizeCorner? {
        guard let frame = singleSelectionFrame else { return nil }
        let radius: CGFloat = 14
        let corners: [(CGPoint, ResizeCorner)] = [
            (CGPoint(x: frame.minX, y: frame.minY), .tl),
            (CGPoint(x: frame.maxX, y: frame.minY), .tr),
            (CGPoint(x: frame.maxX, y: frame.maxY), .br),
            (CGPoint(x: frame.minX, y: frame.maxY), .bl),
        ]
        return corners.first { corner, _ in
            hypot(content.x - corner.x, content.y - corner.y) <= radius
        }?.1
    }

    /// Anchor = the fixed opposite corner.
    private func anchorFor(_ corner: ResizeCorner, of frame: CGRect) -> CGPoint {
        switch corner {
        case .tl: return CGPoint(x: frame.maxX, y: frame.maxY)
        case .tr: return CGPoint(x: frame.minX, y: frame.maxY)
        case .br: return CGPoint(x: frame.minX, y: frame.minY)
        case .bl: return CGPoint(x: frame.maxX, y: frame.minY)
        }
    }

    /// Frame between the anchor and the pointer (min size 12).
    static func rectBetween(anchor: CGPoint, pointer: CGPoint) -> CGRect {
        let minX = min(anchor.x, pointer.x), maxX = max(anchor.x, pointer.x)
        let minY = min(anchor.y, pointer.y), maxY = max(anchor.y, pointer.y)
        return CGRect(
            x: minX, y: minY,
            width: max(maxX - minX, 12),
            height: max(maxY - minY, 12)
        )
    }

    /// Re-frame / re-scale the resizing element between its anchor and the
    /// pointer. Shapes re-frame; texts scale their font with the height;
    /// images re-frame; strokes rescale their ORIGINAL control points into
    /// the new bbox (snapshot taken at drag start).
    private func applyResize(pointer: CGPoint) {
        guard let session = resizeActive else { return }
        switch session.target {
        case .shape(let id):
            guard let index = shapes.firstIndex(where: { $0.id == id }) else { return }
            var updated = shapes[index]
            if updated.kind == .line || updated.kind == .arrow {
                let startIsAnchor = (session.corner == .tr || session.corner == .br)
                let start = startIsAnchor ? session.anchor : pointer
                let end = startIsAnchor ? pointer : session.anchor
                updated.x = Double(start.x)
                updated.y = Double(start.y)
                updated.width = Double(end.x - start.x)
                updated.height = Double(end.y - start.y)
            } else {
                let rect = Self.rectBetween(anchor: session.anchor, pointer: pointer)
                updated.x = Double(rect.minX)
                updated.y = Double(rect.minY)
                updated.width = Double(rect.width)
                updated.height = Double(rect.height)
            }
            shapes[index] = updated

        case .image(let id):
            guard let index = images.firstIndex(where: { $0.id == id }) else { return }
            let rect = Self.rectBetween(anchor: session.anchor, pointer: pointer)
            images[index].x = Double(rect.minX)
            images[index].y = Double(rect.minY)
            images[index].width = Double(rect.width)
            images[index].height = Double(rect.height)

        case .text(let id):
            guard let index = texts.firstIndex(where: { $0.id == id }) else { return }
            let rect = Self.rectBetween(anchor: session.anchor, pointer: pointer)
            var updated = texts[index]
            if let originalSize = session.originalFontSize,
               session.originalFrame.height > 1 {
                let ratio = rect.height / session.originalFrame.height
                updated.fontSize = min(96, max(6, originalSize * ratio))
            }
            updated.x = Double(rect.minX)
            updated.y = Double(rect.minY)
            updated.width = Double(rect.width)
            updated.height = Double(rect.height)
            texts[index] = updated

        case .stroke(let index):
            guard index < drawing.strokes.count,
                  let original = session.originalPoints else { return }
            let rect = Self.rectBetween(anchor: session.anchor, pointer: pointer)
            let oldW = session.originalFrame.width, oldH = session.originalFrame.height
            let sx = oldW > 1 ? rect.width / oldW : 1
            let sy = oldH > 1 ? rect.height / oldH : 1
            let origin = session.originalFrame.origin
            let moved = original.map { pt in
                PKStrokePoint(
                    location: CGPoint(
                        x: rect.minX + (pt.location.x - origin.x) * sx,
                        y: rect.minY + (pt.location.y - origin.y) * sy
                    ),
                    timeOffset: pt.timeOffset,
                    size: pt.size,
                    opacity: pt.opacity,
                    force: pt.force,
                    azimuth: pt.azimuth,
                    altitude: pt.altitude
                )
            }
            guard moved.count > 1 else { return }
            drawing.strokes[index] = PKStroke(
                ink: drawing.strokes[index].ink,
                path: PKStrokePath(controlPoints: moved, creationDate: Date())
            )
        }
    }

    /// ⌘C on the board: stash the selected elements (internal clipboard —
    /// independent of the system pasteboard's node-level copy).
    private func copyBoardSelection() {
        guard !selectedIndices.isEmpty || !selectedTextIDs.isEmpty || !selectedShapeIDs.isEmpty else {
            return
        }
        boardClipboard = (
            shapes: shapes.filter { selectedShapeIDs.contains($0.id) },
            texts: texts.filter { selectedTextIDs.contains($0.id) },
            strokes: drawing.strokes.enumerated()
                .filter { selectedIndices.contains($0.offset) }
                .map(\.element)
        )
        pastedImages = images.filter { selectedImageIDs.contains($0.id) }
    }

    /// ⌘V on the board: duplicate the clipboard 16pt down-right, fresh ids,
    /// and select the duplicates (one undo step).
    private func pasteBoardClipboard() {
        guard !(boardClipboard.shapes.isEmpty && boardClipboard.texts.isEmpty
            && boardClipboard.strokes.isEmpty && pastedImages.isEmpty) else { return }
        pushUndo()
        let dx: Double = 16, dy: Double = 16
        var pastedShapeIDs: [String] = []
        let newShapes = boardClipboard.shapes.map { shape -> SketchShape in
            var copy = shape
            copy.id = UUID().uuidString
            copy.x += dx
            copy.y += dy
            pastedShapeIDs.append(copy.id)
            return copy
        }
        var pastedTextIDs: [String] = []
        let newTexts = boardClipboard.texts.map { element -> SketchText in
            var copy = element
            copy.id = UUID().uuidString
            copy.x += dx
            copy.y += dy
            pastedTextIDs.append(copy.id)
            return copy
        }
        let firstPastedStroke = drawing.strokes.count
        let newStrokes = boardClipboard.strokes.map { stroke in
            SketchSupport.translated(stroke, by: CGAffineTransform(translationX: dx, y: dy))
        }
        let newImages = pastedImages.map { image -> SketchImageElement in
            var copy = image
            copy.id = UUID().uuidString
            copy.x += dx
            copy.y += dy
            return copy
        }
        var pastedImageIDs: [String] = []
        images.append(contentsOf: newImages.map { image in
            pastedImageIDs.append(image.id)
            return image
        })
        shapes.append(contentsOf: newShapes)
        texts.append(contentsOf: newTexts)
        drawing.strokes.append(contentsOf: newStrokes)
        selectedIndices = Set(firstPastedStroke..<drawing.strokes.count)
        selectedTextIDs = Set(pastedTextIDs)
        selectedShapeIDs = Set(pastedShapeIDs)
        selectedImageIDs = Set(pastedImageIDs)
        syncToModel()
    }

    /// Fill applied live to every selected shape; one undo step, one commit.
    private func applyShapeFill(_ fill: String?) {
        guard !selectedShapeIDs.isEmpty else { return }
        lastShapeFill = fill
        pushUndo()
        shapes = shapes.map { shape in
            guard selectedShapeIDs.contains(shape.id) else { return shape }
            var updated = shape
            updated.fillColor = fill
            return updated
        }
        syncToModel()
    }

    /// Image element on the board (scaled content → board).
    @ViewBuilder
    private func imageChrome(_ image: SketchImageElement) -> some View {
        if let nsImage = NSImage(data: image.data) {
            let frame = CGRect(
                x: (image.x - contentRect.minX) * fitScale,
                y: (image.y - contentRect.minY) * fitScale,
                width: image.width * fitScale,
                height: image.height * fitScale
            )
            Image(nsImage: nsImage)
                .resizable()
                .frame(width: frame.width, height: frame.height)
                .overlay {
                    if selectedImageIDs.contains(image.id) {
                        Rectangle()
                            .strokeBorder(Color.accentColor.opacity(0.9),
                                          style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                    }
                }
                .position(x: frame.midX, y: frame.midY)
                .accessibilityIdentifier("sketchImage-\(image.id)")
        }
    }

    /// Toolbar photo button: pick an image, normalize (note-image pipeline),
    /// drop it centered on the board aspect-fitted to ≤320pt.
    private func insertImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an image to place on the board"
        panel.begin { response in
            guard response == .OK, let url = panel.url,
                  let raw = try? Data(contentsOf: url),
                  let png = ClipboardService.normalizeImage(raw) else { return }
            DispatchQueue.main.async {
                insertImageData(png)
            }
        }
    }

    private func insertImageData(_ png: Data) {
        guard let nsImage = NSImage(data: png) else { return }
        let natural = nsImage.size
        guard natural.width > 1, natural.height > 1 else { return }
        let cap: CGFloat = 320
        let scale = min(1, cap / max(natural.width, natural.height))
        let size = CGSize(width: natural.width * scale, height: natural.height * scale)
        // Board center in content coords.
        let center = contentPoint(CGPoint(x: boardSize.width / 2, y: boardSize.height / 2))
        pushUndo()
        images.append(SketchImageElement(
            x: Double(center.x - size.width / 2),
            y: Double(center.y - size.height / 2),
            width: Double(size.width), height: Double(size.height),
            data: png
        ))
        selectedIndices.removeAll()
        selectedTextIDs.removeAll()
        selectedShapeIDs.removeAll()
        selectedImageIDs = [images[images.count - 1].id]
        tool = .select
        syncToModel()
    }

    /// Committed shape element on the board: outline via the SAME dense
    /// ShapeGeometry samples, optional fill, optional centered label.
    @ViewBuilder
    private func shapeChrome(_ shape: SketchShape) -> some View {
        let frame = Self.contentFrame(of: shape)
        let board = CGRect(
            x: (frame.minX - contentRect.minX) * fitScale,
            y: (frame.minY - contentRect.minY) * fitScale,
            width: frame.width * fitScale,
            height: frame.height * fitScale
        )
        ZStack {
            ShapeElementPath(shape: shape, fitScale: fitScale)
                .stroke(
                    Color(nsColor: SketchTextSupport.hexColor(shape.strokeColor)),
                    style: StrokeStyle(lineWidth: CGFloat(shape.strokeWidth) * fitScale,
                                       lineCap: .round, lineJoin: .round)
                )
            if let fill = shape.fillColor {
                ShapeElementPath(shape: shape, fitScale: fitScale)
                    .fill(Color(nsColor: SketchTextSupport.hexColor(fill)))
            }
            if let label = shape.text, !label.isEmpty {
                Text(label)
                    .font(Font.custom(shape.fontFamily, size: CGFloat(shape.fontSize) * fitScale))
                    .foregroundStyle(Color(nsColor: SketchTextSupport.hexColor(shape.textColor)))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 6 * fitScale)
                    .minimumScaleFactor(0.5)
            }
            if selectedShapeIDs.contains(shape.id) {
                Rectangle()
                    .strokeBorder(Color.accentColor.opacity(0.9),
                                  style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            }
        }
        .frame(width: board.width, height: board.height, alignment: .topLeading)
        .position(x: board.midX, y: board.midY)
        .accessibilityIdentifier("sketchShape-\(shape.id)")
    }

    /// Committed text element on the board (scaled content → board).
    @ViewBuilder
    private func committedTextChrome(_ element: SketchText) -> some View {
        let frame = CGRect(
            x: (element.x - contentRect.minX) * fitScale,
            y: (element.y - contentRect.minY) * fitScale,
            width: element.width * fitScale,
            height: element.height * fitScale
        )
        let body = Text(element.text)
            .font(Font.custom(element.fontFamily, size: CGFloat(element.fontSize) * fitScale))
            .foregroundStyle(Color(nsColor: SketchTextSupport.hexColor(element.color)))
            .frame(
                width: frame.width - (element.background != nil ? SketchTextSupport.stickyPadding * 2 * fitScale : 0),
                height: frame.height - (element.background != nil ? SketchTextSupport.stickyPadding * 2 * fitScale : 0),
                alignment: .topLeading
            )
        Group {
            if element.background != nil {
                body.padding(SketchTextSupport.stickyPadding * fitScale)
                    .background(
                        RoundedRectangle(cornerRadius: 6 * fitScale)
                            .fill(Color(nsColor: SketchTextSupport.hexColor(element.background!)))
                            .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                    )
            } else {
                body
            }
        }
        .overlay {
            if selectedTextIDs.contains(element.id) {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.accentColor.opacity(0.9),
                                  style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            }
        }
        .frame(width: frame.width, height: frame.height, alignment: .topLeading)
        .position(x: frame.minX + frame.width / 2, y: frame.minY + frame.height / 2)
        .accessibilityIdentifier("sketchText-\(element.id)")
    }

    /// In-place editor for the open text session: styled TextEditor + font bar
    /// (family with recents on top, size, sticky background). Commit = the
    /// button, ⌘Return, or clicking elsewhere; Esc reverts.
    @ViewBuilder
    private func textEditingOverlay(_ session: TextEditingSession) -> some View {
        let anchor = CGPoint(
            x: (CGFloat(session.x) - contentRect.minX) * fitScale,
            y: (CGFloat(session.y) - contentRect.minY) * fitScale
        )
        let measured = SketchTextSupport.measuredSize(
            text: textDraft.isEmpty ? " " : textDraft,
            family: textFontFamily, size: textFontSize, sticky: textSticky != nil
        )
        // One consistent panel width: the editor matches the fixed-width
        // font bar, so the panel background never shows as an empty filled
        // area beside a narrow editor.
        let width = min(max(measured.width * fitScale + 24, 336), boardSize.width - 24)
        let height = min(max(measured.height * fitScale + 20, 44), boardSize.height * 0.6)
        let clampedX = min(max(anchor.x, 8), max(8, boardSize.width - width - 8))
        let clampedY = min(max(anchor.y, 8), max(8, boardSize.height - height - 8))
        VStack(alignment: .leading, spacing: 4) {
            TextEditor(text: $textDraft)
                .focused($textEditorFocused)
                .font(Font.custom(textFontFamily, size: textFontSize * fitScale))
                .foregroundStyle(Color(nsColor: inkColor))
                .scrollContentBackground(.hidden)
                .frame(width: width, height: height)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .textBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1.5)
                        )
                )
            fontBar
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.97))
                .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
        )
        .padding(4)
        .position(x: clampedX + width / 2, y: clampedY + height / 2)
        .onExitCommand { commitTextEditing(discard: true) }
        .onAppear {
            DispatchQueue.main.async { textEditorFocused = true }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sketchTextEditor")
    }

    /// Font controls for the open text session.
    private var fontBar: some View {
        HStack(spacing: 8) {
            Menu {
                let recents = SketchTextSupport.recentFontFamilies
                    .filter { $0 != textFontFamily }
                if !recents.isEmpty {
                    Section("Recently Used") {
                        ForEach(recents, id: \.self) { family in
                            Button(family) { textFontFamily = family }
                        }
                    }
                }
                Section("All Fonts") {
                    ForEach(SketchTextSupport.fontFamilies, id: \.self) { family in
                        Button(family) {
                            textFontFamily = family
                            SketchTextSupport.noteFontUsed(family)
                        }
                    }
                }
            } label: {
                Text(textFontFamily)
                    .frame(maxWidth: 130, alignment: .leading)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .fixedSize()
            .accessibilityIdentifier("sketchTextFontMenu")

            Menu {
                ForEach(SketchTextSupport.fontSizes, id: \.self) { size in
                    Button(Int(size).description) { textFontSize = size }
                }
            } label: {
                Text("\(Int(textFontSize)) pt")
            }
            .fixedSize()
            .accessibilityIdentifier("sketchTextSizeMenu")

            SketchColorPicker(
                title: "Text Background",
                supportsNone: true,
                selection: $textSticky,
                identifier: "sketchTextSticky"
            )

            Spacer(minLength: 0)

            Button("OK", action: { commitTextEditing() })
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier("sketchTextCommit")
        }
        .frame(width: 320)
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

    private static func textFrame(of element: SketchText) -> CGRect {
        CGRect(x: element.x, y: element.y, width: element.width, height: element.height)
    }

    /// Tap with the select tool: the topmost TEXT under the point wins, else
    /// the stroke closest to the tap center.
    private func tapSelect(at content: CGPoint) {
        if let index = images.lastIndex(where: {
            CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
                .insetBy(dx: -2, dy: -2).contains(content)
        }) {
            selectedImageIDs = [images[index].id]
            selectedIndices = []
            selectedTextIDs = []
            selectedShapeIDs = []
            return
        }
        selectedImageIDs = []
        if let index = texts.lastIndex(where: {
            Self.textFrame(of: $0).insetBy(dx: -4, dy: -4).contains(content)
        }) {
            selectedTextIDs = [texts[index].id]
            selectedIndices = []
            selectedShapeIDs = []
            return
        }
        if let index = shapes.lastIndex(where: { Self.shapeHit($0, contains: content) }) {
            selectedShapeIDs = [shapes[index].id]
            selectedIndices = []
            selectedTextIDs = []
            return
        }
        selectedShapeIDs = []
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
        selectedTextIDs = []
        if selectedIndices.isEmpty { selectedShapeIDs = [] }
    }

    /// Hit test one shape: containment for bbox kinds, distance to the
    /// endpoint segment for line/arrow.
    static func shapeHit(_ shape: SketchShape, contains p: CGPoint) -> Bool {
        guard let kind = shape.shapeKind else { return false }
        if kind == .line || kind == .arrow {
            let a = CGPoint(x: shape.x, y: shape.y)
            let b = CGPoint(x: shape.x + shape.width, y: shape.y + shape.height)
            let abx = b.x - a.x, aby = b.y - a.y
            let t = min(max(((p.x - a.x) * abx + (p.y - a.y) * aby) / (abx * abx + aby * aby), 0), 1)
            let cx = a.x + abx * t, cy = a.y + aby * t
            return hypot(p.x - cx, p.y - cy) <= max(8, shape.strokeWidth)
        }
        return contentFrame(of: shape).insetBy(dx: -2, dy: -2).contains(p)
    }

    /// True when a content point sits inside a selected stroke's or text's bounds.
    private func hitSelected(at content: CGPoint) -> Bool {
        if selectedTextIDs.contains(where: { id in
            texts.first(where: { $0.id == id }).map { Self.textFrame(of: $0).contains(content) } == true
        }) {
            return true
        }
        if selectedShapeIDs.contains(where: { id in
            shapes.first(where: { $0.id == id }).map { Self.shapeHit($0, contains: content) } == true
        }) {
            return true
        }
        if selectedImageIDs.contains(where: { id in
            images.first(where: { $0.id == id }).map {
                CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height).contains(content)
            } == true
        }) {
            return true
        }
        return selectedIndices.contains { index in
            guard index < drawing.strokes.count else { return false }
            let b = Self.bounds(of: drawing.strokes[index])
            return !b.isNull
                && content.x >= b.minX - 6 && content.x <= b.maxX + 6
                && content.y >= b.minY - 6 && content.y <= b.maxY + 6
        }
    }

    /// Marquee: select strokes AND texts whose bounds intersect the drag rect.
    private func marqueeSelect(from a: CGPoint, to b: CGPoint) {
        let rect = CGRect(
            x: min(a.x, b.x), y: min(a.y, b.y),
            width: abs(b.x - a.x), height: abs(b.y - a.y)
        )
        selectedIndices = Set(drawing.strokes.indices.filter { index in
            let bounds = Self.bounds(of: drawing.strokes[index])
            return !bounds.isNull && bounds.insetBy(dx: -4, dy: -4).intersects(rect)
        })
        selectedTextIDs = Set(texts.filter {
            Self.textFrame(of: $0).insetBy(dx: -4, dy: -4).intersects(rect)
        }.map(\.id))
        selectedShapeIDs = Set(shapes.filter {
            Self.contentFrame(of: $0).insetBy(dx: -4, dy: -4).intersects(rect)
        }.map(\.id))
        selectedImageIDs = Set(images.filter {
            CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
                .insetBy(dx: -4, dy: -4).intersects(rect)
        }.map(\.id))
    }

    /// Move the selected strokes AND texts by a content-space delta (no undo
    /// push — the caller pushes once at drag start).
    private func moveSelected(by delta: CGPoint) {
        guard !selectedIndices.isEmpty || !selectedTextIDs.isEmpty
            || !selectedShapeIDs.isEmpty || !selectedImageIDs.isEmpty else { return }
        if !selectedImageIDs.isEmpty {
            images = images.map { image in
                guard selectedImageIDs.contains(image.id) else { return image }
                var moved = image
                moved.x += Double(delta.x)
                moved.y += Double(delta.y)
                return moved
            }
        }
        if !selectedIndices.isEmpty {
            // Translate the ORIGINAL control points (same path trim uses) —
            // resampling through interpolatedPoints(by: .distance(4)) would
            // discard the dense shape sampling and deform the outline.
            let shift = CGAffineTransform(translationX: delta.x, y: delta.y)
            drawing.strokes = drawing.strokes.enumerated().map { index, stroke in
                guard selectedIndices.contains(index) else { return stroke }
                return SketchSupport.translated(stroke, by: shift)
            }
        }
        if !selectedTextIDs.isEmpty {
            texts = texts.map { element in
                guard selectedTextIDs.contains(element.id) else { return element }
                var moved = element
                moved.x += Double(delta.x)
                moved.y += Double(delta.y)
                return moved
            }
        }
        if !selectedShapeIDs.isEmpty {
            shapes = shapes.map { shape in
                guard selectedShapeIDs.contains(shape.id) else { return shape }
                var moved = shape
                moved.x += Double(delta.x)
                moved.y += Double(delta.y)
                return moved
            }
        }
    }

    /// Delete the selected strokes and texts (one undo step).
    private func deleteSelection() {
        guard !selectedIndices.isEmpty || !selectedTextIDs.isEmpty
            || !selectedShapeIDs.isEmpty || !selectedImageIDs.isEmpty else { return }
        pushUndo()
        drawing.strokes = drawing.strokes.enumerated()
            .filter { !selectedIndices.contains($0.offset) }
            .map(\.element)
        texts = texts.filter { !selectedTextIDs.contains($0.id) }
        shapes = shapes.filter { !selectedShapeIDs.contains($0.id) }
        images = images.filter { !selectedImageIDs.contains($0.id) }
        selectedIndices.removeAll()
        selectedTextIDs.removeAll()
        selectedShapeIDs.removeAll()
        selectedImageIDs.removeAll()
        syncToModel()
    }

    /// Bounding box chrome around the selected strokes and texts (content → board).
    @ViewBuilder
    private var selectionChrome: some View {
        let strokeBoxes = selectedIndices.compactMap { index -> CGRect? in
            guard index < drawing.strokes.count else { return nil }
            let b = Self.bounds(of: drawing.strokes[index])
            return b.isNull ? nil : b
        }
        let textBoxes = texts.filter { selectedTextIDs.contains($0.id) }
            .map { Self.textFrame(of: $0) }
        let shapeBoxes = shapes.filter { selectedShapeIDs.contains($0.id) }
            .map { Self.contentFrame(of: $0) }
        let boxes = strokeBoxes + textBoxes + shapeBoxes
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
        undoStack.append((drawing, texts, shapes, images))
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
        redoStack.append((drawing, texts, shapes, images))
        drawing = previous.drawing
        texts = previous.texts
        shapes = previous.shapes
        images = previous.images
        selectedIndices.removeAll()
        selectedTextIDs.removeAll()
        selectedShapeIDs.removeAll()
        textEditing = nil
        labelShapeID = nil
        syncToModel()
    }

    private func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append((drawing, texts, shapes, images))
        drawing = next.drawing
        texts = next.texts
        shapes = next.shapes
        images = next.images
        selectedIndices.removeAll()
        selectedTextIDs.removeAll()
        selectedShapeIDs.removeAll()
        textEditing = nil
        labelShapeID = nil
        syncToModel()
    }

    private func clear() {
        guard !drawing.strokes.isEmpty || !texts.isEmpty || !shapes.isEmpty else { return }
        pushUndo()
        drawing = PKDrawing()
        texts = []
        shapes = []
        images = []
        selectedIndices.removeAll()
        selectedTextIDs.removeAll()
        selectedShapeIDs.removeAll()
        textEditing = nil
        labelShapeID = nil
        syncToModel()
    }

    // MARK: Toolbar (PKToolPicker is UIKit-only; custom chrome is cross-platform)

    private var toolbar: some View {
        HStack(spacing: 10) {
            ForEach([SketchTool.pen, .marker, .eraser], id: \.self) { candidate in
                toolButton(candidate)
            }

            Divider().frame(height: 14)

            // Shapes browser (Freeform-style): one control, the label mirrors
            // the active shape.
            Menu {
                ForEach(SketchTool.shapes, id: \.self) { candidate in
                    Button {
                        tool = candidate
                    } label: {
                        if tool == candidate {
                            Label(candidate.title, systemImage: candidate.icon)
                        } else {
                            Text(candidate.title)
                        }
                    }
                }
            } label: {
                Image(systemName: tool.isShape ? tool.icon : "square.on.square.dashed")
                    .font(.system(size: 14, weight: tool.isShape ? .semibold : .regular))
                    .frame(width: 30, height: 22)
                    .background {
                        if tool.isShape {
                            Capsule().fill(Color.accentColor.opacity(0.16))
                        }
                    }
                    .overlay {
                        if tool.isShape {
                            Capsule().strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1)
                        }
                    }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .foregroundStyle(tool.isShape ? Color.accentColor : Color.secondary)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: tool)
            .accessibilityIdentifier("sketchShapesMenu")

            toolButton(.text)
            toolButton(.select)

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

            Button(action: insertImage) {
                Image(systemName: "photo")
            }
            .buttonStyle(.borderless)
            .help("Insert Image")
            .accessibilityIdentifier("sketchInsertImage")

            // Foreground (ink) + background (board) color pair — PPT-style.
            // The fg picker drives pen/marker ink, shape strokes, and text
            // color; the bg picker sets the board background.
            SketchColorPicker(
                title: "Ink Color",
                selection: Binding(
                    get: { SketchTextSupport.hex(from: inkColor) },
                    set: { inkColor = $0.map { SketchTextSupport.hexColor($0) } ?? .black }
                ),
                identifier: "sketchInk"
            )
            SketchColorPicker(
                title: "Shape Fill",
                supportsNone: true,
                selection: Binding(
                    get: {
                        shapes.last { selectedShapeIDs.contains($0.id) }?.fillColor ?? lastShapeFill
                    },
                    set: { applyShapeFill($0) }
                ),
                identifier: "sketchShapeFill"
            )

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

    /// One flat tool button (the shape tools live in the shapes Menu). The
    /// active tool gets a capsule highlight + weight bump + spring pop so the
    /// current selection reads at a glance.
    private func toolButton(_ candidate: SketchTool) -> some View {
        let active = tool == candidate
        return Button {
            tool = candidate
        } label: {
            Image(systemName: candidate.icon)
                .font(.system(size: 14, weight: active ? .semibold : .regular))
                .scaleEffect(active ? 1.12 : 1)
                .frame(width: 30, height: 22)
                .background {
                    if active {
                        Capsule().fill(Color.accentColor.opacity(0.16))
                    }
                }
                .overlay {
                    if active {
                        Capsule().strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1)
                    }
                }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(active ? Color.accentColor : Color.secondary)
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: tool)
        .accessibilityIdentifier("sketchTool" + candidate.rawValue.prefix(1).uppercased()
                                 + candidate.rawValue.dropFirst())
        .accessibilityAddTraits(active ? [.isSelected] : [])
        .help(candidate.title + " (\(Self.shortcut(for: candidate)))")
    }

    /// Photoshop-convention letter for a tool (empty = no shortcut).
    static func shortcut(for candidate: SketchTool) -> String {
        switch candidate {
        case .select: return "V"
        case .pen: return "B"
        case .marker: return "H"
        case .eraser: return "E"
        case .text: return "T"
        default: return candidate.isShape ? "U" : ""
        }
    }
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
        Image(nsImage: Self.render(drawing, rect: rect))
            .resizable()
    }

    /// PKDrawing.image() adapts ink PRESENTATION to the current appearance —
    /// under Dark, black ink renders white and white renders black (a
    /// Notes-style legibility feature). Force aqua so the raster shows the
    /// literal ink colors the user picked, matching the live drag preview.
    static func render(_ drawing: PKDrawing, rect: CGRect) -> NSImage {
        let bounds = rect.width > 0 && rect.height > 0 ? rect : CGRect(x: 0, y: 0, width: 1, height: 1)
        var image: NSImage?
        if let aqua = NSAppearance(named: .aqua) {
            aqua.performAsCurrentDrawingAppearance {
                image = drawing.image(from: bounds, scale: 2)
            }
        }
        return image ?? drawing.image(from: bounds, scale: 2)
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

/// One resize grip: a small white dot with an accent ring.
private struct ResizeHandle: View {
    var body: some View {
        Circle()
            .fill(Color.white)
            .frame(width: 9, height: 9)
            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 1.5))
            .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
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
            // The library shapes preview through the SAME dense samples the
            // commit will use — what you drag is exactly what you get.
            if let kind = tool.shapeKind {
                Path { path in
                    let samples = ShapeGeometry.points(for: kind, from: start, to: end)
                    guard let first = samples.first else { return }
                    path.move(to: first)
                    for sample in samples.dropFirst() {
                        path.addLine(to: sample)
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: width, lineJoin: .round))
            } else {
                EmptyView()
            }
        }
    }
}

/// Outline path of a model shape in LOCAL (0-based, fitted) coordinates:
/// dense ShapeGeometry samples for the bbox kinds, the endpoint pair for
/// line/arrow (plus the arrowhead). Local origin = the shape's bounding-box
/// top-left, so negative line extents stay inside the frame.
struct ShapeElementPath: Shape {
    let shape: SketchShape
    var fitScale: CGFloat = 1

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let kind = shape.shapeKind else { return path }
        let minX = min(shape.x, shape.x + shape.width)
        let minY = min(shape.y, shape.y + shape.height)
        let a = CGPoint(x: CGFloat(shape.x - minX) * fitScale,
                        y: CGFloat(shape.y - minY) * fitScale)
        let b = CGPoint(x: a.x + CGFloat(shape.width) * fitScale,
                        y: a.y + CGFloat(shape.height) * fitScale)
        let samples = ShapeGeometry.points(for: kind, from: a, to: b)
        guard let first = samples.first else { return path }
        path.move(to: first)
        for sample in samples.dropFirst() {
            path.addLine(to: sample)
        }
        if kind == .arrow {
            let angle = atan2(b.y - a.y, b.x - a.x)
            let head = max(CGFloat(10), CGFloat(shape.strokeWidth) * 4)
            for sign in [CGFloat.pi * 0.82, -CGFloat.pi * 0.82] {
                let tip = CGPoint(x: b.x + head * cos(angle + sign),
                                  y: b.y + head * sin(angle + sign))
                path.move(to: b)
                path.addLine(to: tip)
            }
        }
        return path
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
