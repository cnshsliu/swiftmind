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

    public func layout(
        map: MindMap,
        selection: SelectionState = SelectionState(),
        measuredNoteHeights: [NodeID: Double] = [:]
    ) -> MapSnapshot {
        var nodes: [NodeVisual] = []
        var edges: [EdgeVisual] = []

        let filter = map.activeFilter
        let graph = MapGraph.analyze(map)
        let sheet = map.styleSheet
        let root = map.root

        let rootSize = measure(root, sheet: sheet, measuredNoteHeights: measuredNoteHeights)
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
            graph: graph,
            into: &nodes
        )
        // Root children: only place where L/R is decided.
        placeRootChildren(
            of: root,
            parentFrame: rootFrame,
            selection: selection,
            sheet: sheet,
            filter: filter,
            graph: graph,
            measuredNoteHeights: measuredNoteHeights,
            nodes: &nodes,
            edges: &edges
        )

        let bounds = nodes.map(\.frame).reduce(rootFrame) { $0.union($1) }.inset(by: -40)
        return MapSnapshot(nodes: nodes, edges: edges, bounds: bounds)
    }

    // MARK: - Visibility

    /// Children shown under hide-mode filter (match or ancestor of match).
    private func visibleChildren(of node: Node, filter: MapFilter?, graph: MapGraph) -> [Node] {
        guard let filter, filter.mode == .hide else {
            return node.children
        }
        return node.children.filter {
            FilterEvaluator.matchesIncludingDescendants($0, rule: filter.rule, graph: graph)
        }
    }

    private func isHighlighted(_ node: Node, filter: MapFilter?, graph: MapGraph) -> Bool {
        guard let filter, filter.mode == .highlight else { return false }
        return FilterEvaluator.matches(node, rule: filter.rule, graph: graph)
    }

    // MARK: - Measure

    /// Estimated rendered width of a single-line title, Unicode-aware:
    /// Latin-ish scalars average `charWidth` (≥ 0.55×fontSize), while CJK and
    /// other full-width glyphs render ~fontSize wide and count double. Shared
    /// with the Mac inline editor so its box matches the frame a commit will
    /// produce. Empty text still reserves one unit (min width floors later).
    public static func estimatedTextWidth(_ text: String, fontSize: Double, charWidth: Double) -> Double {
        let base = max(charWidth, fontSize * 0.55)
        var units = 0.0
        for scalar in text.unicodeScalars {
            units += Self.isWideScalar(scalar) ? 2 : 1
        }
        return max(1, units) * base
    }

    /// Full-width scalar ranges: CJK ideographs & extensions, kana, hangul,
    /// full-width forms, CJK punctuation, and the square/unit blocks.
    static func isWideScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x115F,       // Hangul Jamo
             0x2E80...0x303E,       // CJK Radicals, Kangxi, CJK Symbols & Punctuation
             0x3041...0x33FF,       // Hiragana, Katakana, Bopomofo, CJK Compatibility
             0x3400...0x4DBF,       // CJK Extension A
             0x4E00...0x9FFF,       // CJK Unified Ideographs
             0xA000...0xA4CF,       // Yi
             0xAC00...0xD7A3,       // Hangul Syllables
             0xF900...0xFAFF,       // CJK Compatibility Ideographs
             0xFE10...0xFE19,       // Vertical forms
             0xFE30...0xFE6F,       // CJK Compatibility Forms
             0xFF00...0xFF60,       // Fullwidth Forms
             0xFFE0...0xFFE6,       // Fullwidth signs
             0x1F300...0x1FAFF,     // Emoji (render wide)
             0x20000...0x3FFFD:     // CJK Extensions B+
            return true
        default:
            return false
        }
    }

    private func measure(
        _ node: Node,
        sheet: StyleSheet,
        measuredNoteHeights: [NodeID: Double]
    ) -> (width: Double, height: Double) {
        let style = StyleResolver.resolve(node: node, sheet: sheet)
        if node.sketch != nil {
            // Sketch node: sized from the trimmed content board (scaled to fit
            // the media box), plus an optional title strip. Sketch wins over
            // the note card.
            let titleH = node.text.isEmpty ? 0 : config.sketchTitleLineHeight
            let boardW: Double
            let boardH: Double
            if let w = node.sketchWidth, let h = node.sketchHeight, w > 0, h > 0 {
                (boardW, boardH) = sketchBoardSize(contentWidth: w, contentHeight: h)
            } else {
                // No content yet (or cleared): minimal placeholder board.
                boardW = config.sketchMinSize
                boardH = config.sketchMinSize
            }
            var h = 16 + titleH + boardH
            if Self.hasFormula(node) { h += config.formulaBadgeHeight }
            return (boardW + config.paddingX * 2, h)
        }
        if node.isNoteExpanded {
            // AST guess stays UI-free. A measured card height replaces it.
            // Both are capped; the card view scrolls overflow in-place.
            let guess = MarkdownMeasure(
                width: config.expandedNoteWidth,
                charWidth: max(config.charWidth, style.fontSize * 0.55),
                lineHeight: config.expandedNoteLineHeight,
                imageHeight: config.mediaMaxSize
            ).height(of: node.noteMarkdown) + config.expandedNoteLineHeight + config.paddingX * 2
            let raw = measuredNoteHeights[node.id] ?? max(config.nodeHeight, guess)
            var h = min(config.expandedNoteMaxHeight, raw)
            if Self.hasFormula(node) { h += config.formulaBadgeHeight }
            return (config.expandedNoteWidth, h)
        }
        // Unicode-aware: CJK glyphs render ~fontSize wide, not ~0.55×fontSize.
        let textWidth = Self.estimatedTextWidth(node.text, fontSize: style.fontSize, charWidth: config.charWidth)
        let iconCount = min(3, node.icons.count)
        let iconWidth = iconCount == 0 ? 0 : Double(iconCount) * config.iconSlotWidth + 4
        var badgeWidth = 0.0
        if !node.noteMarkdown.isEmpty { badgeWidth += config.badgeReserve }
        if node.positionPin != nil { badgeWidth += config.badgeReserve * 0.5 }
        let hasFormula = Self.hasFormula(node)
        if hasFormula { badgeWidth += config.badgeReserve }
        let width = max(
            config.minNodeWidth,
            textWidth + iconWidth + badgeWidth + config.paddingX * 2
        )
        var height = max(config.nodeHeight, style.fontSize + 16)
        if hasFormula { height += config.formulaBadgeHeight }
        return (width, height)
    }

    private static func hasFormula(_ node: Node) -> Bool {
        guard let f = node.formula else { return false }
        return !f.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Side assignment (root children only)

    /// First-level only: explicit `.left`/`.right` wins; `.auto` balances by subtree weight.
    /// On ties prefer **left** (first child grows to the left).
    private func assignRootChildSides(
        _ children: [Node],
        sheet: StyleSheet,
        filter: MapFilter?,
        graph: MapGraph,
        measuredNoteHeights: [NodeID: Double]
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
                // Lighter side wins; prefer left when equal.
                side = leftWeight <= rightWeight ? .left : .right
            }
            let w = subtreeHeight(
                child,
                sheet: sheet,
                filter: filter,
                graph: graph,
                measuredNoteHeights: measuredNoteHeights
            )
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
    private func subtreeHeight(
        _ node: Node,
        sheet: StyleSheet,
        filter: MapFilter?,
        graph: MapGraph,
        measuredNoteHeights: [NodeID: Double]
    ) -> Double {
        let selfH = measure(node, sheet: sheet, measuredNoteHeights: measuredNoteHeights).height
        guard !node.isFolded else { return selfH }
        let kids = visibleChildren(of: node, filter: filter, graph: graph).filter { $0.positionPin == nil }
        guard !kids.isEmpty else { return selfH }
        return max(
            selfH,
            columnHeight(kids, sheet: sheet, filter: filter, graph: graph, measuredNoteHeights: measuredNoteHeights)
        )
    }

    private func columnHeight(
        _ nodes: [Node],
        sheet: StyleSheet,
        filter: MapFilter?,
        graph: MapGraph,
        measuredNoteHeights: [NodeID: Double]
    ) -> Double {
        guard !nodes.isEmpty else { return 0 }
        return nodes.map {
            subtreeHeight($0, sheet: sheet, filter: filter, graph: graph, measuredNoteHeights: measuredNoteHeights)
        }.reduce(0, +)
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
        graph: MapGraph,
        measuredNoteHeights: [NodeID: Double],
        nodes: inout [NodeVisual],
        edges: inout [EdgeVisual]
    ) {
        guard !root.isFolded else { return }

        let children = visibleChildren(of: root, filter: filter, graph: graph)
        let assigned = assignRootChildSides(
            children,
            sheet: sheet,
            filter: filter,
            graph: graph,
            measuredNoteHeights: measuredNoteHeights
        )
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
            graph: graph,
            measuredNoteHeights: measuredNoteHeights,
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
            graph: graph,
            measuredNoteHeights: measuredNoteHeights,
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
        graph: MapGraph,
        measuredNoteHeights: [NodeID: Double],
        nodes: inout [NodeVisual],
        edges: inout [EdgeVisual]
    ) {
        guard !parent.isFolded else { return }
        guard side == .left || side == .right else { return }

        let children = visibleChildren(of: parent, filter: filter, graph: graph)
        packColumn(
            children,
            side: side,
            parent: parent,
            parentFrame: parentFrame,
            depth: depth,
            selection: selection,
            sheet: sheet,
            filter: filter,
            graph: graph,
            measuredNoteHeights: measuredNoteHeights,
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
        graph: MapGraph,
        measuredNoteHeights: [NodeID: Double],
        nodes: inout [NodeVisual],
        edges: inout [EdgeVisual]
    ) {
        let auto = children.filter { $0.positionPin == nil }
        let pinned = children.filter { $0.positionPin != nil }

        let totalH = columnHeight(
            auto,
            sheet: sheet,
            filter: filter,
            graph: graph,
            measuredNoteHeights: measuredNoteHeights
        )
        var cursorY = parentFrame.midY - totalH / 2

        for child in auto {
            let size = measure(child, sheet: sheet, measuredNoteHeights: measuredNoteHeights)
            let blockH = subtreeHeight(
                child,
                sheet: sheet,
                filter: filter,
                graph: graph,
                measuredNoteHeights: measuredNoteHeights
            )
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
            graph: graph,
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
                graph: graph,
                measuredNoteHeights: measuredNoteHeights,
                nodes: &nodes,
                edges: &edges
            )
            cursorY += blockH + config.verticalGap
        }

        for child in pinned {
            let size = measure(child, sheet: sheet, measuredNoteHeights: measuredNoteHeights)
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
            graph: graph,
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
                graph: graph,
                measuredNoteHeights: measuredNoteHeights,
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

    /// Scaled sketch board size for the canvas render rect; nil while empty.
    private func sketchSize(of node: Node) -> Point2D? {
        guard node.sketch != nil,
              let w = node.sketchWidth, let h = node.sketchHeight, w > 0, h > 0 else { return nil }
        let (bw, bh) = sketchBoardSize(contentWidth: w, contentHeight: h)
        return Point2D(x: bw, y: bh)
    }

    /// Uniform scale-to-fit of sketch content inside the media box: the long
    /// edge lands on `min(mediaMaxSize, sketchMaxSize)` (never upscaling past
    /// the content), tiny drawings lift to `sketchMinSize` on the long edge.
    private func sketchBoardSize(contentWidth w: Double, contentHeight h: Double) -> (Double, Double) {
        let box = min(config.mediaMaxSize, config.sketchMaxSize)
        let longEdge = max(w, h)
        var factor = min(1, box / longEdge)
        if longEdge * factor < config.sketchMinSize {
            factor = config.sketchMinSize / longEdge
        }
        return (w * factor, h * factor)
    }

    private func appendNode(
        _ node: Node,
        frame: Rect2D,
        depth: Int,
        side: NodeSide,
        selection: SelectionState,
        sheet: StyleSheet,
        filter: MapFilter?,
        graph: MapGraph,
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
                isHighlighted: isHighlighted(node, filter: filter, graph: graph),
                isNoteExpanded: node.isNoteExpanded && node.sketch == nil,
                hasSketch: node.sketch != nil,
                sketchSize: sketchSize(of: node)
            )
        )
    }
}
