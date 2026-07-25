import SwiftUI
import SwiftMindCore

struct MapCanvasView: View {
    @ObservedObject var session: DocumentSession

    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    /// Base scale captured at magnify gesture begin (so magnification multiplies, not replaces).
    @State private var magnifyBase: CGFloat = 1
    /// Base pan offset captured at drag gesture begin.
    @State private var panBase: CGSize = .zero
    @State private var canvasSize: CGSize = .zero

    // MARK: Drag reparent
    @State private var dragNodeID: NodeID?
    @State private var isPanning = false
    @State private var dropTargetID: NodeID?
    @State private var dragCurrentLocation: CGPoint?

    // MARK: In-place edit
    @State private var editingNodeID: NodeID?
    @State private var editDraft: String = ""
    @FocusState private var editFieldFocused: Bool

    private static let minScale: CGFloat = 0.25
    private static let maxScale: CGFloat = 3

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

            let isDropTarget = dropTargetID == node.id
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
            // Hide label while editing this node (overlay TextField shows it).
            if editingNodeID != node.id {
                let text = Text(node.text)
                    .font(.system(
                        size: node.style.fontSize,
                        weight: node.style.isBold ? .bold : .regular
                    ))
                    .foregroundColor(textColor)
                context.draw(text, in: rect.insetBy(dx: 6, dy: 4))
            }
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

    /// Single drag: node hit → reparent gesture; empty → pan. Distinguishes pan vs node drag at begin.
    private func combinedDragGesture(snapshot: MapSnapshot) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                // First change: classify start location.
                if dragNodeID == nil && !isPanning {
                    if let id = hitTest(value.startLocation, snapshot: snapshot, viewSize: canvasSize) {
                        // Do not reparent the root; treat as pan instead.
                        if id == session.store.map.root.id {
                            isPanning = true
                            panBase = offset
                        } else {
                            dragNodeID = id
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
                    if let hit = hitTest(value.location, snapshot: snapshot, viewSize: canvasSize),
                       hit != dragNodeID {
                        dropTargetID = hit
                    } else {
                        dropTargetID = nil
                    }
                }
            }
            .onEnded { value in
                defer {
                    dragNodeID = nil
                    dropTargetID = nil
                    dragCurrentLocation = nil
                    isPanning = false
                    panBase = offset
                }

                guard let dragID = dragNodeID else { return }

                guard let target = hitTest(value.location, snapshot: snapshot, viewSize: canvasSize),
                      target != dragID else {
                    // Empty release or self — cancel (no pin in M1).
                    return
                }

                // Append as last child of the drop target. Invalid self/descendant throws — ignore.
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

    // MARK: - Hit testing

    /// Convert a view-space tap into map coordinates by inverting the
    /// canvas transform (center + pan, then scale), then test node frames
    /// back-to-front so later-drawn nodes win.
    private func hitTest(
        _ location: CGPoint,
        snapshot: MapSnapshot,
        viewSize: CGSize
    ) -> NodeID? {
        guard viewSize.width > 0, viewSize.height > 0, scale > 0 else { return nil }

        let mapX = (location.x - viewSize.width / 2 - offset.width) / scale
        let mapY = (location.y - viewSize.height / 2 - offset.height) / scale

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
