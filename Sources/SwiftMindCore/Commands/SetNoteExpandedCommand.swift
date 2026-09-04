public final class SetNoteExpandedCommand: MapCommand {
    public let name = "SetNoteExpanded"
    public let nodeID: NodeID
    public let isNoteExpanded: Bool
    private var oldIsNoteExpanded: Bool?

    public init(nodeID: NodeID, isNoteExpanded: Bool) {
        self.nodeID = nodeID
        self.isNoteExpanded = isNoteExpanded
    }

    public func execute(on map: inout MindMap) throws {
        guard let node = map.node(id: nodeID) else {
            throw MapCommandError.nodeNotFound(nodeID)
        }
        if oldIsNoteExpanded == nil { oldIsNoteExpanded = node.isNoteExpanded }
        guard map.updateNode(id: nodeID, { $0.isNoteExpanded = isNoteExpanded }) else {
            throw MapCommandError.nodeNotFound(nodeID)
        }
    }

    public func undo(on map: inout MindMap) throws {
        guard let oldIsNoteExpanded else { throw MapCommandError.nodeNotFound(nodeID) }
        guard map.updateNode(id: nodeID, { $0.isNoteExpanded = oldIsNoteExpanded }) else {
            throw MapCommandError.nodeNotFound(nodeID)
        }
    }
}
