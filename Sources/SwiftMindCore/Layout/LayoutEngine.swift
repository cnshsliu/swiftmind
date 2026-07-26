/// Mind-map layout: **left and right sides pack independently** so siblings
/// no longer share one vertical cursor (which caused chaotic fan-out).
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

        appendNode(map.root, frame: rootFrame, depth: 0, side: .auto, selection: selection, into: &nodes)
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

    // MARK: - Measure

    private func measure(_ node: Node) -> (width: Double, height: Double) {
        let cw = max(config.charWidth, node.style.fontSize * 0.55)
        let textWidth = Double(max(1, node.text.count)) * cw
        let iconCount = min(3, node.icons.count)
        let iconWidth = iconCount == 0 ? 0 : Double(iconCount) * config.iconSlotWidth + 4
        var badgeWidth = 0.0
        if !node.noteMarkdown.isEmpty { badgeWidth += config.badgeReserve }
        if node.positionPin != nil { badgeWidth += config.badgeReserve * 0.5 }
        let width = max(
            config.minNodeWidth,
            textWidth + iconWidth + badgeWidth + config.paddingX * 2
        )
        let height = max(config.nodeHeight, node.style.fontSize + 16)
        return (width, height)
    }

    /// Side used for layout: explicit side wins; `.auto` balanced by subtree weight.
    private func assignSides(_ children: [Node]) -> [(Node, NodeSide)] {
        var rightWeight = 0.0
        var leftWeight = 0.0
        var result: [(Node, NodeSide)] = []
        result.reserveCapacity(children.count)

        for child in children {
            let side: NodeSide
            if child.side == .left || child.side == .right {
                side = child.side
            } else {
                // Balance auto children onto the lighter side (by subtree height).
                side = leftWeight <= rightWeight ? .right : .left
            }
            let w = subtreeHeight(child)
            if side == .left {
                leftWeight += w
            } else {
                rightWeight += w
            }
            result.append((child, side))
        }
        return result
    }

    /// Height of auto-layout block on one side (pinned kids excluded from stack).
    private func subtreeHeight(_ node: Node) -> Double {
        let selfH = measure(node).height
        guard !node.isFolded else { return selfH }
        let autoKids = node.children.filter { $0.positionPin == nil }
        guard !autoKids.isEmpty else { return selfH }
        // For height estimate, take max of left/right columns of this node.
        let assigned = assignSides(autoKids)
        let leftH = columnHeight(assigned.filter { $0.1 == .left }.map(\.0))
        let rightH = columnHeight(assigned.filter { $0.1 == .right }.map(\.0))
        return max(selfH, max(leftH, rightH))
    }

    private func columnHeight(_ nodes: [Node]) -> Double {
        guard !nodes.isEmpty else { return 0 }
        return nodes.map { subtreeHeight($0) }.reduce(0, +)
            + Double(max(0, nodes.count - 1)) * config.verticalGap
    }

    // MARK: - Place

    private func placeChildren(
        of parent: Node,
        parentFrame: Rect2D,
        depth: Int,
        selection: SelectionState,
        nodes: inout [NodeVisual],
        edges: inout [EdgeVisual]
    ) {
        guard !parent.isFolded else { return }

        let assigned = assignSides(parent.children)
        let lefts = assigned.filter { $0.1 == .left }
        let rights = assigned.filter { $0.1 == .right }

        packColumn(
            lefts.map(\.0),
            side: .left,
            parent: parent,
            parentFrame: parentFrame,
            depth: depth,
            selection: selection,
            nodes: &nodes,
            edges: &edges
        )
        packColumn(
            rights.map(\.0),
            side: .right,
            parent: parent,
            parentFrame: parentFrame,
            depth: depth,
            selection: selection,
            nodes: &nodes,
            edges: &edges
        )

        // Pinned children still render (may also appear in left/right lists — place once).
        // assignSides includes all children; pinned are placed in packColumn with pin branch.
    }

    private func packColumn(
        _ children: [Node],
        side: NodeSide,
        parent: Node,
        parentFrame: Rect2D,
        depth: Int,
        selection: SelectionState,
        nodes: inout [NodeVisual],
        edges: inout [EdgeVisual]
    ) {
        let auto = children.filter { $0.positionPin == nil }
        let pinned = children.filter { $0.positionPin != nil }

        let totalH = columnHeight(auto)
        var cursorY = parentFrame.midY - totalH / 2

        for child in auto {
            let size = measure(child)
            let blockH = subtreeHeight(child)
            let centerY = cursorY + blockH / 2
            let x: Double
            if side == .left {
                x = parentFrame.x - config.horizontalGap - size.width
            } else {
                x = parentFrame.x + parentFrame.width + config.horizontalGap
            }
            let frame = Rect2D(
                x: x,
                y: centerY - size.height / 2,
                width: size.width,
                height: size.height
            )
            appendNode(child, frame: frame, depth: depth, side: side, selection: selection, into: &nodes)
            appendEdge(from: parent, parentFrame: parentFrame, to: child, frame: frame, side: side, edges: &edges)
            placeChildren(
                of: child,
                parentFrame: frame,
                depth: depth + 1,
                selection: selection,
                nodes: &nodes,
                edges: &edges
            )
            cursorY += blockH + config.verticalGap
        }

        for child in pinned {
            let size = measure(child)
            let pin = child.positionPin!
            let frame = Rect2D(
                x: pin.x - size.width / 2,
                y: pin.y - size.height / 2,
                width: size.width,
                height: size.height
            )
            appendNode(child, frame: frame, depth: depth, side: side, selection: selection, into: &nodes)
            appendEdge(from: parent, parentFrame: parentFrame, to: child, frame: frame, side: side, edges: &edges)
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

    private func appendEdge(
        from parent: Node,
        parentFrame: Rect2D,
        to child: Node,
        frame: Rect2D,
        side: NodeSide,
        edges: inout [EdgeVisual]
    ) {
        let fromPt = Point2D(
            x: side == .left ? parentFrame.x : parentFrame.x + parentFrame.width,
            y: parentFrame.midY
        )
        let toPt = Point2D(
            x: side == .left ? frame.x + frame.width : frame.x,
            y: frame.midY
        )
        edges.append(EdgeVisual(from: parent.id, to: child.id, fromPoint: fromPt, toPoint: toPt))
    }

    private func appendNode(
        _ node: Node,
        frame: Rect2D,
        depth: Int,
        side: NodeSide,
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
                side: side,
                isFolded: node.isFolded,
                isSelected: selection.selectedIDs.contains(node.id),
                hasNote: !node.noteMarkdown.isEmpty,
                iconIDs: node.icons.map(\.id),
                isPinned: node.positionPin != nil
            )
        )
    }
}
