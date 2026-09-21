import SwiftUI
import SwiftMindCore
import AppKit
import PencilKit
import UniformTypeIdentifiers

struct MapCanvasView: View {
    @ObservedObject var session: DocumentSession
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(MediaSizeLevel.defaultsKey) private var mediaSizeLevel = MediaSizeLevel.medium.rawValue
    /// Settings' note-editing mode (panel vs directly-on-card); @AppStorage
    /// re-renders on defaults changes, so the toggle applies immediately.
    @AppStorage(NoteEditMode.defaultsKey) private var noteEditMode = NoteEditMode.panel.rawValue

    /// Note-card images scale into the Settings media box.
    private var mediaImageHeight: CGFloat {
        CGFloat((MediaSizeLevel(rawValue: mediaSizeLevel) ?? .medium).points)
    }

    /// Base scale captured on the first pinch tick (so magnification multiplies, not replaces).
    @State private var magnifyBase: CGFloat = 1
    @State private var magnifyGestureActive = false
    /// Base pan offset captured at drag gesture begin.
    @State private var panBase: CGSize = .zero
    @State private var canvasSize: CGSize = .zero

    private var scale: CGFloat { CGFloat(session.viewport.scale) }

    private var offset: CGSize {
        get {
            CGSize(width: session.viewport.offset.x, height: session.viewport.offset.y)
        }
        nonmutating set {
            // Interactive pan limit (drag + scroll): the viewport never shows
            // blank space beyond the content — panning stops flush at the
            // content edges. Glitched huge deltas clamp to the same boundary.
            var candidate = session.viewport
            candidate.offset = Point2D(x: Double(newValue.width), y: Double(newValue.height))
            session.setCanvasOffset(
                candidate.panClampedOffset(
                    contentBounds: session.store.snapshot().bounds,
                    viewWidth: Double(canvasSize.width),
                    viewHeight: Double(canvasSize.height)
                )
            )
        }
    }

    // MARK: Drag reparent / pin / pan
    @State private var dragNodeID: NodeID?
    @State private var isPanning = false
    /// Option+drag pin mode (vs reparent).
    @State private var isPinDragging = false
    @State private var dropTargetID: NodeID?
    @State private var dragCurrentLocation: CGPoint?
    /// Live map-space position while reparent-dragging (ghost).
    @State private var reparentGhostCenter: CGPoint?
    /// External drag & drop (Finder/Safari) — distinct from internal reparent.
    @State private var isExternalDropTargeted = false

    // MARK: In-place edit
    @State private var editingNodeID: NodeID?
    @State private var editDraft: String = ""
    @FocusState private var editFieldFocused: Bool
    /// Canvas must be key-view focused for Return / Delete to work.
    @FocusState private var canvasFocused: Bool
    /// View-space pointer location for hover → Return selects + edits that node.
    @State private var hoverLocation: CGPoint?
    /// Fallback when SwiftUI focus does not deliver key events to the canvas.
    @State private var keyMonitor: Any?
    @State private var scrollMonitor: Any?
    /// Spatial navigation memory: parent → last focused child (h/l returns to it).
    @State private var lastChildByParent: [NodeID: NodeID] = [:]
    /// Follow mode (F): the active node is always panned to the viewport center.
    @State private var followMode = false

    // MARK: Floating note editor
    @State private var noteEditorNodeID: NodeID?
    @State private var noteEditorDraft: String = ""
    /// `.floatingRight` is `e` / ⇧⌘E; `.inPlace` is double-click / ⌘E on any
    /// non-sketch node; `.onCard` (Settings → Notes) hosts the editor at an
    /// expanded card's frame.
    @State private var noteEditorPlacement: NoteEditorPlacement = .floatingRight
    @State private var noteCommitTask: Task<Void, Never>?
    /// Normal-form document of the last committed model state; contentRevision
    /// changes that move the model off this baseline came from outside.
    @State private var lastCommittedNoteDocument: String?
    /// Composed document captured when the editor opened; Esc reverts to this
    /// (unlike `lastCommittedNoteDocument`, which advances with each commit).
    @State private var noteEditorBaseline: String?
    /// One-shot toolbar insertion (image/math/link), consumed by the editor.
    @State private var pendingNoteInsertion: MarkdownInsertion?
    /// Canvas offset stashed when the editor opened (restored on close).
    @State private var preEditorPan: CGSize?
    /// The offset we panned to; restore only if the user hasn't panned since.
    @State private var editorPanTarget: CGSize?
    private static let noteEditorWidth: CGFloat = 420

    // MARK: Sketch (drawing) editor
    @State private var drawingNodeID: NodeID?
    @State private var sketchDraft: Data = Data()
    /// Baseline of the last committed sketch payload; skips no-op commits and
    /// detects external model changes while the editor is open.
    @State private var lastCommittedSketch: Data?
    @State private var sketchCommitTask: Task<Void, Never>?
    /// True once the user drew/erased since open/last commit — close without
    /// edits must not push a redundant SetSketchCommand.
    @State private var sketchIsDirty = false
    @State private var sketchTool: SketchTool = .pen
    @State private var sketchInkColor: NSColor = .black
    /// Board the editing overlay currently shows (grows as strokes near edges).
    @State private var sketchEditorSize: CGSize = CGSize(width: 800, height: 600)

    /// Classic wheel mice report deltas in line units (~1 per notch) and need
    /// a points-per-notch distance; precise devices (trackpads, smooth-scroll
    /// mice) already deliver point deltas and pan 1:1 like a native scroll view.
    private static let wheelNotchDistance = 40.0

    private static let badgeFontSize: CGFloat = 11
    /// Space reserved at the bottom of a node for the formula result line.
    private static let formulaBadgeStrip: CGFloat = 14
    private static let iconSlot: CGFloat = 14
    /// Extra hit padding in map space (apple-design: ~hysteresis around targets).
    private static let hitPadding: Double = 4

    private var selectedAccessibilityValue: String {
        guard let id = session.store.selection.primary,
              let node = session.store.map.node(id: id) else {
            return "No node selected"
        }
        let t = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Untitled node selected" : "Selected \(t)"
    }

