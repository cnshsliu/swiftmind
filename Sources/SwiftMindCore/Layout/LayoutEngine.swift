public struct LayoutEngine: Sendable {
    public var config: LayoutConfig

    public init(config: LayoutConfig = LayoutConfig()) {
        self.config = config
    }

    public func layout(map: MindMap, selection: SelectionState = SelectionState()) -> MapSnapshot {
        var nodes: [NodeVisual] = []
        var edges: [EdgeVisual] = []
        let rootSize = measure(map.root)
        let rootFrame: Rect2D
        if let pin = map.root.positionPin {
            // Pinned: frame center at pin coordinates.
            rootFrame = Rect2D(
                x: pin.x - rootSize.width / 2,
                y: pin.y - rootSize.height / 2,
                width: rootSize.width,
                height: rootSize.height
            )
        } else {
            rootFrame = Rect2D(
                x: -rootSize.width / 2,
                y: -rootSize.height / 2,
                width: rootSize.width,
                height: rootSize.height
            )
        }
        appendNode(map.root, frame: rootFrame, depth: 0, selection: selection, into: &nodes)
        placeChildren(
            of: map.root,
            parentFrame: rootFrame,
            depth: 1,
            selection: selection,
            nodes: &nodes,
            edges: &edges
        )
        let bounds = nodes.map(\.frame).reduce(rootFrame) { $0.union($1) }.inset(by: -40)
        return MapSnapshot(nodes: nodes, edges: edges, bounds: bounds)
    }

    private func measure(_ node: Node) -> (width: Double, height: Double) {
        let cw = max(config.charWidth, node.style.fontSize * 0.55)
        let width = max(config.minNodeWidth, Double(node.text.count) * cw + config.paddingX * 2)
        let height = max(config.nodeHeight, node.style.fontSize + 16)
        return (width, height)
    }

    private func resolvedSide(_ node: Node, index: Int) -> NodeSide {
        if node.side != .auto { return node.side }
        return index % 2 == 0 ? .right : .left
    }

    /// Height of this node's auto-layout block. Pinned children do not consume stack slots.
    private func subtreeHeight(_ node: Node) -> Double {
        let selfH = measure(node).height
        guard !node.isFolded else { return selfH }
        let autoKids = node.children.filter { $0.positionPin == nil }
        guard !autoKids.isEmpty else { return selfH }
        let kids = autoKids.map { subtreeHeight($0) }.reduce(0, +)
            + Double(max(0, autoKids.count - 1)) * config.verticalGap
        return max(selfH, kids)
    }

    private func placeChildren(
        of parent: Node,
        parentFrame: Rect2D,
        depth: Int,
        selection: SelectionState,
        nodes: inout [NodeVisual],
        edges: inout [EdgeVisual]
    ) {
        guard !parent.isFolded else { return }

        // Auto stack ignores pinned siblings so they pack as if pins were absent.
        let autoChildren = parent.children.filter { $0.positionPin == nil }
        let totalH: Double
        if autoChildren.isEmpty {
            totalH = 0
        } else {
            totalH = autoChildren.map { subtreeHeight($0) }.reduce(0, +)
                + Double(max(0, autoChildren.count - 1)) * config.verticalGap
        }
        var cursorY = parentFrame.midY - totalH / 2

        for (index, child) in parent.children.enumerated() {
            let side = resolvedSide(child, index: index)
            let size = measure(child)
            let frame: Rect2D
            if let pin = child.positionPin {
                // Frame center at (pin.x, pin.y); does not advance auto-stack cursor.
                frame = Rect2D(
                    x: pin.x - size.width / 2,
                    y: pin.y - size.height / 2,
                    width: size.width,
                    height: size.height
                )
            } else {
                let blockH = subtreeHeight(child)
                let centerY = cursorY + blockH / 2
                let x: Double
                if side == .left {
                    x = parentFrame.x - config.horizontalGap - size.width
                } else {
                    x = parentFrame.x + parentFrame.width + config.horizontalGap
                }
                frame = Rect2D(
                    x: x,
                    y: centerY - size.height / 2,
                    width: size.width,
                    height: size.height
                )
                cursorY += blockH + config.verticalGap
            }

            appendNode(child, frame: frame, depth: depth, selection: selection, into: &nodes)
            let from = Point2D(
                x: side == .left ? parentFrame.x : parentFrame.x + parentFrame.width,
                y: parentFrame.midY
            )
            let to = Point2D(
                x: side == .left ? frame.x + frame.width : frame.x,
                y: frame.midY
            )
            edges.append(EdgeVisual(from: parent.id, to: child.id, fromPoint: from, toPoint: to))
            // Children of pinned nodes still place relative to the pinned parent frame.
            placeChildren(
                of: child,
                parentFrame: frame,
                depth: depth + 1,
                selection: selection,
                nodes: &nodes,
                edges: &edges
            )
        }
    }

    private func appendNode(
        _ node: Node,
        frame: Rect2D,
        depth: Int,
        selection: SelectionState,
        into nodes: inout [NodeVisual]
    ) {
        nodes.append(
            NodeVisual(
                id: node.id,
                text: node.text,
                frame: frame,
                style: node.style,
                depth: depth,
                side: node.side,
                isFolded: node.isFolded,
                isSelected: selection.selectedIDs.contains(node.id),
                hasNote: !node.noteMarkdown.isEmpty,
                iconIDs: node.icons.map(\.id),
                isPinned: node.positionPin != nil
            )
        )
    }
}
