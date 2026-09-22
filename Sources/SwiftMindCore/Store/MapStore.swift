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

    public init(map: MindMap) {
        self.map = map
        self.selection = SelectionState(selectedIDs: [map.root.id], primary: map.root.id)
    }

    /// Layout with selection applied. Selection-only changes reuse geometry cache.
    public func snapshot() -> MapSnapshot {
        let geometry = geometrySnapshot()
        return geometry.applying(selection: selection)
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
        noteCardHeights = [:]
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
        try bus.undo(on: &map)
        noteCardHeights = [:]
        invalidateGeometry()
        contentRevision &+= 1
        selectionRevision &+= 1
    }

    public func redo() throws {
        try bus.redo(on: &map)
        noteCardHeights = [:]
        invalidateGeometry()
        contentRevision &+= 1
        selectionRevision &+= 1
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
    }
}
