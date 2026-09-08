import SwiftUI
import SwiftMindCore
import AppKit
import UniformTypeIdentifiers

struct MapCanvasView: View {
    @ObservedObject var session: DocumentSession
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            session.setCanvasOffset(Point2D(x: Double(newValue.width), y: Double(newValue.height)))
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
    @State private var noteCommitTask: Task<Void, Never>?
    /// Normal-form document of the last committed model state; contentRevision
    /// changes that move the model off this baseline came from outside.
    @State private var lastCommittedNoteDocument: String?
    /// Canvas offset stashed when the editor opened (restored on close).
    @State private var preEditorPan: CGSize?
    /// The offset we panned to; restore only if the user hasn't panned since.
    @State private var editorPanTarget: CGSize?
    @FocusState private var noteEditorFocused: Bool
    private static let noteEditorWidth: CGFloat = 420

    private static let badgeFontSize: CGFloat = 11
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

        GeometryReader { geo in
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

                // Below the edit overlay: editing a title must not sit behind a card.
                ForEach(snapshot.nodes.filter(\.isNoteExpanded)) { visual in
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
            }
            .onChange(of: geo.size) { _, newSize in
                canvasSize = newSize
                session.rememberCanvasLayout(width: Double(newSize.width), height: Double(newSize.height))
            }
            // Focus target for keyboard: Return = rename, Delete = remove (non-root).
            .focusable()
            .focused($canvasFocused)
            .focusEffectDisabled()
            .onKeyPress(.return) {
                guard editingNodeID == nil, noteEditorNodeID == nil else { return .ignored }
                if session.isBrainMode {
                    // Brain: select under pointer, then open map / toggle folder.
                    if let hover = hoverLocation,
                       let id = hitTest(hover, snapshot: snapshot, viewSize: canvasSize) {
                        session.select(id)
                    }
                    session.activatePrimary()
                    return .handled
                }
                // Hover target wins: select that node, then edit.
                beginEditPreferringHover(snapshot: snapshot)
                return .handled
            }
            .onKeyPress(.delete) {
                guard editingNodeID == nil, noteEditorNodeID == nil else { return .ignored }
                deleteSelectionIfAllowed()
                return .handled
            }
            .onKeyPress(.init("\u{7F}")) { // forward delete on some keyboards
                guard editingNodeID == nil, noteEditorNodeID == nil else { return .ignored }
                deleteSelectionIfAllowed()
                return .handled
            }
            // Esc clears the current focus (editing handles Esc itself).
            .onKeyPress(.escape) {
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
            .onKeyPress(.init("h")) { navigateKey(.left) }
            .onKeyPress(.init("l")) { navigateKey(.right) }
            .onKeyPress(.init("j")) { navigateKey(.down) }
            .onKeyPress(.init("k")) { navigateKey(.up) }
            // Follow mode toggle: active node stays centered while navigating.
            .onKeyPress(.init("f")) {
                guard editingNodeID == nil, noteEditorNodeID == nil else { return .ignored }
                toggleFollowMode()
                return .handled
            }
            // Note editor (E) and note card expansion (X) for the primary node.
            // Brain pseudo-nodes must not get CompositeAgentCommand mutations.
            // Both are blocked while any editor (title or note) owns the
            // keyboard — otherwise typing "e" inside the note editor would
            // close it.
            .onKeyPress(.init("e")) {
                guard editingNodeID == nil, noteEditorNodeID == nil,
                      !session.isBrainMode else { return .ignored }
                toggleNoteEditor()
                return .handled
            }
            .onKeyPress(.init("x")) {
                guard editingNodeID == nil, noteEditorNodeID == nil,
                      !session.isBrainMode else { return .ignored }
                toggleNoteExpansion()
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
            guard !session.isBrainMode, editingNodeID == nil else { return false }
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
            session.liveNoteDocument = nil
            session.rememberCanvasPointer(overCanvas: false, viewPoint: nil)
            session.optionScrollRemainder = 0
        }
        .onReceive(NotificationCenter.default.publisher(for: .swiftMindCanvasReturn)) { _ in
            guard editingNodeID == nil, noteEditorNodeID == nil else { return }
            beginEditPreferringHover(snapshot: session.store.snapshot())
        }
        .onReceive(NotificationCenter.default.publisher(for: .swiftMindCanvasDelete)) { _ in
            guard editingNodeID == nil, noteEditorNodeID == nil else { return }
            deleteSelectionIfAllowed()
        }
        .onReceive(NotificationCenter.default.publisher(for: .swiftMindToggleNoteEditor)) { _ in
            guard editingNodeID == nil else { return }
            toggleNoteEditor()
        }
        .onReceive(NotificationCenter.default.publisher(for: .swiftMindToggleNoteExpansion)) { _ in
            guard editingNodeID == nil else { return }
            toggleNoteExpansion()
        }
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
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
            if let fr = event.window?.firstResponder as? NSView,
               fr is NSTextView || fr is NSTextField,
               let content = event.window?.contentView {
                let p = content.convert(event.locationInWindow, from: nil)
                if let hit = content.hitTest(p),
                   hit === fr || hit.isDescendant(of: fr) || fr.isDescendant(of: hit) {
                    return event
                }
            }
            if event.modifierFlags.contains(.option) {
                session.handleOptionScroll(
                    deltaY: Double(event.deltaY),
                    precise: event.hasPreciseScrollingDeltas
                )
            } else {
                session.optionScrollRemainder = 0
                session.panCanvas(
                    by: Point2D(x: Double(event.scrollingDeltaX), y: Double(event.scrollingDeltaY))
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
        guard editingNodeID == nil, noteEditorNodeID == nil else { return .ignored }
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
            // expanded nodes render the note card instead of the plain title.
            if editingNodeID != node.id && !node.isNoteExpanded {
                let textRect = rect.insetBy(dx: 6, dy: 4)
                let adjustedTextRect = CGRect(
                    x: textRect.minX + iconStripWidth,
                    y: textRect.minY,
                    width: max(0, textRect.width - iconStripWidth),
                    height: textRect.height
                )
                let text = Text(node.text)
                    .font(.system(
                        size: node.style.fontSize,
                        weight: node.style.isBold ? .bold : .regular
                    ))
                    .foregroundColor(textColor)
                context.draw(text, in: adjustedTextRect)
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

            // Formula result badge — bottom-left of frame ("= 30", "75%", "#ERR").
            if let value = formulaResults[node.id] {
                let formula = session.store.map.node(id: node.id)?.formula
                let badgeText = FormulaBadgeFormatter.text(for: value, formula: formula)
                let isError = FormulaBadgeFormatter.isError(value)
                let badge = Text("= \(badgeText)")
                    .font(.system(size: Self.badgeFontSize, design: .monospaced))
                    .foregroundColor(isError ? Color.red : Theme.badgeMuted)
                context.draw(
                    badge,
                    at: CGPoint(x: rect.minX + 4, y: rect.maxY - 4),
                    anchor: .bottomLeading
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
    /// off so canvas selection/gestures keep working through the card.
    @ViewBuilder
    private func noteCard(for visual: NodeVisual, viewSize: CGSize) -> some View {
        let frame = viewFrame(for: visual.frame, viewSize: viewSize)
        let markdown = session.store.map.node(id: visual.id)?.noteMarkdown ?? ""
        let document: String = {
            if let live = session.liveNoteDocument, live.nodeID == visual.id {
                return live.document
            }
            return NoteDocument.compose(title: visual.text, body: markdown)
        }()
        ScrollView(.vertical) {
            MarkdownTextView(markdown: document, fontSize: 12, maxImageHeight: 160)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .scrollDisabled(true) // overflow is clipped; layout height is an estimate
        .frame(width: frame.width, height: frame.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
        )
        .position(x: frame.midX, y: frame.midY)
        .allowsHitTesting(false)
        .accessibilityIdentifier("noteCard-\(visual.id.rawValue)")
    }

    /// Floating markdown editor: right of the node, top-aligned. The first
    /// line is the virtual H1 (the node title) — see NoteDocument.
    @ViewBuilder
    private func noteEditorOverlay(for visual: NodeVisual, viewSize: CGSize) -> some View {
        let frame = viewFrame(for: visual.frame, viewSize: viewSize)
        let width = Self.noteEditorWidth
        let height = min(480, max(200, viewSize.height - frame.minY - 24))
        TextEditor(text: $noteEditorDraft)
            .font(.system(size: 13, design: .monospaced))
            .padding(8)
            .frame(width: width, height: height)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1.5)
            )
            .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
            .position(x: frame.maxX + 16 + width / 2, y: frame.minY + height / 2)
            .focused($noteEditorFocused)
            .focusEffectDisabled()
            .onExitCommand { closeNoteEditor() }
            .onChange(of: noteEditorDraft) { _, newValue in
                session.liveNoteDocument = (visual.id, newValue)
                scheduleNoteCommit()
            }
            .accessibilityIdentifier("noteEditor")
    }

    private func toggleNoteEditor() {
        if noteEditorNodeID != nil {
            closeNoteEditor()
            return
        }
        guard let primary = session.store.selection.primary,
              let node = session.store.map.node(id: primary) else { return }
        noteEditorNodeID = primary
        noteEditorDraft = NoteDocument.compose(title: node.text, body: node.noteMarkdown)
        lastCommittedNoteDocument = noteEditorDraft
        session.liveNoteDocument = (primary, noteEditorDraft)
        stashAndPanForEditor()
        DispatchQueue.main.async { noteEditorFocused = true }
    }

    private func closeNoteEditor(committing: Bool = true) {
        noteCommitTask?.cancel()
        noteCommitTask = nil
        if committing {
            commitNoteEditorDraft()
        }
        noteEditorNodeID = nil
        session.liveNoteDocument = nil
        lastCommittedNoteDocument = nil
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

    /// 1s debounce — each typing burst is one CompositeAgentCommand, i.e. one
    /// undo step (the scheduleAutosave idiom from AppModel). noteCommitTask is
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
        session.applyQuiet(CompositeAgentCommand(ops: ops))
        // Baseline = the normal form the model now holds. A nil split title
        // means no setText op, so the model kept node.text.
        lastCommittedNoteDocument = NoteDocument.compose(title: title ?? node.text, body: body)
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

    /// Return: prefer node under pointer; else primary selection.
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

    private func beginEdit(nodeID: NodeID, snapshot: MapSnapshot) {
        guard editingNodeID == nil,
              let visual = snapshot.nodes.first(where: { $0.id == nodeID }) else {
            return
        }
        session.select(nodeID)
        editingNodeID = nodeID
        editDraft = visual.text
        // Ensure next frame focuses the field.
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
                // Tap outside the editor commits; then apply selection.
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
                    // Never steal keyboard focus from the open note editor.
                    if noteEditorNodeID == nil {
                        canvasFocused = true
                    }
                } else {
                    // Click empty canvas: clear focus, still take keyboard focus.
                    session.clearSelection()
                    if noteEditorNodeID == nil {
                        canvasFocused = true
                    }
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
                // Don't stack the in-place title editor on an open note editor.
                if noteEditorNodeID == nil {
                    beginEdit(at: event.location, snapshot: snapshot)
                }
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

// swiftMindToggleNoteEditor / swiftMindToggleNoteExpansion are posted from
// SessionNodeCommands in SwiftMindMacApp, so they must not be file-private.
extension Notification.Name {
    static let swiftMindToggleNoteEditor = Notification.Name("swiftMindToggleNoteEditor")
    static let swiftMindToggleNoteExpansion = Notification.Name("swiftMindToggleNoteExpansion")
}

private extension Notification.Name {
    static let swiftMindCanvasReturn = Notification.Name("swiftMind.canvas.return")
    static let swiftMindCanvasDelete = Notification.Name("swiftMind.canvas.delete")
}

#Preview {
    MapCanvasView(session: DocumentSession(map: .makeEmpty(title: "Preview")))
}
