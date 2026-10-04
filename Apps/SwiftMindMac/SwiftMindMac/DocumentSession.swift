import SwiftUI
import SwiftMindCore

@MainActor
final class DocumentSession: ObservableObject {
    public private(set) var store: MapStore
    /// Map structure/content — triggers document dirty sync.
    @Published private(set) var contentRevision: UInt64 = 0
    /// Selection-only — redraw selection without rewriting the document.
    @Published private(set) var selectionRevision: UInt64 = 0
    @Published var viewMode: ViewMode = .map
    /// One-shot canvas action from the command palette. The canvas consumes
    /// it on appear or when it is already showing.
    @Published var canvasPaletteRequest: CanvasPaletteRequest?
    @Published private(set) var toast: StatusToast?

    /// Live floating-editor draft (virtual-H1 document) while the note editor
    /// is open; rendered views prefer it over the stored model values.
    @Published var liveNoteDocument: (nodeID: NodeID, document: String)?

    /// Canvas pan/zoom. View-state only — not persisted, not undoable.
    /// Offset changes do not publish: the canvas keeps its own pan state so
    /// dragging does not rebuild the sidebar and inspector every frame.
    var viewport = CanvasViewport()
    /// Published only when the zoom changes, so toolbar enablement stays current.
    @Published private(set) var viewportScale: Double = 1
    /// Set when the map had no saved viewport: the canvas zooms to fit the
    /// whole map on first layout, then clears this.
    var needsInitialFit = false
    /// Last laid-out canvas size (for keyboard zoom when the canvas is unmounted).
    private(set) var lastCanvasWidth: Double = 0
    private(set) var lastCanvasHeight: Double = 0
    private(set) var lastAnchorView: Point2D?
    private(set) var pointerIsOverCanvas = false
    var commandScrollRemainder: Double = 0

    /// True when showing the My Brain vault navigator (not a map file).
    var isBrainMode: Bool = false
    /// Double-click / Return activation (open map or toggle folder in brain mode).
    var onPrimaryActivate: (() -> Void)?
    /// My Brain fold. Persists by folder path and reloads children from disk.
    /// A folded vault is stored with no children, so unfolding only a flag
    /// would show an empty folder.
    var onBrainFold: ((NodeID, Bool) -> Void)?
    /// Fired after content mutations (for autosave).
    var onContentChanged: (() -> Void)?
    /// Fired after pan/zoom (persisted separately from the map file).
    var onViewportChanged: (() -> Void)?
    /// Picture files beside the document. Note text stores only the path.
    let noteAssets: NoteAssetStore

    private var toastClearTask: Task<Void, Never>?
    /// One sleeper for a burst of trackpad zoom. Publishing scale every tick
    /// rebuilds the sidebar and inspector.
    private var scalePublishTask: Task<Void, Never>?
    private var scalePublishGeneration: UInt64 = 0

    /// Back-compat for views that observe a single tick.
    var revision: UInt64 { contentRevision &+ selectionRevision }

    enum CanvasPaletteRequest: Equatable {
        case rename(NodeID?)
        case toggleFollow
    }

    enum ViewMode: String, CaseIterable, Identifiable {
        case map
        case outline

        var id: String { rawValue }

        var title: String {
            switch self {
            case .map: return "Map"
            case .outline: return "Outline"
            }
        }
    }

    init(map: MindMap, noteAssets: NoteAssetStore? = nil) {
        self.noteAssets = noteAssets ?? NoteAssetStore()
        self.store = MapStore(map: map)
        applyMediaSize()
        self.contentRevision = store.contentRevision
        self.selectionRevision = store.selectionRevision
    }

    /// Push the Settings media size into the layout engine (sketch boards and
    /// note-image estimates scale to it). Publishes the revision so views
    /// re-render, but does not fire `onContentChanged` — view state only,
    /// the document is not dirty.
    func applyMediaSize() {
        var config = store.layoutConfig
        config.mediaMaxSize = MediaSizeLevel.current.points
        guard config != store.layoutConfig else { return }
        store.layoutConfig = config
        contentRevision = store.contentRevision
        selectionRevision = store.selectionRevision
    }

