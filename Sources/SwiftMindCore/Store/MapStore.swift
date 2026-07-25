public final class MapStore {
    public private(set) var map: MindMap
    public private(set) var selection: SelectionState
    public private(set) var revision: UInt64 = 0
    private let bus = CommandBus()

    public init(map: MindMap) {
        self.map = map
        self.selection = SelectionState(selectedIDs: [map.root.id], primary: map.root.id)
    }

    public func select(_ id: NodeID, additive: Bool = false) {
        selection.select(id, additive: additive)
        revision &+= 1
    }

    public func dispatch(_ command: any MapCommand) throws {
        try bus.execute(command, on: &map)
        if let insert = command as? InsertChildCommand {
            selection.select(insert.newNodeID)
        } else if let insert = command as? InsertSiblingCommand {
            selection.select(insert.newNodeID)
        }
        revision &+= 1
    }

    public func undo() throws {
        try bus.undo(on: &map)
        revision &+= 1
    }

    public func redo() throws {
        try bus.redo(on: &map)
        revision &+= 1
    }

    public var canUndo: Bool { bus.canUndo }
    public var canRedo: Bool { bus.canRedo }

    public func replaceMap(_ map: MindMap) {
        self.map = map
        bus.clearHistory()
        selection = SelectionState(selectedIDs: [map.root.id], primary: map.root.id)
        revision &+= 1
    }
}
