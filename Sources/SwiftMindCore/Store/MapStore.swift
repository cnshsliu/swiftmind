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
    private let layoutEngine = LayoutEngine()

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

    public func select(_ id: NodeID, additive: Bool = false) {
        selection.select(id, additive: additive)
        selectionRevision &+= 1
    }

    public func dispatch(_ command: any MapCommand) throws {
        try bus.execute(command, on: &map)
        if let insert = command as? InsertChildCommand {
            selection.select(insert.newNodeID)
        } else if let insert = command as? InsertSiblingCommand {
            selection.select(insert.newNodeID)
        }
        invalidateGeometry()
        contentRevision &+= 1
        selectionRevision &+= 1
    }

    public func undo() throws {
        try bus.undo(on: &map)
        invalidateGeometry()
        contentRevision &+= 1
        selectionRevision &+= 1
    }

    public func redo() throws {
        try bus.redo(on: &map)
        invalidateGeometry()
        contentRevision &+= 1
        selectionRevision &+= 1
    }

    public var canUndo: Bool { bus.canUndo }
    public var canRedo: Bool { bus.canRedo }

    public func replaceMap(_ map: MindMap) {
        self.map = map
        bus.clearHistory()
        selection = SelectionState(selectedIDs: [map.root.id], primary: map.root.id)
        invalidateGeometry()
        contentRevision &+= 1
        selectionRevision &+= 1
    }

    private func geometrySnapshot() -> MapSnapshot {
        if let cachedGeometry, cachedForContentRevision == contentRevision {
            return cachedGeometry
        }
        // Layout without selection; flags applied in `applying(selection:)`.
        let fresh = layoutEngine.layout(map: map, selection: SelectionState())
        cachedGeometry = fresh
        cachedForContentRevision = contentRevision
        return fresh
    }

    private func invalidateGeometry() {
        cachedGeometry = nil
        cachedForContentRevision = .max
    }
}