    func syncFromDocument(_ map: MindMap) {
        store.replaceMap(map)
        publishContent()
    }

    func exportMap() -> MindMap {
        store.map
    }

    /// Point note image paths at a renamed assets folder.
    func replaceInNotes(from: String, to: String) {
        let before = store.contentRevision
        store.replaceInNotes(from: from, to: to)
        if store.contentRevision != before {
            publishContent()
        }
    }

    func toggleSelection(_ id: NodeID) {
        store.toggleSelection(id)
        selectionRevision = store.selectionRevision
    }

    func apply(_ command: any MapCommand) {
        do {
            try store.dispatch(command)
            publishContent()
            announceSuccess(for: command)
        } catch {
            presentError(error)
        }
    }

    func applyQuiet(_ command: any MapCommand) {
        do {
            try store.dispatch(command)
            publishContent()
        } catch {
            presentError(error)
        }
    }

    /// Bridge path: throws instead of toasting so the caller reports back.
    func applyThrowing(_ command: any MapCommand) throws {
        try store.dispatch(command)
        publishContent()
    }

    func undo() {
        do {
            try store.undo()
            publishContent()
            showToast("Undid last change", kind: .info)
        } catch {
            presentError(error)
        }
    }

    func redo() {
        do {
            try store.redo()
            publishContent()
            showToast("Redid last change", kind: .info)
        } catch {
            presentError(error)
        }
    }

    /// Selection only — does not mark the document dirty or relayout geometry.
    func select(_ id: NodeID, additive: Bool = false) {
        store.select(id, additive: additive)
        selectionRevision = store.selectionRevision
        objectWillChange.send()
    }

    /// Clear focus (Esc / click on blank canvas).
    func clearSelection() {
        store.clearSelection()
        selectionRevision = store.selectionRevision
        objectWillChange.send()
    }

    func rememberCanvasLayout(width: Double, height: Double) {
        lastCanvasWidth = width
        lastCanvasHeight = height
    }

    func rememberCanvasPointer(overCanvas: Bool, viewPoint: Point2D?) {
        pointerIsOverCanvas = overCanvas
        if overCanvas {
            lastAnchorView = viewPoint
        } else {
            commandScrollRemainder = 0
        }
    }

    func setCanvasOffset(_ offset: Point2D) {
        viewport.offset = offset
        onViewportChanged?()
    }

    func setCanvasScale(
        _ scale: Double,
        around viewPoint: Point2D,
        width: Double,
        height: Double,
        publishScale: Bool = true
    ) {
        var next = viewport
        next.setScale(scale, anchorView: viewPoint, viewWidth: width, viewHeight: height)
        adoptViewport(next, publishScale: publishScale)
    }

    func panCanvas(by delta: Point2D) {
        var next = viewport
        next.pan(by: delta)
        viewport = next
        onViewportChanged?()
    }

    func replaceViewport(_ next: CanvasViewport) {
        adoptViewport(next)
    }

    private func adoptViewport(_ next: CanvasViewport, publishScale: Bool = true) {
        viewport = next
        if publishScale {
            viewportScale = next.scale
        }
        onViewportChanged?()
    }

    /// Toolbar reads `viewportScale`. Continuous zoom updates the canvas
    /// directly and publishes once the gesture settles.
    func publishViewportScale() {
        if viewportScale != viewport.scale {
            viewportScale = viewport.scale
        }
    }

