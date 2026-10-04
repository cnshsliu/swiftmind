public final class MapStore {
    public private(set) var map: MindMap
    public private(set) var selection: SelectionState
    /// Bumps when map structure/content changes (layout invalid).
    public private(set) var contentRevision: UInt64 = 0
    /// Bumps when only selection changes (layout cache valid).
    public private(set) var selectionRevision: UInt64 = 0

    /// Combined tick for views that don't care why (legacy).
    public var revision: UInt64 { contentRevision &+ selectionRevision }

    private let bus = CommandBus()
    private var layoutEngine = LayoutEngine()
    private var formulaEngine = FormulaEngine()

    /// Layout parameters (gaps, media size, …). Changing them invalidates the
    /// geometry cache and bumps `contentRevision` so views re-render — the map
    /// content itself is untouched.
    public var layoutConfig: LayoutConfig {
        get { layoutEngine.config }
        set {
            guard newValue != layoutEngine.config else { return }
            layoutEngine.config = newValue
            noteCardHeights = [:]
            invalidateGeometry()
            contentRevision &+= 1
        }
    }

    /// Measured expanded-note card heights. Cleared after a successful content
    /// change or a layout-config change. Not cleared inside `invalidateGeometry`
    /// — that would drop the override before the relayout that consumes it.
    public private(set) var noteCardHeights: [NodeID: Double] = [:]

    /// Geometry-only snapshot (selection flags cleared). Invalidated on content change.
    private var cachedGeometry: MapSnapshot?
    private var cachedForContentRevision: UInt64 = .max
    /// Selection flags applied. Pan and hover call `snapshot()` every event;
    /// rebuilding the node array each time allocates on the hot path.
    private var cachedDisplay: MapSnapshot?
    private var cachedDisplayContent: UInt64 = .max
    private var cachedDisplaySelection: UInt64 = .max

    public init(map: MindMap) {
        self.map = map
        self.selection = SelectionState(selectedIDs: [map.root.id], primary: map.root.id)
    }

    /// Layout with selection applied. Selection-only changes reuse geometry cache.
    /// Repeated calls at the same revisions return the cached value (array is
    /// copy-on-write) so pan and scroll do not allocate a node per frame.
    public func snapshot() -> MapSnapshot {
        if let cachedDisplay,
           cachedDisplayContent == contentRevision,
           cachedDisplaySelection == selectionRevision {
            return cachedDisplay
        }
        let applied = geometrySnapshot().applying(selection: selection)
        cachedDisplay = applied
        cachedDisplayContent = contentRevision
        cachedDisplaySelection = selectionRevision
        return applied
    }

    /// Replace the parser's expanded-note height guess for one relayout.
    /// A repeat within 1 point is ignored so measurement cannot loop.
    public func updateMeasuredNoteHeight(_ height: Double, for id: NodeID) {
        guard height > 0, map.node(id: id) != nil else { return }
        let capped = min(height, layoutEngine.config.expandedNoteMaxHeight)
        if let existing = noteCardHeights[id], abs(existing - capped) <= 1 { return }
        noteCardHeights[id] = capped
        invalidateGeometry()
        contentRevision &+= 1
    }

    public func select(_ id: NodeID, additive: Bool = false) {
        selection.select(id, additive: additive)
        selectionRevision &+= 1
    }

    /// ⇧click: toggle membership; the id becomes primary when added.
    public func toggleSelection(_ id: NodeID) {
        if selection.selectedIDs.contains(id) {
            selection.selectedIDs.remove(id)
            if selection.primary == id {
                selection.primary = selection.selectedIDs.first
            }
        } else {
            selection.select(id, additive: true)
        }
        selectionRevision &+= 1
    }

    public func clearSelection() {
        selection.clear()
        selectionRevision &+= 1
    }

    public func dispatch(_ command: any MapCommand) throws {
        // Capture a sibling focus target before a delete removes the primary.
        var focusAfterDelete: NodeID?
        if let delete = command as? DeleteNodesCommand,
           let primary = selection.primary,
           delete.nodeIDs.contains(primary) {
            focusAfterDelete = siblingFocusTarget(deleting: primary, alsoDeleted: delete.nodeIDs)
        }
        try bus.execute(command, on: &map)
        if let insert = command as? InsertChildCommand {
            selection.select(insert.newNodeID)
        } else if let insert = command as? InsertSiblingCommand {
            selection.select(insert.newNodeID)
        } else if command is DeleteNodesCommand {
            if let focusAfterDelete {
                selection.select(focusAfterDelete)
            } else {
                // Prune deleted non-primary IDs; root only if focus was lost.
                let hadSelection = !selection.selectedIDs.isEmpty
                selection.selectedIDs = selection.selectedIDs.filter { map.node(id: $0) != nil }
                if let primary = selection.primary, map.node(id: primary) == nil {
                    selection.primary = selection.selectedIDs.first
                }
                if selection.selectedIDs.isEmpty, hadSelection {
                    selection.select(map.root.id)
                }
            }
        }
        if Self.commandInvalidatesMeasuredHeights(command) {
            noteCardHeights = [:]
        }
        invalidateGeometry()
        contentRevision &+= 1
        selectionRevision &+= 1
    }

    /// Where focus goes when `id` is deleted: next surviving sibling, then
    /// previous, then the parent (nil if the parent is deleted too).
    private func siblingFocusTarget(deleting id: NodeID, alsoDeleted: Set<NodeID>) -> NodeID? {
        guard let parentID = map.parentID(of: id),
              let parent = map.node(id: parentID),
              let index = parent.children.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        if let after = parent.children[(index + 1)...].first(where: { !alsoDeleted.contains($0.id) }) {
            return after.id
        }
        if index > 0,
           let before = parent.children[..<index].last(where: { !alsoDeleted.contains($0.id) }) {
            return before.id
        }
        return alsoDeleted.contains(parentID) ? nil : parentID
    }

    public func undo() throws {
        let command = bus.peekUndo()
        try bus.undo(on: &map)
        if Self.commandInvalidatesMeasuredHeights(command) {
            noteCardHeights = [:]
        }
        invalidateGeometry()
        contentRevision &+= 1
        selectionRevision &+= 1
    }

    public func redo() throws {
        let command = bus.peekRedo()
        try bus.redo(on: &map)
        if Self.commandInvalidatesMeasuredHeights(command) {
            noteCardHeights = [:]
        }
        invalidateGeometry()
        contentRevision &+= 1
        selectionRevision &+= 1
    }

    /// Measured note-card heights only depend on note content (and the set
    /// of nodes carrying notes). Structure-only commands — reorder, fold,
    /// insert, move, style — keep the cache so expanded cards do not flash
    /// back to the AST estimate and re-measure on every relayout.
    static func commandInvalidatesMeasuredHeights(_ command: (any MapCommand)?) -> Bool {
        switch command {
        case is SetNoteCommand, is DeleteNodesCommand, is SetNoteExpandedCommand:
            return true
        case is SetSketchShapesCommand:
            return false // sketch-only, like SetSketch/SetSketchTexts below
        case let composite as CompositeAgentCommand:
            // Sketch-only batches (drawing/text edits) never touch note
            // content — clearing the cache on every stroke commit made all
            // markdown cards flash back to the AST estimate and re-measure.
            return composite.ops.contains { op in
                switch op {
                case .setSketch, .setSketchTexts, .setSketchShapes, .setSketchImages: return false
                default: return true
                }
            }
        default:
            return false
        }
    }

    /// Close the coalescing group with this key (e.g. when the note editor
    /// closes) so the next same-key command starts a fresh undo step.
    /// No content change — no revision bump.
    public func endCoalescing(key: String) {
        bus.endCoalescing(key: key)
    }

    public var canUndo: Bool { bus.canUndo }
    public var canRedo: Bool { bus.canRedo }

    /// Computed value of one node's formula (memoized; nil when no formula).
    public func formulaValue(for id: NodeID) -> FormulaValue? {
        formulaEngine.result(for: id, in: map)
    }

    /// Computed values for all nodes with formulas (memoized per subtree).
    public func formulaResults() -> [NodeID: FormulaValue] {
        formulaEngine.results(in: map)
    }

    /// Replace `from` with `to` in every note. Used when the file is renamed
    /// and asset paths must follow the new `.swiftmind.assets` folder.
    public func replaceInNotes(from: String, to: String) {
        guard !from.isEmpty, from != to else { return }
        var changed = false
        func walk(_ node: inout Node) {
            if node.noteMarkdown.contains(from) {
                node.noteMarkdown = node.noteMarkdown.replacingOccurrences(of: from, with: to)
                changed = true
            }
            for index in node.children.indices {
                walk(&node.children[index])
            }
        }
        walk(&map.root)
        guard changed else { return }
        invalidateGeometry()
        contentRevision &+= 1
    }

    public func replaceMap(_ map: MindMap) {
        self.map = map
        bus.clearHistory()
        selection = SelectionState(selectedIDs: [map.root.id], primary: map.root.id)
        noteCardHeights = [:]
        invalidateGeometry()
        contentRevision &+= 1
        selectionRevision &+= 1
    }

    private func geometrySnapshot() -> MapSnapshot {
        if let cachedGeometry, cachedForContentRevision == contentRevision {
            return cachedGeometry
        }
        // Layout without selection; flags applied in `applying(selection:)`.
        let fresh = layoutEngine.layout(
            map: map,
            selection: SelectionState(),
            measuredNoteHeights: noteCardHeights
        )
        cachedGeometry = fresh
        cachedForContentRevision = contentRevision
        return fresh
    }

    private func invalidateGeometry() {
        cachedGeometry = nil
        cachedForContentRevision = .max
        cachedDisplay = nil
        cachedDisplayContent = .max
        cachedDisplaySelection = .max
    }
}

extension MapStore {
    /// Target sibling index for a one-slot reorder (⌥↑/⌥↓), clamped so the
    /// first cannot move up and the last cannot move down.
    public static func reorderTarget(current: Int, delta: Int, count: Int) -> Int {
        min(max(current + delta, 0), max(count - 1, 0))
    }
}
