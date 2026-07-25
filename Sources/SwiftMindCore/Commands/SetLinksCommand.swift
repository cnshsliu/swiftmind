public final class SetLinksCommand: MapCommand {
    public let name = "SetLinks"
    public let nodeID: NodeID
    public let links: [NodeLink]
    private var old: [NodeLink]?

    public init(nodeID: NodeID, links: [NodeLink]) {
        self.nodeID = nodeID
        self.links = links
    }

    public func execute(on map: inout MindMap) throws {
        guard let node = map.node(id: nodeID) else { throw MapCommandError.nodeNotFound(nodeID) }
        if old == nil { old = node.links }
        guard map.updateNode(id: nodeID, { $0.links = links }) else {
            throw MapCommandError.nodeNotFound(nodeID)
        }
    }

    public func undo(on map: inout MindMap) throws {
        guard let old else { throw MapCommandError.nodeNotFound(nodeID) }
        guard map.updateNode(id: nodeID, { $0.links = old }) else {
            throw MapCommandError.nodeNotFound(nodeID)
        }
    }
}