    func scheduleViewportScalePublish() {
        scalePublishGeneration &+= 1
        let generation = scalePublishGeneration
        if scalePublishTask != nil { return }
        scalePublishTask = Task { @MainActor in
            var seen = generation
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 150_000_000)
                if Task.isCancelled { break }
                if scalePublishGeneration == seen {
                    publishViewportScale()
                    break
                }
                seen = scalePublishGeneration
            }
            scalePublishTask = nil
            if scalePublishGeneration != seen {
                scheduleViewportScalePublish()
            }
        }
    }

    func zoomIn(publishScale: Bool = true) {
        applyZoomStep(.in, publishScale: publishScale)
    }

    func zoomOut(publishScale: Bool = true) {
        applyZoomStep(.out, publishScale: publishScale)
    }

    func handleCommandScroll(deltaY: Double, precise: Bool, publishScale: Bool = true) {
        guard !isBrainMode else { return }
        if precise {
            commandScrollRemainder += deltaY
            while commandScrollRemainder >= 1 {
                commandScrollRemainder -= 1
                zoomIn(publishScale: publishScale)
            }
            while commandScrollRemainder <= -1 {
                commandScrollRemainder += 1
                zoomOut(publishScale: publishScale)
            }
        } else {
            if deltaY > 0 { zoomIn(publishScale: publishScale) }
            else if deltaY < 0 { zoomOut(publishScale: publishScale) }
        }
    }

    func resetToActualSize() {
        guard !isBrainMode else { return }
        var next = viewport
        let anchor = zoomAnchor()
        next.resetToActualSize(
            anchorView: anchor,
            viewWidth: lastCanvasWidth,
            viewHeight: lastCanvasHeight
        )
        adoptViewport(next)
    }

    /// Fit the whole map into the view (Zoom to Fit / first open of a map
    /// with no saved viewport). No-op until the canvas reports its size.
    func zoomToFit() {
        guard !isBrainMode else { return }
        let next = viewport.fittedToContent(
            contentBounds: store.snapshot().bounds,
            viewWidth: lastCanvasWidth,
            viewHeight: lastCanvasHeight
        )
        guard next != viewport else { return }
        adoptViewport(next)
    }

    private func applyZoomStep(_ step: ZoomStep, publishScale: Bool = true) {
        guard !isBrainMode else { return }
        var next = viewport
        next.zoomByStepping(
            step,
            anchorView: zoomAnchor(),
            viewWidth: lastCanvasWidth,
            viewHeight: lastCanvasHeight
        )
        adoptViewport(next, publishScale: publishScale)
    }

    private func zoomAnchor() -> Point2D {
        CanvasViewport.commandAnchor(
            pointerOverCanvas: pointerIsOverCanvas,
            lastAnchorView: lastAnchorView,
            viewWidth: lastCanvasWidth,
            viewHeight: lastCanvasHeight
        )
    }

    var canUndo: Bool { store.canUndo }
    var canRedo: Bool { store.canRedo }

    func showToast(_ message: String, kind: StatusToast.Kind = .info, duration: TimeInterval = 2.2) {
        toastClearTask?.cancel()
        toast = StatusToast(message: message, kind: kind)
        toastClearTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            if toast?.message == message {
                toast = nil
            }
        }
    }

    func dismissToast() {
        toastClearTask?.cancel()
        toast = nil
    }

    private func announceSuccess(for command: any MapCommand) {
        switch command.name {
        case "DeleteNodes":
            showToast("Deleted · ⌘Z to undo", kind: .success)
        case "MoveNode":
            showToast("Moved node · ⌘Z to undo", kind: .success)
        default:
            break
        }
    }

    private func presentError(_ error: Error) {
        let message: String
        if let mapError = error as? MapCommandError {
            message = mapError.userFacingMessage
        } else {
            message = error.localizedDescription
        }
        showToast(message, kind: .error, duration: 3.2)
    }

    private func publishContent() {
        contentRevision = store.contentRevision
        selectionRevision = store.selectionRevision
        objectWillChange.send()
        onContentChanged?()
    }

    func activatePrimary() {
        onPrimaryActivate?()
    }
}

/// Scroll state of one expanded note card. Owned by the canvas, not the
/// session, so a wheel tick does not republish the sidebar and inspector.
struct NoteCardScrollState: Equatable {
    /// Offset in map points, applied before the card is scaled with the zoom.
    var offset: CGFloat
    /// Rendered card document at the time the offset was last set; a mismatch
    /// means the note was re-committed and the offset resets to the top.
    var document: String
}

extension MapCommandError {
    var userFacingMessage: String {
        switch self {
        case .nodeNotFound:
            return "That node is no longer available"
        case .cannotDeleteRoot:
            return "Can't delete the central idea"
        case .invalidParent:
            return "Can't move a node into its own branch"
        }
    }
}