    var body: some View {
        // Content + selection ticks (selection does not rebuild geometry).
        let _ = session.contentRevision
        let _ = session.selectionRevision
        let snapshot = session.store.snapshot()
        let formulaResults = session.store.formulaResults()
        let hoverID = hoveredNodeID(in: snapshot)

        let base = GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // Drawing only — Canvas path fills are not always hit-testable; text is.
                // Keep pointer events on a full-size clear layer so hover/tap use the node rect.
                Canvas { context, size in
                    draw(snapshot: snapshot, formulaResults: formulaResults, hoverID: hoverID, context: &context, size: size)
                }
                .allowsHitTesting(false)

                // Full canvas hit surface: hover + gestures use geometric node frames, not glyphs.
                Color.clear
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            hoverLocation = point
                            session.rememberCanvasPointer(
                                overCanvas: true,
                                viewPoint: Point2D(x: Double(point.x), y: Double(point.y))
                            )
                        case .ended:
                            hoverLocation = nil
                            session.rememberCanvasPointer(overCanvas: false, viewPoint: nil)
                        }
                    }
                    // High-priority tap for snappy selection; drag only after real movement.
                    .highPriorityGesture(tapSelectGesture(snapshot: snapshot))
                    .gesture(combinedDragGesture(snapshot: snapshot))
                    .simultaneousGesture(magnifyGesture)
                    .simultaneousGesture(doubleTapEditGesture(snapshot: snapshot))
                    .contextMenu {
                        if !session.isBrainMode,
                           let id = hoveredNodeID(in: snapshot) ?? session.store.selection.primary {
                            NodeContextMenu(session: session, nodeID: id)
                        }
                    }

                // Below the edit overlay: editing a title must not sit behind a card.
                // The card under the on-card editor hides (no double text).
                ForEach(snapshot.nodes.filter { $0.isNoteExpanded && $0.id != onCardEditingNodeID }) { visual in
                    noteCard(for: visual, viewSize: geo.size)
                }

                if let editorID = noteEditorNodeID,
                   let visual = snapshot.nodes.first(where: { $0.id == editorID }) {
                    noteEditorOverlay(for: visual, viewSize: geo.size)
                }

                if let editingNodeID,
                   let visual = snapshot.nodes.first(where: { $0.id == editingNodeID }) {
                    editOverlay(for: visual, viewSize: geo.size)
                }

                // Sketch editing: scrim eats canvas gestures, the large
                // borderless board above it accepts strokes anywhere inside.
                if drawingNodeID != nil {
                    Rectangle()
                        .fill(Color.black.opacity(colorScheme == .dark ? 0.35 : 0.08))
                        .contentShape(Rectangle())
                        .onTapGesture { closeSketchEditor() }
                }
                if let sketchID = drawingNodeID,
                   let visual = snapshot.nodes.first(where: { $0.id == sketchID }) {
                    sketchEditorOverlay(for: visual, viewSize: geo.size)
                }

                if followMode {
                    VStack {
                        HStack {
                            Spacer()
                            Label("Follow", systemImage: "scope")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.regularMaterial, in: Capsule())
                                .foregroundStyle(.secondary)
                                .padding(10)
                        }
                        Spacer()
                    }
                    .allowsHitTesting(false)
                }
            }
            .onAppear {
                canvasSize = geo.size
                session.rememberCanvasLayout(width: Double(geo.size.width), height: Double(geo.size.height))
                healRestoredViewport(viewSize: geo.size)
                fitViewportIfNeeded()
            }
            // Bootstrap swaps in a new session (with the saved viewport
            // restored) AFTER this view first appeared — heal then too.
            .onChange(of: ObjectIdentifier(session)) { _, _ in
                healRestoredViewport(viewSize: canvasSize)
                fitViewportIfNeeded()
            }
            .onChange(of: geo.size) { _, newSize in
                canvasSize = newSize
                session.rememberCanvasLayout(width: Double(newSize.width), height: Double(newSize.height))
                // Resizing the window changes the pan limits — re-clamp.
                offset = offset
            }
            // Any zoom change (pinch, ⌘-scroll, menu) can strand the view at
            // the edges — re-apply the never-blank pan clamp. Only touches
            // the offset, never the scale, so this cannot re-trigger itself.
            .onChange(of: session.viewport.scale) { _, _ in
                offset = offset
            }
            // Focus target for keyboard: Return = rename, Delete = remove (non-root).
            .focusable()
            .focused($canvasFocused)
            .focusEffectDisabled()
            .onKeyPress(.return) {
                guard editingNodeID == nil, noteEditorNodeID == nil, drawingNodeID == nil else { return .ignored }
                if session.isBrainMode {
                    // Brain: select under pointer, then open map / toggle folder.
                    if let hover = hoverLocation,
                       let id = hitTest(hover, snapshot: snapshot, viewSize: canvasSize) {
                        session.select(id)
                    }
                    session.activatePrimary()
                    return .handled
                }
                // Hover target wins: select that node, then edit its title.
                beginTitleEditPreferringHover(snapshot: snapshot)
                return .handled
            }
            .onKeyPress(.delete) {
                guard editingNodeID == nil, noteEditorNodeID == nil, drawingNodeID == nil else { return .ignored }
                deleteSelectionIfAllowed()
                return .handled
            }
            .onKeyPress(.init("\u{7F}")) { // forward delete on some keyboards
                guard editingNodeID == nil, noteEditorNodeID == nil, drawingNodeID == nil else { return .ignored }
                deleteSelectionIfAllowed()
                return .handled
            }
            // Esc clears the current focus (editing handles Esc itself).
            .onKeyPress(.escape) {
                if drawingNodeID != nil {
                    closeSketchEditor()
                    return .handled
                }
                guard editingNodeID == nil, noteEditorNodeID == nil else { return .ignored }
                session.clearSelection()
                return .handled
            }
            // Spatial navigation: arrows + hjkl. h/l move relative to the
            // branch side (left branch: h = outward to children, l = parent;
            // right branch reversed), j/k = next/previous sibling.
            .onKeyPress(.leftArrow) { navigateKey(.left) }
            .onKeyPress(.rightArrow) { navigateKey(.right) }
            .onKeyPress(.downArrow) { navigateKey(.down) }
            .onKeyPress(.upArrow) { navigateKey(.up) }
            .onKeyPress(.init("h")) { plainLetterKey { navigateKey(.left) } }
            .onKeyPress(.init("l")) { plainLetterKey { navigateKey(.right) } }
            .onKeyPress(.init("j")) { plainLetterKey { navigateKey(.down) } }
            .onKeyPress(.init("k")) { plainLetterKey { navigateKey(.up) } }
            // Follow mode: bare `f` only. ⌘F is search (must not be stolen).
            .onKeyPress(.init("f")) {
                guard modifiersAreBare() else { return .ignored }
                guard editingNodeID == nil, noteEditorNodeID == nil, drawingNodeID == nil else { return .ignored }
                toggleFollowMode()
                return .handled
            }
            // Note editor (E) and note card expansion (X) for the primary node.
            // Brain pseudo-nodes must not get CompositeAgentCommand mutations.
            // Both are blocked while any editor (title or note) owns the
            // keyboard — otherwise typing "e" inside the note editor would
            // close it.
            .onKeyPress(.init("e")) {
                let mods = NSEvent.modifierFlags.intersection([.command, .shift, .option])
                guard mods.isEmpty else { return .ignored }
                guard editingNodeID == nil, noteEditorNodeID == nil, drawingNodeID == nil,
                      !session.isBrainMode else { return .ignored }
                toggleNoteEditor()
                return .handled
            }
            .onKeyPress(.init("x")) {
                guard modifiersAreBare() else { return .ignored }
                guard editingNodeID == nil, noteEditorNodeID == nil, drawingNodeID == nil,
                      !session.isBrainMode else { return .ignored }
                toggleNoteExpansion()
                return .handled
            }
            // Sketch (D): convert the selected node into a drawing node, or
            // open/close the in-place editor when it already is one.
            .onKeyPress(.init("d")) {
                guard modifiersAreBare() else { return .ignored }
                guard editingNodeID == nil, noteEditorNodeID == nil,
                      !session.isBrainMode else { return .ignored }
                toggleSketchMode()
                return .handled
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvasStageFill(for: colorScheme))
        .clipped()
        .overlay {
            if isExternalDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 2)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(
            of: [
                UTType.swiftmindNode, .fileURL, .url, .image,
                .html, .utf8PlainText, .plainText,
            ],
            isTargeted: $isExternalDropTargeted
        ) { providers, location in
            guard !session.isBrainMode, editingNodeID == nil, drawingNodeID == nil else { return false }
            let snapshot = session.store.snapshot()
            // Drop onto a node = child of that node; empty canvas = child of
            // the selection (or root), pinned at the drop point.
            let hit = hitTest(location, snapshot: snapshot, viewSize: canvasSize)
            let parent = hit ?? session.store.selection.primary ?? session.store.map.root.id
            let pin: Point2D? = hit == nil ? {
                let p = mapPoint(from: location, viewSize: canvasSize)
                return Point2D(x: p.x, y: p.y)
            }() : nil
            ClipboardService.handleDrop(
                providers: providers, parent: parent, pin: pin, into: session
            )
            return true
        }
        // children: .contain keeps mapCanvas discoverable while exposing
        // overlay identifiers (noteEditor, noteCard-*) to XCUITest.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mind map canvas")
        .accessibilityIdentifier("mapCanvas")
        .accessibilityValue(selectedAccessibilityValue)
        .accessibilityAddTraits(.updatesFrequently)
        return withCanvasEvents(base)
    }

    /// Selection/content revision handling, lifecycle hooks, and notification
    /// wiring — extracted from `body` so the type-checker stays under budget.
    private func withCanvasEvents<Content: View>(_ content: Content) -> some View {
        content
        .onChange(of: session.selectionRevision) { _, _ in
            // After click-select, ensure canvas can receive Return/Delete.
            // Never steal focus from the note editor or the in-place editor.
            if editingNodeID == nil, noteEditorNodeID == nil {
                canvasFocused = true
            }
            // Remember which child was last focused under each parent (h/l memory).
            if let primary = session.store.selection.primary,
               let parent = session.store.map.parentID(of: primary) {
                lastChildByParent[parent] = primary
            }
            // Keep active node on-screen when selection moves (e.g. ⌘T / ⇧⌘T).
            keepPrimaryInFrame(animated: !reduceMotion)
        }
        // Cancel in-place edit if selection/model removes the node.
        .onChange(of: session.contentRevision) { _, _ in
            if let editingNodeID,
               session.store.map.node(id: editingNodeID) == nil {
                cancelEdit()
            }
            if let sketchID = drawingNodeID {
                if let node = session.store.map.node(id: sketchID) {
                    // External change (⌘Z, CLI, agent): the model moved off the
                    // last-committed payload. Own commits land exactly on it.
                    if node.sketch != lastCommittedSketch {
                        sketchCommitTask?.cancel()
                        sketchCommitTask = nil
                        sketchDraft = node.sketch ?? SketchSupport.emptyDrawingData()
                        lastCommittedSketch = node.sketch
                        sketchIsDirty = false
                    }
                } else {
                    // Node vanished — close without committing.
                    closeSketchEditor(committing: false)
                }
            }
            if let id = noteEditorNodeID {
                if let node = session.store.map.node(id: id) {
                    // External change (⌘Z, CLI, agent bridge): the model moved
                    // off the last-committed baseline. Own commits land exactly
                    // on it, so they never trigger this reload. Cancel any
                    // pending debounce commit — it would clobber the undo.
                    let modelDoc = NoteDocument.compose(title: node.text, body: node.noteMarkdown)
                    if modelDoc != lastCommittedNoteDocument {
                        noteCommitTask?.cancel()
                        noteCommitTask = nil
                        noteEditorDraft = modelDoc
                        session.liveNoteDocument = (id, modelDoc)
                        lastCommittedNoteDocument = modelDoc
                    }
                } else {
                    // Node vanished — close without committing, restoring pan.
                    closeNoteEditor(committing: false)
                }
            }
            // Expanded-card scroll offsets die with the card or a re-commit.
            resetStaleNoteCardScrolls()
            // New/moved nodes change layout — pan so primary stays in view.
            keepPrimaryInFrame(animated: !reduceMotion)
        }
        .onAppear { installKeyMonitor() }
        .onDisappear {
            removeKeyMonitor()
            // Leaving the canvas (e.g. outline mode) must not leak the live
            // draft: commit so the last keystrokes land, then clear the channel.
            if noteEditorNodeID != nil {
                closeNoteEditor(committing: true)
            }
            if drawingNodeID != nil {
                closeSketchEditor(committing: true)
            }
            session.liveNoteDocument = nil
            session.rememberCanvasPointer(overCanvas: false, viewPoint: nil)
            session.commandScrollRemainder = 0
        }
        .onReceive(NotificationCenter.default.publisher(for: .swiftMindCanvasReturn)) { _ in
            guard editingNodeID == nil, noteEditorNodeID == nil, drawingNodeID == nil else { return }
            beginTitleEditPreferringHover(snapshot: session.store.snapshot())
        }
        // ⌘Enter while the note editor is open (from the key monitor).
        .onReceive(NotificationCenter.default.publisher(for: .swiftMindCanvasCommitNoteEditor)) { _ in
            guard noteEditorNodeID != nil else { return }
            closeNoteEditor(committing: true)
        }
        // Context-menu Rename: plain title editing even on noted nodes.
        .onReceive(NotificationCenter.default.publisher(for: .swiftMindRenameNode)) { note in
            handleRenameNotification(note)
        }
        .onReceive(NotificationCenter.default.publisher(for: .swiftMindCanvasDelete)) { _ in
            guard editingNodeID == nil, noteEditorNodeID == nil, drawingNodeID == nil else { return }
            deleteSelectionIfAllowed()
        }
        .onReceive(NotificationCenter.default.publisher(for: .swiftMindToggleNoteEditor)) { _ in
            guard editingNodeID == nil else { return }
            toggleNoteEditor()
        }
        .onReceive(NotificationCenter.default.publisher(for: .swiftMindEditNoteInPlace)) { note in
            guard !session.isBrainMode else { return }
            if let id = note.object as? NodeID {
                beginEdit(nodeID: id, snapshot: session.store.snapshot())
            } else {
                beginEditPreferringHover(snapshot: session.store.snapshot())
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .swiftMindToggleNoteExpansion)) { _ in
            guard editingNodeID == nil else { return }
            toggleNoteExpansion()
        }
        .onReceive(NotificationCenter.default.publisher(for: .swiftMindToggleSketch)) { note in
            guard editingNodeID == nil, !session.isBrainMode else { return }
            if let id = note.object as? NodeID {
                session.select(id)
                beginSketch(on: id)
            } else {
                toggleSketchMode()
            }
        }
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [session] event in
            // ⌘Return commits & closes the open note editor — posted as a
            // notification because this monitor holds a stale View copy, and
            // placed before the text-editing guard because the editor's
            // NSTextView would otherwise swallow it. (`liveNoteDocument` is
            // non-nil exactly while the note editor is open.)
            if (event.keyCode == 36 || event.keyCode == 76),
               event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
               session.liveNoteDocument != nil {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .swiftMindCanvasCommitNoteEditor, object: nil)
                }
                return nil
            }
            // Don't steal keys from real text editing (inspector, outline, map field).
            if let fr = event.window?.firstResponder, fr is NSTextView || fr is NSTextField {
                return event
            }
            // 36 = Return, 76 = keypad Enter
            if event.keyCode == 36 || event.keyCode == 76 {
                DispatchQueue.main.async {
                    // Pulse triggers onChange → edit under hover / selection.
                    // (Cannot mutate @State from a stale View copy inside the monitor.)
                    NotificationCenter.default.post(name: .swiftMindCanvasReturn, object: nil)
                }
                return nil
            }
            // 51 = delete, 117 = forward delete
            if event.keyCode == 51 || event.keyCode == 117 {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .swiftMindCanvasDelete, object: nil)
                }
                return nil
            }
            return event
        }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [session] event in
            guard session.pointerIsOverCanvas else { return event }
            if session.isBrainMode { return event }
            // No map panning under the open sketch editor.
            if SketchEventGuard.editorIsActive { return event }
            if let fr = event.window?.firstResponder as? NSView,
               fr is NSTextView || fr is NSTextField,
               let content = event.window?.contentView {
                let p = content.convert(event.locationInWindow, from: nil)
                if let hit = content.hitTest(p),
                   hit === fr || hit.isDescendant(of: fr) || fr.isDescendant(of: hit) {
                    return event
                }
            }
            // An expanded, overflowing note card under the pointer scrolls its
            // content instead of panning the map (cards are hit-test-transparent,
            // so the map's wheel monitor drives them). Non-overflowing cards
            // fall through to the normal pan below.
            if !event.modifierFlags.contains(.command),
               let pointer = session.lastAnchorView,
               let cardID = overflowingNoteCardID(at: CGPoint(x: pointer.x, y: pointer.y)) {
                let dy = event.hasPreciseScrollingDeltas
                    ? CGFloat(event.scrollingDeltaY)
                    : CGFloat(event.scrollingDeltaY) * Self.wheelNotchDistance
                scrollNoteCard(cardID, by: dy)
                return nil
            }
            if event.modifierFlags.contains(.command) {
                session.handleCommandScroll(
                    deltaY: Double(event.deltaY),
                    precise: event.hasPreciseScrollingDeltas
                )
            } else {
                session.commandScrollRemainder = 0
                let dx = Double(event.scrollingDeltaX)
                let dy = Double(event.scrollingDeltaY)
                // Trackpad / smooth-scroll mouse: content follows the finger
                // 1:1 (multiplying here is what felt runaway). Classic wheel
                // mice report ~1 line per notch and get a fixed distance.
                // Both route through the clamped `offset` setter so the map
                // can never be scrolled into a blank viewport.
                let step = event.hasPreciseScrollingDeltas
                    ? Point2D(x: dx, y: dy)
                    : Point2D(x: dx * Self.wheelNotchDistance, y: dy * Self.wheelNotchDistance)
                offset = CGSize(
                    width: offset.width + CGFloat(step.x),
                    height: offset.height + CGFloat(step.y)
                )
            }
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
            self.scrollMonitor = nil
        }
    }

    private func deleteSelectionIfAllowed() {
        let root = session.store.map.root.id
        var ids = session.store.selection.selectedIDs.filter { $0 != root }
        if ids.isEmpty,
           let hover = hoverLocation,
           let hovered = hitTest(hover, snapshot: session.store.snapshot(), viewSize: canvasSize),
           hovered != root {
            // No focus — Delete applies to the node under the pointer.
            ids = [hovered]
        }
        guard !ids.isEmpty else {
            if session.store.selection.selectedIDs.isEmpty {
                session.showToast("Nothing to delete", kind: .error)
            } else {
                session.showToast("Can't delete the central idea", kind: .error)
            }
            return
        }
        session.apply(DeleteNodesCommand(nodeIDs: Array(ids)))
    }

    // MARK: - Spatial navigation (hjkl / arrows)

    private enum NavDirection { case left, right, up, down }

    private func navigateKey(_ direction: NavDirection) -> KeyPress.Result {
        guard editingNodeID == nil, noteEditorNodeID == nil, drawingNodeID == nil else { return .ignored }
        navigate(direction)
        return .handled
    }

    private func navigate(_ direction: NavDirection) {
        let snapshot = session.store.snapshot()
        guard let current = session.store.selection.primary,
              let visual = snapshot.nodes.first(where: { $0.id == current }) else { return }
        let map = session.store.map

        let target: NodeID?
        switch direction {
        case .up:
            target = sameSideSibling(of: current, visual: visual, offset: -1, snapshot: snapshot)
        case .down:
            target = sameSideSibling(of: current, visual: visual, offset: 1, snapshot: snapshot)
        case .left, .right:
            target = horizontalTarget(from: current, visual: visual, direction: direction, snapshot: snapshot)
        }
        guard let target, target != current else { return }
        session.select(target)
    }

    /// Next/previous sibling restricted to the CURRENT BRANCH SIDE — j/k
    /// walk one visual column (children alternate left/right around the
    /// center, plain sibling order zigzags between the columns).
    private func sameSideSibling(
        of current: NodeID, visual: NodeVisual, offset: Int, snapshot: MapSnapshot
    ) -> NodeID? {
        let map = session.store.map
        guard let parentID = map.parentID(of: current),
              let parent = map.node(id: parentID) else { return nil }
        func side(of id: NodeID) -> NodeSide? {
            snapshot.nodes.first { $0.id == id }?.side
        }
        let column = parent.children.filter { side(of: $0.id) == visual.side }
        guard let index = column.firstIndex(where: { $0.id == current }) else {
            return SpatialNavigator.sibling(of: current, in: map, offset: offset)
        }
        let target = index + offset
        guard column.indices.contains(target) else { return nil }
        return column[target].id
    }

    private func horizontalTarget(
        from current: NodeID,
        visual: NodeVisual,
        direction: NavDirection,
        snapshot: MapSnapshot
    ) -> NodeID? {
        let map = session.store.map
        if visual.depth == 0 {
            // Root: left → left-side child, right → right-side child.
            let wanted: NodeSide = direction == .left ? .left : .right
            return outwardChild(of: current, preferredSide: wanted, snapshot: snapshot)
        }
        // Outward = away from the center on this branch's side:
        // left branch → h is outward, l is toward the center; right branch reversed.
        let outward = (visual.side == .left) == (direction == .left)
        if outward {
            return outwardChild(of: current, preferredSide: nil, snapshot: snapshot)
        }
        // First-level "inward" crosses to the mirror node on the OTHER side
        // (same column index, clamped to the last when that side is
        // shorter) instead of landing on the center node.
        if visual.depth == 1,
           let mirror = mirrorFirstLevelNode(of: current, visual: visual, snapshot: snapshot) {
            return mirror
        }
        return map.parentID(of: current)
    }

    /// The same-index node on the opposite side among the root's first-level
    /// children (column order per side; clamped to the last if shorter).
    private func mirrorFirstLevelNode(
        of current: NodeID, visual: NodeVisual, snapshot: MapSnapshot
    ) -> NodeID? {
        let map = session.store.map
        let children = map.root.children
        func side(of id: NodeID) -> NodeSide? {
            snapshot.nodes.first { $0.id == id }?.side
        }
        let other: NodeSide = visual.side == .left ? .right : .left
        let ownColumn = children.filter { side(of: $0.id) == visual.side }
        let otherColumn = children.filter { side(of: $0.id) == other }
        guard !otherColumn.isEmpty,
              let index = ownColumn.firstIndex(where: { $0.id == current }) else {
            return nil
        }
        return otherColumn[min(index, otherColumn.count - 1)].id
    }

    /// Child to move to. A folded node unfolds instead of moving (next press
    /// navigates in). Honors the last-focused-child memory; root prefers a
    /// child on `preferredSide` (snapshot-resolved).
    private func outwardChild(of id: NodeID, preferredSide: NodeSide?, snapshot: MapSnapshot) -> NodeID? {
        let map = session.store.map
        guard let node = map.node(id: id), !node.children.isEmpty else { return nil }
        if node.isFolded {
            session.applyQuiet(SetFoldedCommand(nodeID: id, isFolded: false))
            return nil
        }
        let remembered = lastChildByParent[id]
        if let preferredSide {
            let childIDs = Set(node.children.map(\.id))
            if let remembered,
               childIDs.contains(remembered),
               snapshot.nodes.first(where: { $0.id == remembered })?.side == preferredSide {
                return remembered
            }
            if let match = snapshot.nodes.first(where: { childIDs.contains($0.id) && $0.side == preferredSide }) {
                return match.id
            }
        }
        return SpatialNavigator.childToFocus(of: id, in: map, remembered: remembered)
    }

    // MARK: - Hover / visibility

    /// F toggles follow mode: every selection/layout change re-centers the
    /// active node instead of just nudging it into the safe margin.
    private func toggleFollowMode() {
        followMode.toggle()
        if followMode {
            centerPrimary(animated: !reduceMotion)
            session.showToast("Follow mode on — active node stays centered", kind: .info)
        } else {
            session.showToast("Follow mode off", kind: .info)
        }
    }

    /// Follow mode centers the active node; otherwise just keep it in view.
    private func keepPrimaryInFrame(animated: Bool) {
        guard noteEditorNodeID == nil else { return }
        if followMode {
            centerPrimary(animated: animated)
        } else {
            ensurePrimaryVisible(animated: animated)
        }
    }

    /// Pan so the primary selection sits exactly at the viewport center.
    private func centerPrimary(animated: Bool) {
        guard canvasSize.width > 40, canvasSize.height > 40 else { return }
        guard let primary = session.store.selection.primary else { return }
        let snapshot = session.store.snapshot()
        guard let visual = snapshot.nodes.first(where: { $0.id == primary }) else { return }

        // Inverse of viewFrame: node center lands on the viewport center.
        let target = CGSize(
            width: -(visual.frame.x + visual.frame.width / 2) * Double(scale),
            height: -(visual.frame.y + visual.frame.height / 2) * Double(scale)
        )
        guard target != offset else { return }
        let apply = {
            offset = target
            panBase = target
        }
        if animated {
            withAnimation(.easeOut(duration: 0.22)) { apply() }
        } else {
            apply()
        }
    }

    private func hoveredNodeID(in snapshot: MapSnapshot) -> NodeID? {
        guard let hover = hoverLocation, canvasSize.width > 0 else { return nil }
        return hitTest(hover, snapshot: snapshot, viewSize: canvasSize)
    }

    /// A viewport restored from saved preferences can strand the map entirely
    /// offscreen (one bad write poisons every launch after). An offset may
    /// never exceed the content extent plus a few screens of panning —
    /// anything beyond that is garbage: reset rather than nudge. Runs on
    /// appear and whenever bootstrap swaps the session (the saved viewport is
    /// restored only then). The session setters are used (not direct
    /// assignment) so the healed state persists over the poison.
    private func healRestoredViewport(viewSize: CGSize) {
        guard viewSize.width > 40, viewSize.height > 40 else { return }
        let vp = session.viewport
        let bounds = session.store.snapshot().bounds
        let limitX = bounds.width * vp.scale + Double(viewSize.width) * 3 + 80
        let limitY = bounds.height * vp.scale + Double(viewSize.height) * 3 + 80
        guard abs(vp.offset.x) > limitX || abs(vp.offset.y) > limitY else { return }
        session.setCanvasScale(
            1,
            around: Point2D(x: Double(viewSize.width) / 2, y: Double(viewSize.height) / 2),
            width: Double(viewSize.width),
            height: Double(viewSize.height)
        )
        session.setCanvasOffset(Point2D(x: 0, y: 0))
    }

    /// First open of a map with no saved viewport: zoom to fit the whole map.
    /// Runs once per session, after the canvas knows its size.
    private func fitViewportIfNeeded() {
        guard session.needsInitialFit, canvasSize.width > 40, canvasSize.height > 40 else { return }
        session.needsInitialFit = false
        session.zoomToFit()
    }

    /// Pan so the primary selection stays inside a comfortable viewport margin.
    private func ensurePrimaryVisible(animated: Bool) {
        guard canvasSize.width > 40, canvasSize.height > 40 else { return }
        guard let primary = session.store.selection.primary else { return }
        let snapshot = session.store.snapshot()
        guard let visual = snapshot.nodes.first(where: { $0.id == primary }) else { return }

        let margin: CGFloat = 72
        let viewFrame = viewFrame(for: visual.frame, viewSize: canvasSize)
        let bounds = CGRect(
            x: margin,
            y: margin,
            width: canvasSize.width - margin * 2,
            height: canvasSize.height - margin * 2
        )

        // Fully inside the safe rect — nothing to do.
        if bounds.contains(viewFrame) {
            return
        }

        // Nudge so the node center sits inside the safe rect (prefer centering if far out).
        let center = CGPoint(x: viewFrame.midX, y: viewFrame.midY)
        var dx: CGFloat = 0
        var dy: CGFloat = 0

        let farOutside =
            center.x < -margin || center.x > canvasSize.width + margin
            || center.y < -margin || center.y > canvasSize.height + margin

        if farOutside {
            // Center the active node in the viewport.
            dx = canvasSize.width / 2 - center.x
            dy = canvasSize.height / 2 - center.y
        } else {
            if viewFrame.minX < bounds.minX { dx = bounds.minX - viewFrame.minX }
            if viewFrame.maxX > bounds.maxX { dx = bounds.maxX - viewFrame.maxX }
            if viewFrame.minY < bounds.minY { dy = bounds.minY - viewFrame.minY }
            if viewFrame.maxY > bounds.maxY { dy = bounds.maxY - viewFrame.maxY }
        }

        guard dx != 0 || dy != 0 else { return }

        let apply = {
            offset = CGSize(width: offset.width + dx, height: offset.height + dy)
            panBase = offset
        }
        if animated {
            withAnimation(.easeOut(duration: 0.22)) { apply() }
        } else {
            apply()
        }
    }

    // MARK: - Drawing

    private func draw(
        snapshot: MapSnapshot,
        formulaResults: [NodeID: FormulaValue],
        hoverID: NodeID?,
        context: inout GraphicsContext,
        size: CGSize
    ) {
        context.translateBy(x: size.width / 2 + offset.width, y: size.height / 2 + offset.height)
        context.scaleBy(x: scale, y: scale)

        for edge in snapshot.edges {
            let from = CGPoint(x: edge.fromPoint.x, y: edge.fromPoint.y)
            let to = CGPoint(x: edge.toPoint.x, y: edge.toPoint.y)
            var path = Path()
            path.move(to: from)
            // Soft cubic connectors (mind-map taste, not rigid lines).
            let midX = (from.x + to.x) / 2
            path.addCurve(
                to: to,
                control1: CGPoint(x: midX, y: from.y),
                control2: CGPoint(x: midX, y: to.y)
            )
            context.stroke(path, with: .color(Theme.edgeStroke(for: colorScheme)), lineWidth: 1.6 / scale)
        }

        for node in snapshot.nodes {
            let rect = CGRect(
                x: node.frame.x,
                y: node.frame.y,
                width: node.frame.width,
                height: node.frame.height
            )
            let corner: CGFloat = node.depth == 0 ? 12 : 8
            let path = Path(roundedRect: rect, cornerRadius: corner)

            // While editing, the TextField draws the only chrome — skip selection rings here.
            let isEditingThis = editingNodeID == node.id
            let isHovered = hoverID == node.id && !isEditingThis && !node.isSelected

            // Soft elevation under selected nodes (craft / depth).
            if node.isSelected && !isEditingThis {
                let shadowRect = rect.offsetBy(dx: 0, dy: 1.5 / scale)
                let shadowPath = Path(roundedRect: shadowRect, cornerRadius: corner)
                context.fill(
                    shadowPath,
                    with: .color(Color.black.opacity(colorScheme == .dark ? 0.35 : 0.10))
                )
            }

            if let fill = node.style.canvasFillColor {
                context.fill(path, with: .color(fill))
            } else {
                context.fill(path, with: .color(Theme.nodeDefaultFill))
            }

            // Hover tint on top of default fill (not when selected — selection already clear).
            if isHovered {
                context.fill(path, with: .color(Theme.hoverFill))
            }

            let isDropTarget = dropTargetID == node.id && !isPinDragging
            let strokeColor: Color
            if isEditingThis {
                // Underlay only — no stroke (avoids double border with the editor).
                strokeColor = Color.clear
            } else if isDropTarget {
                strokeColor = Theme.dropTarget
            } else if node.isSelected {
                strokeColor = Theme.selectionStroke
            } else if node.isHighlighted {
                strokeColor = Color.yellow.opacity(colorScheme == .dark ? 0.85 : 0.9)
            } else if isHovered {
                strokeColor = Theme.hoverStroke
            } else if node.depth == 0 {
                strokeColor = Color.accentColor.opacity(0.45)
            } else {
                strokeColor = Color.secondary.opacity(colorScheme == .dark ? 0.45 : 0.32)
            }
            if !isEditingThis {
                let strokeWidth: CGFloat
                if isDropTarget || node.isSelected {
                    strokeWidth = 2.75 / scale
                } else if node.isHighlighted {
                    strokeWidth = 2.4 / scale
                } else if isHovered {
                    strokeWidth = 2.0 / scale
                } else if node.depth == 0 {
                    strokeWidth = 1.5 / scale
                } else {
                    strokeWidth = 1.0 / scale
                }
                context.stroke(path, with: .color(strokeColor), lineWidth: strokeWidth)
            }

            if node.isHighlighted && !node.isSelected && !isEditingThis {
                context.fill(path, with: .color(Color.yellow.opacity(colorScheme == .dark ? 0.12 : 0.18)))
            }

            if isDropTarget {
                context.fill(path, with: .color(Theme.dropTarget.opacity(0.14)))
            }

            if dragNodeID == node.id {
                context.fill(path, with: .color(Color.accentColor.opacity(0.10)))
            }

            let textColor: Color = {
                if node.style.isRootAccentStyle { return .white }
                return node.style.canvasTextColor
            }()

            // Icons (up to 3) left of title; shrink text frame.
            let iconIDs = Array(node.iconIDs.prefix(3))
            let iconStripWidth = iconIDs.isEmpty
                ? 0
                : CGFloat(iconIDs.count) * Self.iconSlot + 4

            if !iconIDs.isEmpty {
                var x = rect.minX + 6
                let midY = rect.midY
                for iconID in iconIDs {
                    let symbol = NodeIcon.sfSymbolNames[iconID] ?? "questionmark"
                    let badge = Text(Image(systemName: symbol))
                        .font(.system(size: Self.badgeFontSize))
                        .foregroundColor(textColor.opacity(0.9))
                    context.draw(badge, at: CGPoint(x: x + Self.iconSlot / 2, y: midY), anchor: .center)
                    x += Self.iconSlot
                }
            }

            // Hide label while editing this node (overlay TextField shows it);
            // expanded nodes render the note card, sketch nodes the drawing board.
            if editingNodeID != node.id && !node.isNoteExpanded && !node.hasSketch {
                let formulaStrip: CGFloat = formulaResults[node.id] == nil ? 0 : Self.formulaBadgeStrip
                let textRect = rect.insetBy(dx: 6, dy: 4)
                let adjustedTextRect = CGRect(
                    x: textRect.minX + iconStripWidth,
                    y: textRect.minY,
                    width: max(0, textRect.width - iconStripWidth),
                    height: max(0, textRect.height - formulaStrip)
                )
                let text = Text(node.text)
                    .font(.system(
                        size: node.style.fontSize,
                        weight: node.style.isBold ? .bold : .regular
                    ))
                    .foregroundColor(textColor)
                context.draw(text, in: adjustedTextRect)
            }

            // Sketch node: title strip above a drawing board (the committed
            // strokes, rasterized). The editing overlay draws its own canvas.
            if node.hasSketch && drawingNodeID != node.id {
                let cfg = LayoutConfig()
                let titleH = node.text.isEmpty ? 0 : cfg.sketchTitleLineHeight
                if !node.text.isEmpty {
                    let title = Text(node.text)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(textColor)
                    context.draw(
                        title,
                        in: CGRect(x: rect.minX, y: rect.minY + 2, width: rect.width, height: titleH)
                    )
                }
                let boardW = rect.width - cfg.paddingX * 2
                let boardH = rect.height - 16 - titleH
                let boardRect = CGRect(
                    x: rect.midX - boardW / 2,
                    y: rect.minY + 8 + titleH,
                    width: boardW,
                    height: boardH
                )
                // Light card keeps black ink legible in dark mode.
                context.fill(
                    Path(roundedRect: boardRect, cornerRadius: 4),
                    with: .color(Color(nsColor: .textBackgroundColor))
                )
                if let model = session.store.map.node(id: node.id),
                   let data = model.sketch,
                   let contentW = model.sketchWidth, let contentH = model.sketchHeight,
                   contentW > 0, contentH > 0,
                   // Rasterize at the natural content size; SwiftUI scales the
                   // bitmap into the (possibly much smaller) display boardRect.
                   let image = SketchSupport.image(
                       nodeID: node.id,
                       data: data,
                       boardSize: CGSize(width: contentW, height: contentH),
                       scale: scale
                   ) {
                    context.draw(Image(nsImage: image), in: boardRect)
                } else {
                    // Empty sketch: pencil placeholder.
                    let hint = Text(Image(systemName: "scribble"))
                        .font(.system(size: 16))
                        .foregroundColor(Theme.badgeMuted)
                    context.draw(hint, at: CGPoint(x: boardRect.midX, y: boardRect.midY), anchor: .center)
                }
            }

            // Note glyph — top-right of frame.
            if node.hasNote {
                let noteBadge = Text(Image(systemName: "note.text"))
                    .font(.system(size: Self.badgeFontSize))
                    .foregroundColor(Theme.badgeMuted)
                context.draw(
                    noteBadge,
                    at: CGPoint(x: rect.maxX - 4, y: rect.minY + 4),
                    anchor: .topTrailing
                )
            }

            // Pin badge — top-left of frame.
            if node.isPinned {
                let pinBadge = Text(Image(systemName: "pin.fill"))
                    .font(.system(size: Self.badgeFontSize))
                    .foregroundColor(Theme.pinAccent)
                context.draw(
                    pinBadge,
                    at: CGPoint(x: rect.minX + 4, y: rect.minY + 4),
                    anchor: .topLeading
                )
            }

            if node.isFolded {
                let foldBadge = Text(Image(systemName: "chevron.right.circle.fill"))
                    .font(.system(size: Self.badgeFontSize))
                    .foregroundColor(Color.accentColor.opacity(0.85))
                context.draw(
                    foldBadge,
                    at: CGPoint(x: rect.maxX - 4, y: rect.maxY - 4),
                    anchor: .bottomTrailing
                )
            }

            // Formula result — own line under the title, not overlaid on it.
            if let value = formulaResults[node.id] {
                let formula = session.store.map.node(id: node.id)?.formula
                let badgeText = FormulaBadgeFormatter.text(for: value, formula: formula)
                let isError = FormulaBadgeFormatter.isError(value)
                let badge = Text("= \(badgeText)")
                    .font(.system(size: Self.badgeFontSize, design: .monospaced))
                    .foregroundColor(isError ? Color.red : Theme.badgeMuted)
                context.draw(
                    badge,
                    at: CGPoint(x: rect.midX, y: rect.maxY - 5),
                    anchor: .bottom
                )
            }
        }

        // Live pin preview while Option+dragging.
        if isPinDragging,
           let loc = dragCurrentLocation,
           scale > 0 {
            let mapPt = mapPoint(from: loc, viewSize: size)
            let pinPreview = Text(Image(systemName: "pin.fill"))
                .font(.system(size: 14))
                .foregroundColor(.orange)
            context.draw(pinPreview, at: mapPt, anchor: .center)
        }

        // Ghost while reparent-dragging (shows where the node “is”).
        if !isPinDragging,
           let ghost = reparentGhostCenter,
           let dragID = dragNodeID,
           let visual = snapshot.nodes.first(where: { $0.id == dragID }) {
            let gw = visual.frame.width
            let gh = visual.frame.height
            let ghostRect = CGRect(
                x: ghost.x - gw / 2,
                y: ghost.y - gh / 2,
                width: gw,
                height: gh
            )
            let ghostPath = Path(roundedRect: ghostRect, cornerRadius: 8)
            context.stroke(ghostPath, with: .color(Color.accentColor.opacity(0.7)), lineWidth: 1.5 / scale)
            context.fill(ghostPath, with: .color(Color.accentColor.opacity(0.12)))
        }
    }

    // MARK: - In-place edit overlay

    @ViewBuilder
    private func editOverlay(for visual: NodeVisual, viewSize: CGSize) -> some View {
        let frame = viewFrame(for: visual.frame, viewSize: viewSize)
        // Single accent ring only (no inner node stroke + outer selection ring).
        TextField("Title", text: $editDraft)
            .textFieldStyle(.plain)
            .font(.system(
                size: CGFloat(visual.style.fontSize) * scale,
                weight: visual.style.isBold ? .bold : .regular
            ))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 10 * scale)
            .padding(.vertical, 6 * scale)
            .frame(width: max(frame.width + 8 * scale, 88), height: max(frame.height + 4 * scale, 32))
            .background(
                RoundedRectangle(cornerRadius: 10 * scale, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10 * scale, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2.5)
            )
            .shadow(color: Color.accentColor.opacity(0.25), radius: 4, y: 1)
            .position(x: frame.midX, y: frame.midY)
            .focused($editFieldFocused)
            .focusEffectDisabled() // system focus ring was the "inner" second border
            .onSubmit { commitEdit() }
            .onExitCommand { cancelEdit() }
            .onChange(of: editFieldFocused) { _, focused in
                if !focused, editingNodeID != nil {
                    commitEdit()
                }
            }
            .onAppear {
                canvasFocused = false
                DispatchQueue.main.async {
                    editFieldFocused = true
                }
            }
    }

    /// Read-only rendered markdown card for an expanded node. Hit-testing is
    /// off so canvas selection/gestures keep working through the card; wheel
    /// scrolling over an overflowing card is handled by the canvas scroll
    /// monitor (`scrollNoteCard`), which shifts the content inside the clip.
    @ViewBuilder
    private func noteCard(for visual: NodeVisual, viewSize: CGSize) -> some View {
        let frame = viewFrame(for: visual.frame, viewSize: viewSize)
        let document = noteCardDocument(for: visual.id, fallbackTitle: visual.text)
        let scroll = session.noteCardScroll[visual.id]?.offset ?? 0
        MarkdownTextView(markdown: document, fontSize: 12, maxImageHeight: mediaImageHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .offset(y: -scroll)
            .frame(width: frame.width, height: frame.height, alignment: .topLeading)
            .clipped() // layout height is an estimate; overflow scrolls
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
        )
        .position(x: frame.midX, y: frame.midY)
        .allowsHitTesting(false)
        .accessibilityIdentifier("noteCard-\(visual.id.rawValue)")
    }

    /// The document a card renders: the live editor draft while editing,
    /// otherwise the composed model document.
    private func noteCardDocument(for id: NodeID, fallbackTitle: String) -> String {
        if let live = session.liveNoteDocument, live.nodeID == id {
            return live.document
        }
        let node = session.store.map.node(id: id)
        return NoteDocument.compose(title: node?.text ?? fallbackTitle, body: node?.noteMarkdown ?? "")
    }

    /// Estimated rendered content height of a card's document, in view points.
    private func noteCardContentHeight(for id: NodeID) -> CGFloat {
        let config = session.store.layoutConfig
        let mapPoints = MarkdownSegmenter.estimatedHeight(
            of: noteCardDocument(for: id, fallbackTitle: ""),
            lineHeight: config.expandedNoteLineHeight,
            imageHeight: config.mediaMaxSize
        )
        return CGFloat(mapPoints) * scale
    }

    /// The expanded card under a view-space point, but only when its content
    /// overflows the frame (otherwise the wheel keeps panning the map). The
    /// card being edited on-card is skipped — the editor scrolls natively.
    private func overflowingNoteCardID(at viewPoint: CGPoint) -> NodeID? {
        let viewSize = CGSize(width: session.lastCanvasWidth, height: session.lastCanvasHeight)
        guard viewSize.width > 40, viewSize.height > 40 else { return nil }
        let snapshot = session.store.snapshot()
        guard let id = hitTest(viewPoint, snapshot: snapshot, viewSize: viewSize),
              id != session.liveNoteDocument?.nodeID,
              let visual = snapshot.nodes.first(where: { $0.id == id }),
              visual.isNoteExpanded else { return nil }
        let frame = viewFrame(for: visual.frame, viewSize: viewSize)
        let overflow = noteCardContentHeight(for: id) - frame.height
        return overflow > 1 ? id : nil
    }

    /// Wheel-scroll one card, clamped to [0, overflow]. Positive wheel deltas
    /// move map content down (see the pan branch), so card scroll subtracts
    /// them. A re-committed note (document changed) restarts from the top.
    private func scrollNoteCard(_ id: NodeID, by deltaY: CGFloat) {
        let viewSize = CGSize(width: session.lastCanvasWidth, height: session.lastCanvasHeight)
        let snapshot = session.store.snapshot()
        guard let visual = snapshot.nodes.first(where: { $0.id == id }) else { return }
        let frame = viewFrame(for: visual.frame, viewSize: viewSize)
        let overflow = max(0, noteCardContentHeight(for: id) - frame.height)
        guard overflow > 0 else { return }
        let document = noteCardDocument(for: id, fallbackTitle: visual.text)
        let current = session.noteCardScroll[id]
        let base = current?.document == document ? current?.offset ?? 0 : 0
        let next = min(max(0, base - deltaY), overflow)
        session.noteCardScroll[id] = NoteCardScrollState(offset: next, document: document)
    }

    /// Card scroll offsets die with the card (collapsed or deleted) and reset
    /// to the top when the note is re-committed (document mismatch).
    private func resetStaleNoteCardScrolls() {
        guard !session.noteCardScroll.isEmpty else { return }
        var next = session.noteCardScroll
        var changed = false
        for (id, state) in next {
            guard let node = session.store.map.node(id: id), node.isNoteExpanded else {
                next.removeValue(forKey: id)
                changed = true
                continue
            }
            let document = noteCardDocument(for: id, fallbackTitle: node.text)
            if document != state.document {
                next[id] = NoteCardScrollState(offset: 0, document: document)
                changed = true
            }
        }
        if changed { session.noteCardScroll = next }
    }

    private func handleRenameNotification(_ note: Notification) {
        guard !session.isBrainMode, noteEditorNodeID == nil, drawingNodeID == nil else { return }
        let snapshot = session.store.snapshot()
        if let id = note.object as? NodeID {
            beginTitleEdit(nodeID: id, snapshot: snapshot)
        } else {
            beginTitleEditPreferringHover(snapshot: snapshot)
        }
    }

    /// Markdown editor: floating to the right (`e`), covering the node
    /// (double-click / ⌘E), or hosted at the expanded card's frame when the
    /// on-card mode is on (Settings → Notes). All placements share the draft,
    /// baseline, debounce and undo coalescing; Esc cancels back to the
    /// editor-open baseline, ⌘Enter and click-away commit & close.
    @ViewBuilder
    private func noteEditorOverlay(for visual: NodeVisual, viewSize: CGSize) -> some View {
        let frame = viewFrame(for: visual.frame, viewSize: viewSize)
        Group {
            if noteEditorPlacement == .onCard {
                onCardNoteEditor(frame: frame)
            } else {
                panelNoteEditor(frame: frame, viewSize: viewSize)
            }
        }
        .onChange(of: noteEditorDraft) { _, newValue in
            session.liveNoteDocument = (visual.id, newValue)
            scheduleNoteCommit()
        }
    }

    /// The shared editor (panel and on-card both host it).
    private func noteEditorView(chromeIdentifier: String) -> some View {
        MarkdownEditorView(
            text: $noteEditorDraft,
            insertion: $pendingNoteInsertion,
            onCancel: { closeNoteEditor(committing: false) }, // Esc
            onInsertImage: insertImageIntoNoteEditor,
            chromeIdentifier: chromeIdentifier
        )
    }

    /// Node whose rendered card hides because the on-card editor covers it.
    private var onCardEditingNodeID: NodeID? {
        noteEditorPlacement == .onCard ? noteEditorNodeID : nil
    }

    /// Panel host: floating right of the node or covering it in place, with
    /// the insertion toolbar row on top.
    @ViewBuilder
    private func panelNoteEditor(frame: CGRect, viewSize: CGSize) -> some View {
        let inPlace = noteEditorPlacement == .inPlace
        let width: CGFloat = inPlace ? max(frame.width, 320) : Self.noteEditorWidth
        let height: CGFloat = {
            if inPlace {
                return min(max(frame.height, 220), max(160, viewSize.height - 24))
            }
            return min(480, max(200, viewSize.height - frame.minY - 24))
        }()
        let centerX: CGFloat = inPlace
            ? frame.minX + width / 2
            : frame.maxX + 16 + width / 2
        // Top-aligned with the node, but clamped into the viewport: a node
        // near the window edge must never push the editor off-screen
        // (unreachable = unclosable, and XCTest can't hit-test it).
        let rawCenterY = frame.minY + height / 2
        let minCenterY = height / 2 + 16
        let maxCenterY = max(minCenterY, viewSize.height - height / 2 - 16)
        let centerY = min(max(rawCenterY, minCenterY), maxCenterY)
        noteEditorView(chromeIdentifier: "noteEditorPanel")
            .frame(width: width, height: height)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1.5)
            )
            .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
            .position(x: centerX, y: centerY)
            .accessibilityIdentifier("noteEditorPanel")
    }

    /// On-card host (3a): the editor sits at the expanded card's frame with
    /// the card's chrome plus an accent focus ring. Toolbar lives inside the
    /// host (same as the panel) so hit-testing stays on the card. No
    /// pan-for-editor — the canvas stays put.
    @ViewBuilder
    private func onCardNoteEditor(frame: CGRect) -> some View {
        noteEditorView(chromeIdentifier: "noteEditorOnCard")
        .frame(width: frame.width, height: frame.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1.5)
        )
        .shadow(color: .black.opacity(0.15), radius: 6, y: 1)
        .position(x: frame.midX, y: frame.midY)
        .accessibilityIdentifier("noteEditorOnCard")
    }

    /// Image button: file picker → data-URI markdown line at the caret
    /// (reuses the paste path's normalizer: ≤720pt longest side, PNG, <10 MB).
    private func insertImageIntoNoteEditor() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an image to embed in the note"
        panel.begin { response in
            guard response == .OK, let url = panel.url,
                  let data = try? Data(contentsOf: url),
                  let png = ClipboardService.normalizeImage(data) else { return }
            let name = url.deletingPathExtension().lastPathComponent
            let markdown = "![\(name)](data:image/png;base64,\(png.base64EncodedString()))"
            DispatchQueue.main.async {
                pendingNoteInsertion = MarkdownInsertion(payload: .image(markdown: markdown))
            }
        }
    }

    /// `e` / ⇧⌘E: floating editor to the right of the selected node (or the
    /// on-card editor when the mode is on and the note card is expanded).
    private func toggleNoteEditor() {
        if noteEditorNodeID != nil, noteEditorPlacement == .floatingRight {
            closeNoteEditor()
            return
        }
        guard let primary = session.store.selection.primary else { return }
        openNoteEditor(nodeID: primary, placement: preferredNotePlacement(for: primary, fallback: .floatingRight))
    }

    /// On-card mode (Settings → Notes) applies only to nodes with an expanded
    /// note card; collapsed/empty notes keep the panel editor. No auto-expand:
    /// opening the editor must not mutate the map as a side effect.
    private func preferredNotePlacement(for id: NodeID, fallback: NoteEditorPlacement) -> NoteEditorPlacement {
        guard noteEditMode == NoteEditMode.onCard.rawValue,
              let node = session.store.map.node(id: id),
              node.isNoteExpanded else { return fallback }
        return .onCard
    }

    private func openNoteEditor(nodeID: NodeID, placement: NoteEditorPlacement) {
        if noteEditorNodeID == nodeID, noteEditorPlacement == placement {
            closeNoteEditor()
            return
        }
        if noteEditorNodeID != nil {
            closeNoteEditor(committing: true)
        }
        if editingNodeID != nil {
            commitEdit()
        }
        guard let node = session.store.map.node(id: nodeID) else { return }
        session.select(nodeID)
        noteEditorPlacement = placement
        noteEditorNodeID = nodeID
        noteEditorDraft = NoteDocument.compose(title: node.text, body: node.noteMarkdown)
        lastCommittedNoteDocument = noteEditorDraft
        noteEditorBaseline = noteEditorDraft
        session.liveNoteDocument = (nodeID, noteEditorDraft)
        if placement == .floatingRight {
            stashAndPanForEditor()
        }
    }

    /// `committing == false` is the Esc/cancel path: instead of committing the
    /// draft, the node is reverted to the editor-open baseline (an undoable
    /// command when the debounced commits already moved the model). A vanished
    /// node simply closes, as before.
    private func closeNoteEditor(committing: Bool = true) {
        noteCommitTask?.cancel()
        noteCommitTask = nil
        let closingNodeID = noteEditorNodeID
        if committing {
            // The closing commit still joins the session's coalescing group —
            // one ⌘Z reverts open-to-close.
            commitNoteEditorDraft()
        }
        if let closingNodeID {
            // End the undo-coalescing group with the session. BEFORE the Esc
            // revert so the revert never merges into the group: after a
            // cancel, ⌘Z undoes the revert and a second ⌘Z undoes the session.
            session.store.endCoalescing(key: Self.noteCoalescingKey(for: closingNodeID))
        }
        noteEditorNodeID = nil
        session.liveNoteDocument = nil
        lastCommittedNoteDocument = nil
        if !committing {
            revertNoteToBaseline(nodeID: closingNodeID)
        }
        noteEditorBaseline = nil
        // Restore the pre-editor pan only if the user hasn't panned since.
        if let saved = preEditorPan, let target = editorPanTarget, offset == target {
            let apply = { offset = saved; panBase = saved }
            if reduceMotion { apply() } else {
                withAnimation(.easeOut(duration: 0.22)) { apply() }
            }
        }
        preEditorPan = nil
        editorPanTarget = nil
        canvasFocused = true
    }

    /// Esc cancel: restore the composed document captured at editor-open as
    /// one undoable CompositeAgentCommand. No-op when the model still matches
    /// the baseline (no debounced commit landed) or the node is gone.
    private func revertNoteToBaseline(nodeID: NodeID?) {
        guard let id = nodeID,
              let baseline = noteEditorBaseline,
              let node = session.store.map.node(id: id) else { return }
        let modelDoc = NoteDocument.compose(title: node.text, body: node.noteMarkdown)
        guard modelDoc != baseline else { return }
        let (title, body) = NoteDocument.split(baseline)
        var ops: [MapOp] = []
        if let title, title != node.text { ops.append(.setText(nodeID: id, text: title)) }
        if body != node.noteMarkdown { ops.append(.setNote(nodeID: id, markdown: body)) }
        if !ops.isEmpty {
            session.applyQuiet(CompositeAgentCommand(ops: ops))
        }
    }

    /// Pan the canvas left so the editor fits right of the node.
    private func stashAndPanForEditor() {
        guard let id = noteEditorNodeID,
              let visual = session.store.snapshot().nodes.first(where: { $0.id == id }) else { return }
        let frame = viewFrame(for: visual.frame, viewSize: canvasSize)
        let overflow = frame.maxX + 16 + Self.noteEditorWidth - (canvasSize.width - 16)
        guard overflow > 0 else { return }
        preEditorPan = offset
        let target = CGSize(width: offset.width - overflow, height: offset.height)
        editorPanTarget = target
        let apply = { offset = target; panBase = target }
        if reduceMotion { apply() } else {
            withAnimation(.easeOut(duration: 0.22)) { apply() }
        }
    }

    private func toggleNoteExpansion() {
        guard let primary = session.store.selection.primary,
              let node = session.store.map.node(id: primary) else { return }
        session.applyQuiet(SetNoteExpandedCommand(nodeID: primary, isNoteExpanded: !node.isNoteExpanded))
    }

    /// 1s debounce — each burst is one CompositeAgentCommand carrying the
    /// session coalescing key, so the whole editor session (open → close) is
    /// ONE map-level undo step (spec 2026-09-21, 2c). noteCommitTask is
    /// cleared after firing so "a commit is in flight" is detectable.
    private func scheduleNoteCommit() {
        noteCommitTask?.cancel()
        noteCommitTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            commitNoteEditorDraft()
            noteCommitTask = nil
        }
    }

    private func commitNoteEditorDraft() {
        guard let id = noteEditorNodeID,
              let node = session.store.map.node(id: id) else { return }
        let (title, body) = NoteDocument.split(noteEditorDraft)
        var ops: [MapOp] = []
        if let title, title != node.text { ops.append(.setText(nodeID: id, text: title)) }
        if body != node.noteMarkdown { ops.append(.setNote(nodeID: id, markdown: body)) }
        if ops.isEmpty {
            // Model unchanged — the baseline still tracks its normal form.
            lastCommittedNoteDocument = NoteDocument.compose(title: node.text, body: node.noteMarkdown)
            return
        }
        session.applyQuiet(
            CompositeAgentCommand(ops: ops, coalescingKey: Self.noteCoalescingKey(for: id))
        )
        // Baseline = the normal form the model now holds. A nil split title
        // means no setText op, so the model kept node.text.
        lastCommittedNoteDocument = NoteDocument.compose(title: title ?? node.text, body: body)
    }

    /// All debounced commits of one note-editor session share this key.
    private static func noteCoalescingKey(for id: NodeID) -> String {
        "note-edit:\(id.rawValue)"
    }

    // MARK: - Sketch editor (large borderless board, trim-to-content on commit)

    /// `d` / ⇧⌘D: convert-or-edit. Closing is Esc / Done / scrim tap.
    private func toggleSketchMode() {
        if drawingNodeID != nil {
            closeSketchEditor()
            return
        }
        guard let primary = session.store.selection.primary,
              session.store.map.node(id: primary) != nil else { return }
        beginSketch(on: primary)
    }

    /// Scribble target: empty node takes the board itself; a node with
    /// content gets a fresh child to draw on so nothing is displaced.
    private func beginSketch(on nodeID: NodeID) {
        guard let node = session.store.map.node(id: nodeID) else { return }
        if nodeHasSketchContent(node) || nodeIsEmpty(node) {
            openSketchEditor(nodeID: nodeID)
        } else {
            let newID = NodeID.generate()
            session.apply(InsertChildCommand(parentID: nodeID, newNodeID: newID, text: ""))
            openSketchEditor(nodeID: newID)
        }
    }

    private func nodeHasSketchContent(_ node: Node) -> Bool {
        guard let sketch = node.sketch else { return false }
        return sketch != SketchSupport.emptyDrawingData()
    }

    /// Default title every insert path gives a new node (⌘T, toolbar, palette,
    /// context menu) — a node the user hasn't typed in yet counts as empty.
    private static let untitledNodeText = "New Idea"

    private func nodeIsEmpty(_ node: Node) -> Bool {
        let text = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text.isEmpty || text == Self.untitledNodeText)
            && node.noteMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !nodeHasSketchContent(node)
    }

    private func openSketchEditor(nodeID: NodeID) {
        if noteEditorNodeID != nil {
            closeNoteEditor(committing: true)
        }
        if editingNodeID != nil {
            commitEdit()
        }
        guard let node = session.store.map.node(id: nodeID) else { return }
        session.select(nodeID)
        sketchEditorSize = initialSketchEditorSize
        if let existing = node.sketch {
            // Committed payloads stay in content coordinates — the editor
            // fits them into the board view-only, never rewriting strokes.
            sketchDraft = existing
            lastCommittedSketch = existing
        } else {
            // First open: convert (undoable); placeholder board until content.
            let empty = SketchSupport.emptyDrawingData()
            session.applyQuiet(SetSketchCommand(nodeID: nodeID, sketch: empty, width: nil, height: nil))
            sketchDraft = empty
            lastCommittedSketch = empty
        }
        sketchIsDirty = false
        drawingNodeID = nodeID
        SketchEventGuard.editorIsActive = true
        canvasFocused = true
        // Drawing at deep zoom is unusable — pull in before opening.
        if scale < 0.75 {
            session.setCanvasScale(
                1.0,
                around: Point2D(x: Double(canvasSize.width / 2), y: Double(canvasSize.height / 2)),
                width: Double(canvasSize.width),
                height: Double(canvasSize.height)
            )
        }
    }

    private func closeSketchEditor(committing: Bool = true) {
        sketchCommitTask?.cancel()
        sketchCommitTask = nil
        if committing {
            commitSketchDraft()
        }
        drawingNodeID = nil
        sketchIsDirty = false
        SketchEventGuard.editorIsActive = false
        canvasFocused = true
    }

    /// 1s debounce — each drawing burst is one undo step (note-editor parity).
    private func scheduleSketchCommit() {
        sketchIsDirty = true
        sketchCommitTask?.cancel()
        sketchCommitTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            commitSketchDraft()
            sketchCommitTask = nil
        }
    }

    /// Trim the draft to its stroke bounding box (+ padding), normalize to the
    /// padding origin, and persist. Empty drawing → placeholder board. A draft
    /// that fails to decode is NOT treated as empty — wiping real content on a
    /// transient decode failure is unrecoverable, so we keep the last commit.
    private func commitSketchDraft() {
        guard sketchIsDirty,
              let id = drawingNodeID,
              session.store.map.node(id: id) != nil else { return }
        let padding = LayoutConfig().sketchTrimPadding
        if let trimmed = SketchSupport.trim(sketchDraft, padding: padding) {
            guard trimmed.data != lastCommittedSketch else { return }
            session.applyQuiet(
                SetSketchCommand(
                    nodeID: id,
                    sketch: trimmed.data,
                    width: Double(trimmed.size.width),
                    height: Double(trimmed.size.height)
                )
            )
            lastCommittedSketch = trimmed.data
        } else {
            let decodesToNoStrokes = ((try? PKDrawing(data: sketchDraft))?.strokes.isEmpty) == true
            guard decodesToNoStrokes else { return }
            // All strokes erased — back to the empty placeholder.
            let empty = SketchSupport.emptyDrawingData()
            guard empty != lastCommittedSketch else { return }
            session.applyQuiet(SetSketchCommand(nodeID: id, sketch: empty, width: nil, height: nil))
            lastCommittedSketch = empty
        }
        sketchIsDirty = false
    }

    private var initialSketchEditorSize: CGSize {
        CGSize(
            width: min(max(canvasSize.width * 0.7, 480), max(320, canvasSize.width - 32)),
            height: min(max(canvasSize.height * 0.7, 360), max(240, canvasSize.height - 32))
        )
    }

    /// Large borderless drawing surface centered on the node (clamped into the
    /// viewport) with a compact tool strip. The board size is fixed for the
    /// session — strokes live in content coordinates and the editor fits them
    /// view-only, so nothing shifts under the pen. Esc / Done / scrim tap
    /// commits and closes; the node then shows the trimmed, centered content.
    @ViewBuilder
    private func sketchEditorOverlay(for visual: NodeVisual, viewSize: CGSize) -> some View {
        let frame = viewFrame(for: visual.frame, viewSize: viewSize)
        let editorW = min(sketchEditorSize.width, max(320, viewSize.width - 32))
        let editorH = min(sketchEditorSize.height, max(240, viewSize.height - 64))
        let centerX = min(max(frame.midX, editorW / 2 + 16), viewSize.width - editorW / 2 - 16)
        let centerY = min(max(frame.midY, editorH / 2 + 16), viewSize.height - editorH / 2 - 16)

        SketchEditorView(
            drawingData: $sketchDraft,
            tool: $sketchTool,
            inkColor: $sketchInkColor,
            onStrokeChange: { scheduleSketchCommit() },
            onDone: { closeSketchEditor() }
        )
        .frame(width: editorW, height: editorH + 36)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1.5)
        )
        .shadow(color: .black.opacity(0.25), radius: 10, y: 2)
        .position(x: centerX, y: centerY)
        .onExitCommand { closeSketchEditor() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sketchEditor")
    }

    private func viewFrame(for mapFrame: Rect2D, viewSize: CGSize) -> CGRect {
        let x = mapFrame.x * Double(scale) + Double(viewSize.width) / 2 + Double(offset.width)
        let y = mapFrame.y * Double(scale) + Double(viewSize.height) / 2 + Double(offset.height)
        let w = mapFrame.width * Double(scale)
        let h = mapFrame.height * Double(scale)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func beginEdit(at location: CGPoint, snapshot: MapSnapshot) {
        guard let id = hitTest(location, snapshot: snapshot, viewSize: canvasSize) else {
            return
        }
        beginEdit(nodeID: id, snapshot: snapshot)
    }

    /// ⌘E / double-click: prefer node under pointer; else primary selection.
    private func beginEditPreferringHover(snapshot: MapSnapshot) {
        if let hover = hoverLocation,
           let id = hitTest(hover, snapshot: snapshot, viewSize: canvasSize) {
            beginEdit(nodeID: id, snapshot: snapshot)
            return
        }
        beginEditSelected(snapshot: snapshot)
    }

    private func beginEditSelected(snapshot: MapSnapshot) {
        guard let id = session.store.selection.primary else { return }
        beginEdit(nodeID: id, snapshot: snapshot)
    }

    /// Return / Rename: prefer node under pointer; else primary selection.
    private func beginTitleEditPreferringHover(snapshot: MapSnapshot) {
        if let hover = hoverLocation,
           let id = hitTest(hover, snapshot: snapshot, viewSize: canvasSize) {
            beginTitleEdit(nodeID: id, snapshot: snapshot)
            return
        }
        guard let id = session.store.selection.primary else { return }
        beginTitleEdit(nodeID: id, snapshot: snapshot)
    }

    /// ⌘E / "Edit Note at Node" / double-click: honest note editing. Sketch
    /// nodes route to the drawing board; every other node opens the note
    /// editor in place — even with an empty note (the virtual document is
    /// just `# title`) — or on the card itself when the on-card mode is on
    /// and the note is expanded. Plain title editing stays on Return / Rename.
    private func beginEdit(nodeID: NodeID, snapshot: MapSnapshot) {
        guard snapshot.nodes.contains(where: { $0.id == nodeID }) else { return }
        if let node = session.store.map.node(id: nodeID), node.sketch != nil {
            openSketchEditor(nodeID: nodeID)
            return
        }
        openNoteEditor(nodeID: nodeID, placement: preferredNotePlacement(for: nodeID, fallback: .inPlace))
    }

    /// Return / context-menu Rename: the plain title field. Sketch nodes have
    /// no inline title editor — "editing" them means drawing.
    private func beginTitleEdit(nodeID: NodeID, snapshot: MapSnapshot) {
        guard snapshot.nodes.contains(where: { $0.id == nodeID }) else { return }
        if let node = session.store.map.node(id: nodeID), node.sketch != nil {
            openSketchEditor(nodeID: nodeID)
            return
        }
        if noteEditorNodeID != nil {
            closeNoteEditor(committing: true)
        }
        guard editingNodeID == nil,
              let visual = snapshot.nodes.first(where: { $0.id == nodeID }) else {
            return
        }
        session.select(nodeID)
        editingNodeID = nodeID
        editDraft = visual.text
        DispatchQueue.main.async {
            editFieldFocused = true
        }
    }

    private func commitEdit() {
        guard let id = editingNodeID else { return }
        let trimmed = editDraft
        if let node = session.store.map.node(id: id), trimmed != node.text {
            session.applyQuiet(SetTextCommand(nodeID: id, newText: trimmed))
        }
        editingNodeID = nil
        editFieldFocused = false
    }

    private func cancelEdit() {
        editingNodeID = nil
        editDraft = ""
        editFieldFocused = false
    }

    // MARK: - Gestures

    /// Drag rules (M2 polish):
    /// - **Space held** or start on empty / root → pan canvas
    /// - **Option + node** → pin at release location
    /// - **Node (non-root)** → reparent onto drop target (orange highlight + ghost)
    private func combinedDragGesture(snapshot: MapSnapshot) -> some Gesture {
        // Higher threshold so light clicks stay taps (less "sticky" selection).
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                // Starting a drag ends in-place edit (save first).
                if editingNodeID != nil, dragNodeID == nil, !isPanning {
                    commitEdit()
                }
                if dragNodeID == nil && !isPanning {
                    let mods = NSEvent.modifierFlags
                    // Space or ⌘+drag: always pan (even starting on a node).
                    let forcePan = isSpaceKeyDown() || mods.contains(.command)
                    let optionHeld = mods.contains(.option)

                    if forcePan {
                        isPanning = true
                        panBase = offset
                    } else if let id = hitTest(value.startLocation, snapshot: snapshot, viewSize: canvasSize) {
                        if optionHeld {
                            dragNodeID = id
                            isPinDragging = true
                            session.select(id)
                        } else if id == session.store.map.root.id {
                            isPanning = true
                            panBase = offset
                        } else {
                            dragNodeID = id
                            isPinDragging = false
                            session.select(id)
                        }
                    } else {
                        isPanning = true
                        panBase = offset
                    }
                }

                if isPanning {
                    offset = CGSize(
                        width: panBase.width + value.translation.width,
                        height: panBase.height + value.translation.height
                    )
                } else if dragNodeID != nil {
                    dragCurrentLocation = value.location
                    let mapPt = mapPoint(from: value.location, viewSize: canvasSize)
                    if isPinDragging {
                        dropTargetID = nil
                        reparentGhostCenter = nil
                    } else {
                        reparentGhostCenter = mapPt
                        if let hit = hitTest(value.location, snapshot: snapshot, viewSize: canvasSize),
                           hit != dragNodeID {
                            dropTargetID = hit
                        } else {
                            dropTargetID = nil
                        }
                    }
                }
            }
            .onEnded { value in
                defer {
                    dragNodeID = nil
                    dropTargetID = nil
                    dragCurrentLocation = nil
                    reparentGhostCenter = nil
                    isPanning = false
                    isPinDragging = false
                    panBase = offset
                }

                guard let dragID = dragNodeID else { return }

                if isPinDragging {
                    let mapPt = mapPoint(from: value.location, viewSize: canvasSize)
                    session.apply(
                        SetPinCommand(
                            nodeID: dragID,
                            positionPin: Point2D(x: Double(mapPt.x), y: Double(mapPt.y))
                        )
                    )
                    return
                }

                guard let target = hitTest(value.location, snapshot: snapshot, viewSize: canvasSize),
                      target != dragID else {
                    return
                }

                let index: Int
                if let parent = session.store.map.node(id: target) {
                    index = parent.children.count
                } else {
                    index = 0
                }
                session.apply(
                    MoveNodeCommand(nodeID: dragID, newParentID: target, index: index)
                )
            }
    }

    /// Letter shortcuts (f/h/j/k/l/x) must not swallow ⌘F / ⌘L / etc.
    private func modifiersAreBare() -> Bool {
        NSEvent.modifierFlags.intersection([.command, .option, .control]).isEmpty
    }

    private func plainLetterKey(_ action: () -> KeyPress.Result) -> KeyPress.Result {
        guard modifiersAreBare() else { return .ignored }
        return action()
    }

    /// True while space is physically held (for pan-over-node).
    private func isSpaceKeyDown() -> Bool {
        // kVK_Space = 0x31
        CGEventSource.keyState(.combinedSessionState, key: 0x31)
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if !magnifyGestureActive {
                    magnifyGestureActive = true
                    magnifyBase = scale
                }
                let next = Double(magnifyBase) * Double(value.magnification)
                let anchor: Point2D = {
                    if let hover = hoverLocation {
                        return Point2D(x: Double(hover.x), y: Double(hover.y))
                    }
                    return Point2D(x: Double(canvasSize.width) / 2, y: Double(canvasSize.height) / 2)
                }()
                session.setCanvasScale(
                    next,
                    around: anchor,
                    width: Double(canvasSize.width),
                    height: Double(canvasSize.height)
                )
            }
            .onEnded { _ in
                magnifyBase = scale
                magnifyGestureActive = false
            }
    }

    private func tapSelectGesture(snapshot: MapSnapshot) -> some Gesture {
        SpatialTapGesture()
            .onEnded { event in
                // Click-away commits & closes the note editor; the tap then
                // proceeds as a normal selection tap. Taps on the editor
                // itself never reach here (the overlay owns its hit area).
                if noteEditorNodeID != nil {
                    closeNoteEditor(committing: true)
                }
                // Tap outside the title field commits; then apply selection.
                if editingNodeID != nil {
                    let editFrame: CGRect? = {
                        guard let id = editingNodeID,
                              let visual = snapshot.nodes.first(where: { $0.id == id }) else {
                            return nil
                        }
                        return viewFrame(for: visual.frame, viewSize: canvasSize)
                    }()
                    if let editFrame, editFrame.insetBy(dx: -4, dy: -4).contains(event.location) {
                        // Tap still inside the field — keep editing.
                        return
                    }
                    commitEdit()
                }
                if let id = hitTest(event.location, snapshot: snapshot, viewSize: canvasSize) {
                    session.select(id)
                    canvasFocused = true
                } else {
                    // Click empty canvas: clear focus, still take keyboard focus.
                    session.clearSelection()
                    canvasFocused = true
                }
            }
    }

    private func doubleTapEditGesture(snapshot: MapSnapshot) -> some Gesture {
        // Prefer Return to edit; double-tap still works but is secondary.
        // In My Brain mode: open map file or fold/unfold vault folder.
        SpatialTapGesture(count: 2)
            .onEnded { event in
                if editingNodeID != nil {
                    commitEdit()
                }
                if session.isBrainMode {
                    if let id = hitTest(event.location, snapshot: snapshot, viewSize: canvasSize) {
                        session.select(id)
                        session.activatePrimary()
                    }
                    return
                }
                beginEdit(at: event.location, snapshot: snapshot)
            }
    }

    // MARK: - Hit testing / coordinates

    /// Convert a view-space point into map coordinates by inverting the
    /// canvas transform (center + pan, then scale).
    private func mapPoint(from location: CGPoint, viewSize: CGSize) -> CGPoint {
        guard viewSize.width > 0, viewSize.height > 0, scale > 0 else {
            return .zero
        }
        let mapX = (location.x - viewSize.width / 2 - offset.width) / scale
        let mapY = (location.y - viewSize.height / 2 - offset.height) / scale
        return CGPoint(x: mapX, y: mapY)
    }

    /// Hit-test the full node rectangle (fill + padding), not just glyph bounds.
    /// Uses view-space frames so hover/tap match what is drawn under pan/zoom.
    /// Later-drawn nodes win (front-most).
    private func hitTest(
        _ location: CGPoint,
        snapshot: MapSnapshot,
        viewSize: CGSize
    ) -> NodeID? {
        guard viewSize.width > 0, viewSize.height > 0, scale > 0 else { return nil }

        // Scale padding with zoom so the affordance stays ~constant in screen space.
        let pad = CGFloat(Self.hitPadding) * scale
        for node in snapshot.nodes.reversed() {
            let frame = viewFrame(for: node.frame, viewSize: viewSize)
            if frame.insetBy(dx: -pad, dy: -pad).contains(location) {
                return node.id
            }
        }
        return nil
    }
}

