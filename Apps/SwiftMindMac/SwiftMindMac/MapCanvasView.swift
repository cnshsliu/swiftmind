import SwiftUI
import SwiftMindCore
import AppKit

struct MapCanvasView: View {
    @ObservedObject var session: DocumentSession

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

    private static let minScale: CGFloat = 0.25
    private static let maxScale: CGFloat = 3
    private static let badgeFontSize: CGFloat = 11
    private static let iconSlot: CGFloat = 14

    var body: some View {
        // Depend on revision so layout redraws after store mutations.
        let _ = session.revision
        let snapshot = session.store.snapshot()

        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    draw(snapshot: snapshot, context: &context, size: size)
                }
                .contentShape(Rectangle())
                .onAppear {
                    canvasSize = geo.size
                }
                .onChange(of: geo.size) { _, newSize in
                    canvasSize = newSize
                }
                .gesture(combinedDragGesture(snapshot: snapshot))
                .simultaneousGesture(magnifyGesture)
                .simultaneousGesture(doubleTapEditGesture(snapshot: snapshot))
                .gesture(tapSelectGesture(snapshot: snapshot))

                if let editingNodeID,
                   let visual = snapshot.nodes.first(where: { $0.id == editingNodeID }) {
                    editOverlay(for: visual, viewSize: geo.size)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .clipped()
        .accessibilityLabel("Mind map canvas")
        // Cancel in-place edit if selection/model removes the node.
        .onChange(of: session.revision) { _, _ in
            if let editingNodeID,
               session.store.map.node(id: editingNodeID) == nil {
                cancelEdit()
            }
        }
    }

    // MARK: - Drawing

    private func draw(snapshot: MapSnapshot, context: inout GraphicsContext, size: CGSize) {
        context.translateBy(x: size.width / 2 + offset.width, y: size.height / 2 + offset.height)
        context.scaleBy(x: scale, y: scale)

        for edge in snapshot.edges {
            var path = Path()
            path.move(to: CGPoint(x: edge.fromPoint.x, y: edge.fromPoint.y))
            path.addLine(to: CGPoint(x: edge.toPoint.x, y: edge.toPoint.y))
            context.stroke(path, with: .color(.secondary), lineWidth: 1.5 / scale)
        }

        for node in snapshot.nodes {
            let rect = CGRect(
                x: node.frame.x,
                y: node.frame.y,
                width: node.frame.width,
                height: node.frame.height
            )
            let path = Path(roundedRect: rect, cornerRadius: 8)

            if let fr = node.style.fillRed,
               let fg = node.style.fillGreen,
               let fb = node.style.fillBlue {
                context.fill(path, with: .color(Color(red: fr, green: fg, blue: fb)))
            } else {
                context.fill(path, with: .color(Color(nsColor: .controlBackgroundColor)))
            }

            let isDropTarget = dropTargetID == node.id && !isPinDragging
            let strokeColor: Color
            if isDropTarget {
                strokeColor = .orange
            } else if node.isSelected {
                strokeColor = .accentColor
            } else {
                strokeColor = Color.secondary.opacity(0.5)
            }
            let strokeWidth = (isDropTarget || node.isSelected ? 2.5 : 1.0) / scale
            context.stroke(path, with: .color(strokeColor), lineWidth: strokeWidth)

            if isDropTarget {
                context.fill(path, with: .color(Color.orange.opacity(0.15)))
            }

            // Dim the node being dragged slightly.
            if dragNodeID == node.id {
                context.fill(path, with: .color(Color.accentColor.opacity(0.12)))
            }

            let textColor = Color(
                red: node.style.textRed,
                green: node.style.textGreen,
                blue: node.style.textBlue
            )

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
                    .foregroundColor(.secondary)
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
                    .foregroundColor(.orange)
                context.draw(
                    pinBadge,
                    at: CGPoint(x: rect.minX + 4, y: rect.minY + 4),
                    anchor: .topLeading
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
        TextField("Title", text: $editDraft)
            .textFieldStyle(.plain)
            .font(.system(
                size: CGFloat(visual.style.fontSize) * scale,
                weight: visual.style.isBold ? .bold : .regular
            ))
            .padding(.horizontal, 6 * scale)
            .padding(.vertical, 4 * scale)
            .background(
                RoundedRectangle(cornerRadius: 8 * scale)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .shadow(radius: 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8 * scale)
                    .stroke(Color.accentColor, lineWidth: 2)
            )
            .frame(width: max(frame.width, 80), height: max(frame.height, 28))
            .position(x: frame.midX, y: frame.midY)
            .focused($editFieldFocused)
            .onSubmit { commitEdit() }
            .onExitCommand { cancelEdit() }
            .onAppear {
                editFieldFocused = true
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
        guard let id = hitTest(location, snapshot: snapshot, viewSize: canvasSize),
              let visual = snapshot.nodes.first(where: { $0.id == id }) else {
            return
        }
        session.select(id)
        editingNodeID = id
        editDraft = visual.text
    }

    private func commitEdit() {
        guard let id = editingNodeID else { return }
        let trimmed = editDraft
        if let node = session.store.map.node(id: id), trimmed != node.text {
            session.apply(SetTextCommand(nodeID: id, newText: trimmed))
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
        // Slightly higher threshold reduces accidental reparent when intending a tap.
        DragGesture(minimumDistance: 6)
            .onChanged { value in
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
                // Don't steal focus from the edit field with a stray single-tap under it.
                if editingNodeID != nil { return }
                if let id = hitTest(event.location, snapshot: snapshot, viewSize: canvasSize) {
                    session.select(id)
                }
            }
    }

    private func doubleTapEditGesture(snapshot: MapSnapshot) -> some Gesture {
        SpatialTapGesture(count: 2)
            .onEnded { event in
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

        for node in snapshot.nodes.reversed() {
            let f = node.frame
            if mapX >= f.x, mapX <= f.x + f.width,
               mapY >= f.y, mapY <= f.y + f.height {
                return node.id
            }
        }
        return nil
    }
}

#Preview {
    MapCanvasView(session: DocumentSession(map: .makeEmpty(title: "Preview")))
}
