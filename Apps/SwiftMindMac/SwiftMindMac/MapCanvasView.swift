import SwiftUI
import SwiftMindCore
import AppKit

struct MapCanvasView: View {
    @ObservedObject var session: DocumentSession
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    /// Base scale captured at magnify gesture begin (so magnification multiplies, not replaces).
    @State private var magnifyBase: CGFloat = 1
    /// Base pan offset captured at drag gesture begin.
    @State private var panBase: CGSize = .zero
    @State private var canvasSize: CGSize = .zero

    // MARK: Drag reparent / pin / pan
    @State private var dragNodeID: NodeID?
    @State private var isPanning = false
    /// Option+drag pin mode (vs reparent).
    @State private var isPinDragging = false
    @State private var dropTargetID: NodeID?
    @State private var dragCurrentLocation: CGPoint?
    /// Live map-space position while reparent-dragging (ghost).
    @State private var reparentGhostCenter: CGPoint?

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
    private static let minScale: CGFloat = 0.25
    private static let maxScale: CGFloat = 3
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
        let hoverID = hoveredNodeID(in: snapshot)

        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    draw(snapshot: snapshot, hoverID: hoverID, context: &context, size: size)
                }
                .contentShape(Rectangle())
                .onAppear {
                    canvasSize = geo.size
                }
                .onChange(of: geo.size) { _, newSize in
                    canvasSize = newSize
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        hoverLocation = point
                    case .ended:
                        hoverLocation = nil
                    }
                }
                // High-priority tap for snappy selection; drag only after real movement.
                .highPriorityGesture(tapSelectGesture(snapshot: snapshot))
                .gesture(combinedDragGesture(snapshot: snapshot))
                .simultaneousGesture(magnifyGesture)
                .simultaneousGesture(doubleTapEditGesture(snapshot: snapshot))

                if let editingNodeID,
                   let visual = snapshot.nodes.first(where: { $0.id == editingNodeID }) {
                    editOverlay(for: visual, viewSize: geo.size)
                }
            }
            // Focus target for keyboard: Return = rename, Delete = remove (non-root).
            .focusable()
            .focused($canvasFocused)
            .focusEffectDisabled()
            .onKeyPress(.return) {
                guard editingNodeID == nil else { return .ignored }
                // Hover target wins: select that node, then edit.
                beginEditPreferringHover(snapshot: snapshot)
                return .handled
            }
            .onKeyPress(.delete) {
                guard editingNodeID == nil else { return .ignored }
                deleteSelectionIfAllowed()
                return .handled
            }
            .onKeyPress(.init("\u{7F}")) { // forward delete on some keyboards
                guard editingNodeID == nil else { return .ignored }
                deleteSelectionIfAllowed()
                return .handled
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvasStageFill(for: colorScheme))
        .clipped()
        // children: .ignore so the identifier is discoverable by XCUITest
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mind map canvas")
        .accessibilityIdentifier("mapCanvas")
        .accessibilityValue(selectedAccessibilityValue)
        .accessibilityAddTraits(.updatesFrequently)
        .onChange(of: session.selectionRevision) { _, _ in
            // After click-select, ensure canvas can receive Return/Delete.
            if editingNodeID == nil {
                canvasFocused = true
            }
            // Keep active node on-screen when selection moves (e.g. ⌘T / ⇧⌘T).
            ensurePrimaryVisible(animated: !reduceMotion)
        }
        // Cancel in-place edit if selection/model removes the node.
        .onChange(of: session.contentRevision) { _, _ in
            if let editingNodeID,
               session.store.map.node(id: editingNodeID) == nil {
                cancelEdit()
            }
            // New/moved nodes change layout — pan so primary stays in view.
            ensurePrimaryVisible(animated: !reduceMotion)
        }
        .onAppear { installKeyMonitor() }
        .onDisappear { removeKeyMonitor() }
        .onReceive(NotificationCenter.default.publisher(for: .swiftMindCanvasReturn)) { _ in
            guard editingNodeID == nil else { return }
            beginEditPreferringHover(snapshot: session.store.snapshot())
        }
        .onReceive(NotificationCenter.default.publisher(for: .swiftMindCanvasDelete)) { _ in
            guard editingNodeID == nil else { return }
            deleteSelectionIfAllowed()
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
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func deleteSelectionIfAllowed() {
        let root = session.store.map.root.id
        let ids = session.store.selection.selectedIDs.filter { $0 != root }
        guard !ids.isEmpty else {
            session.showToast("Can't delete the central idea", kind: .error)
            return
        }
        session.apply(DeleteNodesCommand(nodeIDs: Array(ids)))
    }

    // MARK: - Hover / visibility

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
                } else if isHovered {
                    strokeWidth = 2.0 / scale
                } else if node.depth == 0 {
                    strokeWidth = 1.5 / scale
                } else {
                    strokeWidth = 1.0 / scale
                }
                context.stroke(path, with: .color(strokeColor), lineWidth: strokeWidth)
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

            // Hide label while editing this node (overlay TextField shows it).
            if editingNodeID != node.id {
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
                let next = magnifyBase * value.magnification
                scale = min(Self.maxScale, max(Self.minScale, next))
            }
            .onEnded { _ in
                magnifyBase = scale
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
                    canvasFocused = true
                } else {
                    // Click empty canvas: keep selection, still take keyboard focus.
                    canvasFocused = true
                }
            }
    }

    private func doubleTapEditGesture(snapshot: MapSnapshot) -> some Gesture {
        // Prefer Return to edit; double-tap still works but is secondary.
        SpatialTapGesture(count: 2)
            .onEnded { event in
                if editingNodeID != nil {
                    commitEdit()
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

    /// Convert a view-space tap into map coordinates, then test node frames
    /// back-to-front so later-drawn nodes win.
    private func hitTest(
        _ location: CGPoint,
        snapshot: MapSnapshot,
        viewSize: CGSize
    ) -> NodeID? {
        guard viewSize.width > 0, viewSize.height > 0, scale > 0 else { return nil }

        let pt = mapPoint(from: location, viewSize: viewSize)
        let mapX = Double(pt.x)
        let mapY = Double(pt.y)

        let pad = Self.hitPadding
        for node in snapshot.nodes.reversed() {
            let f = node.frame
            if mapX >= f.x - pad, mapX <= f.x + f.width + pad,
               mapY >= f.y - pad, mapY <= f.y + f.height + pad {
                return node.id
            }
        }
        return nil
    }
}

private extension Notification.Name {
    static let swiftMindCanvasReturn = Notification.Name("swiftMind.canvas.return")
    static let swiftMindCanvasDelete = Notification.Name("swiftMind.canvas.delete")
}

#Preview {
    MapCanvasView(session: DocumentSession(map: .makeEmpty(title: "Preview")))
}
