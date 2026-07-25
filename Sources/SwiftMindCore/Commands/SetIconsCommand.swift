public final class SetIconsCommand: MapCommand {
    public let name = "SetIcons"
    public let nodeID: NodeID
    public let icons: [IconRef]
    private var old: [IconRef]?

    public init(nodeID: NodeID, icons: [IconRef]) {
        self.nodeID = nodeID
        self.icons = icons
    }

    public func execute(on map: inout MindMap) throws {
        guard let node = map.node(id: nodeID) else { throw MapCommandError.nodeNotFound(nodeID) }
        if old == nil { old = node.icons }
        guard map.updateNode(id: nodeID, { $0.icons = icons }) else {
            throw MapCommandError.nodeNotFound(nodeID)
        }
    }

    public func undo(on map: inout MindMap) throws {
        guard let old else { throw MapCommandError.nodeNotFound(nodeID) }
        guard map.updateNode(id: nodeID, { $0.icons = old }) else {
            throw MapCommandError.nodeNotFound(nodeID)
        }
    }
}