// swiftMindToggleNoteEditor / swiftMindToggleNoteExpansion / swiftMindRenameNode
// are posted from SessionNodeCommands / NodeContextMenu, so they must not be
// file-private.
private enum NoteEditorPlacement {
    case floatingRight
    case inPlace
    /// Settings' "Directly on card" mode: the editor hosts at the expanded
    /// note card's frame (spec 2026-09-21, 3a).
    case onCard
}

extension Notification.Name {
    static let swiftMindToggleNoteEditor = Notification.Name("swiftMindToggleNoteEditor")
    static let swiftMindEditNoteInPlace = Notification.Name("swiftMindEditNoteInPlace")
    static let swiftMindRenameNode = Notification.Name("swiftMindRenameNode")
    static let swiftMindToggleNoteExpansion = Notification.Name("swiftMindToggleNoteExpansion")
    static let swiftMindToggleSketch = Notification.Name("swiftMindToggleSketch")
}

private extension Notification.Name {
    static let swiftMindCanvasReturn = Notification.Name("swiftMind.canvas.return")
    static let swiftMindCanvasDelete = Notification.Name("swiftMind.canvas.delete")
    static let swiftMindCanvasCommitNoteEditor = Notification.Name("swiftMind.canvas.commitNoteEditor")
}

#Preview {
    MapCanvasView(session: DocumentSession(map: .makeEmpty(title: "Preview")))
}
