/// Mind-map layout — **Mode 1 (symmetric sides)**:
/// - Only the **root’s first-level children** choose left vs right (explicit or auto-balance).
/// - Every deeper descendant **inherits that branch side** and grows **outward only**
///   (left branch → further left; right branch → further right). Never flips across the parent.
/// - Left and right columns of the root pack independently (separate vertical cursors).
/// - Subtree vertical extent includes all expanded unpinned descendants so siblings clear each other.
///
/// Respects `MindMap.activeFilter` (hide with path-to-root, or highlight).
public struct LayoutEngine: Sendable {
    public var config: LayoutConfig

    public init(config: LayoutConfig = LayoutConfig()) {
        self.config = config
    }

    public func layout(map: MindMap, selection: SelectionState = SelectionState()) -> MapSnapshot {
        var nodes: [NodeVisual] = []
        var edges: [EdgeVisual] = []

        let filter = map.activeFilter
        let sheet = map.styleSheet
        let root = map.root

        let rootSize = measure(root, sheet: sheet)
        let rootFrame: Rect2D
        if let pin = root.positionPin {
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

        appendNode(
            root,
            frame: rootFrame,
            depth: 0,
            side: .auto,
            selection: selection,
            sheet: sheet,
            filter: filter,
            into: &nodes
        )
        // Root children: only place where L/R is decided.
        placeRootChildren(
            of: root,
            parentFrame: rootFrame,
            selection: selection,
            sheet: sheet,
            filter: filter,
            nodes: &nodes,
            edges: &edges
        )

        let bounds = nodes.map(\.frame).reduce(rootFrame) { $0.union($1) }.inset(by: -40)
        return MapSnapshot(nodes: nodes, edges: edges, bounds: bounds)
    }

    // MARK: - Visibility

    /// Children shown under hide-mode filter (match or ancestor of match).
    private func visibleChildren(of node: Node, filter: MapFilter?) -> [Node] {
        guard let filter, filter.mode == .hide else {
            return node.children
        }
        return node.children.filter {
            FilterEvaluator.matchesIncludingDescendants($0, rule: filter.rule)
        }
    }

    private func isHighlighted(_ node: Node, filter: MapFilter?) -> Bool {
        guard let filter, filter.mode == .highlight else { return false }
        return FilterEvaluator.matches(node, rule: filter.rule)
    }

    // MARK: - Measure

    private func measure(_ node: Node, sheet: StyleSheet) -> (width: Double, height: Double) {
        let style = StyleResolver.resolve(node: node, sheet: sheet)
        let cw = max(config.charWidth, style.fontSize * 0.55)
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
        let height = max(config.nodeHeight, style.fontSize + 16)
        return (width, height)
    }

    // MARK: - Side assignment (root children only)

    /// First-level only: explicit `.left`/`.right` wins; `.auto` balances by subtree weight.
    /// On ties prefer **right** (classic mind-map first-child placement).
    private func assignRootChildSides(
        _ children: [Node],
        sheet: StyleSheet,
        filter: MapFilter?
    ) -> [(Node, NodeSide)] {
        var rightWeight = 0.0
        var leftWeight = 0.0
        var result: [(Node, NodeSide)] = []
        result.reserveCapacity(children.count)

        for child in children {
            let side: NodeSide
            if child.side == .left || child.side == .right {
                side = child.side
            } else {
                // Lighter side wins; prefer right when equal.
                side = rightWeight <= leftWeight ? .right : .left
            }
            let w = subtreeHeight(child, sheet: sheet, filter: filter)
            if side == .left {
                leftWeight += w
            } else {
                rightWeight += w
            }
            result.append((child, side))
        }
        return result
    }

    /// Vertical extent of a node plus all expanded unpinned descendants
    /// (single outward column — Mode 1 never splits a branch left+right).
    private func subtreeHeight(_ node: Node, sheet: StyleSheet, filter: MapFilter?) -> Double {
        let selfH = measure(node, sheet: sheet).height
        guard !node.isFolded else { return selfH }
        let kids = visibleChildren(of: node, filter: filter).filter { $0.positionPin == nil }
        guard !kids.isEmpty else { return selfH }
        return max(selfH, columnHeight(kids, sheet: sheet, filter: filter))
    }

    private func columnHeight(_ nodes: [Node], sheet: StyleSheet, filter: MapFilter?) -> Double {
        guard !nodes.isEmpty else { return 0 }
        return nodes.map { subtreeHeight($0, sheet: sheet, filter: filter) }.reduce(0, +)
            + Double(max(0, nodes.count - 1)) * config.verticalGap
    }

    // MARK: - Place

    /// Place depth-1 children: assign L/R, then pack each side as an independent column.
    private func placeRootChildren(
        of root: Node,
        parentFrame: Rect2D,
        selection: SelectionState,
        sheet: StyleSheet,
        filter: MapFilter?,
        nodes: inout [NodeVisual],
        edges: inout [EdgeVisual]
    ) {
        guard !root.isFolded else { return }

        let children = visibleChildren(of: root, filter: filter)
        let assigned = assignRootChildSides(children, sheet: sheet, filter: filter)
        let lefts = assigned.filter { $0.1 == .left }.map(\.0)
        let rights = assigned.filter { $0.1 == .right }.map(\.0)

        packColumn(
            lefts,
            side: .left,
            parent: root,
            parentFrame: parentFrame,
            depth: 1,
            selection: selection,
            sheet: sheet,
            filter: filter,
            nodes: &nodes,
            edges: &edges
        )
        packColumn(
            rights,
            side: .right,
            parent: root,
            parentFrame: parentFrame,
            depth: 1,
            selection: selection,
            sheet: sheet,
            filter: filter,
            nodes: &nodes,
            edges: &edges
        )
    }

    /// Place children of a non-root node: **same branch side as parent**, all outward.
    private func placeBranchChildren(
        of parent: Node,
        parentFrame: Rect2D,
        depth: Int,
        side: NodeSide,
        selection: SelectionState,
        sheet: StyleSheet,
        filter: MapFilter?,
        nodes: inout [NodeVisual],
        edges: inout [EdgeVisual]
    ) {
        guard !parent.isFolded else { return }
        guard side == .left || side == .right else { return }

        let children = visibleChildren(of: parent, filter: filter)
        packColumn(
            children,
            side: side,
            parent: parent,
            parentFrame: parentFrame,
            depth: depth,
            selection: selection,
            sheet: sheet,
            filter: filter,
            nodes: &nodes,
            edges: &edges
        )
    }

    private func packColumn(
        _ children: [Node],
        side: NodeSide,
        parent: Node,
        parentFrame: Rect2D,
        depth: Int,
        selection: SelectionState,
        sheet: StyleSheet,
        filter: MapFilter?,
        nodes: inout [NodeVisual],
        edges: inout [EdgeVisual]
    ) {
        let auto = children.filter { $0.positionPin == nil }
        let pinned = children.filter { $0.positionPin != nil }

        let totalH = columnHeight(auto, sheet: sheet, filter: filter)
        var cursorY = parentFrame.midY - totalH / 2

        for child in auto {
            let size = measure(child, sheet: sheet)
            let blockH = subtreeHeight(child, sheet: sheet, filter: filter)
            let centerY = cursorY + blockH / 2
            // Outward only: left branch → further left; right branch → further right.
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
            appendNode(
                child,
                frame: frame,
                depth: depth,
                side: side,
                selection: selection,
                sheet: sheet,
                filter: filter,
                into: &nodes
            )
            appendEdge(from: parent, parentFrame: parentFrame, to: child, frame: frame, side: side, edges: &edges)
            placeBranchChildren(
                of: child,
                parentFrame: frame,
                depth: depth + 1,
                side: side,
                selection: selection,
                sheet: sheet,
                filter: filter,
                nodes: &nodes,
                edges: &edges
            )
            cursorY += blockH + config.verticalGap
        }

        for child in pinned {
            let size = measure(child, sheet: sheet)
            let pin = child.positionPin!
            let frame = Rect2D(
                x: pin.x - size.width / 2,
                y: pin.y - size.height / 2,
                width: size.width,
                height: size.height
            )
            appendNode(
                child,
                frame: frame,
                depth: depth,
                side: side,
                selection: selection,
                sheet: sheet,
                filter: filter,
                into: &nodes
            )
            appendEdge(from: parent, parentFrame: parentFrame, to: child, frame: frame, side: side, edges: &edges)
            // Pinned nodes still inherit branch side for their expanded children.
            placeBranchChildren(
                of: child,
                parentFrame: frame,
                depth: depth + 1,
                side: side,
                selection: selection,
                sheet: sheet,
                filter: filter,
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
        sheet: StyleSheet,
        filter: MapFilter?,
        into nodes: inout [NodeVisual]
    ) {
        nodes.append(
            NodeVisual(
                id: node.id,
                text: node.text,
                frame: frame,
                style: StyleResolver.resolve(node: node, sheet: sheet),
                depth: depth,
                side: side,
                isFolded: node.isFolded,
                isSelected: selection.selectedIDs.contains(node.id),
                hasNote: !node.noteMarkdown.isEmpty,
                iconIDs: node.icons.map(\.id),
                isPinned: node.positionPin != nil,
                isHighlighted: isHighlighted(node, filter: filter)
            )
        )
    }
}
