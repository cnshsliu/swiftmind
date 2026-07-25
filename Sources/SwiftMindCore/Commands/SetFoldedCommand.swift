public final class SetFoldedCommand: MapCommand {
    public let name = "SetFolded"
    public let nodeID: NodeID
    public let isFolded: Bool
    private var oldIsFolded: Bool?

    public init(nodeID: NodeID, isFolded: Bool) {
        self.nodeID = nodeID
        self.isFolded = isFolded
    }

    public func execute(on map: inout MindMap) throws {
        guard let node = map.node(id: nodeID) else {
            throw MapCommandError.nodeNotFound(nodeID)
        }
        if oldIsFolded == nil { oldIsFolded = node.isFolded }
        guard map.updateNode(id: nodeID, { $0.isFolded = isFolded }) else {
            throw MapCommandError.nodeNotFound(nodeID)
        }
    }

    public func undo(on map: inout MindMap) throws {
        guard let oldIsFolded else { throw MapCommandError.nodeNotFound(nodeID) }
        guard map.updateNode(id: nodeID, { $0.isFolded = oldIsFolded }) else {
            throw MapCommandError.nodeNotFound(nodeID)
        }
    }
}
