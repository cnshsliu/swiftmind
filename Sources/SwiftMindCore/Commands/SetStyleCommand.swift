public final class SetStyleCommand: MapCommand {
    public let name = "SetStyle"
    public let nodeID: NodeID
    public let style: NodeStyle
    private var oldStyle: NodeStyle?

    public init(nodeID: NodeID, style: NodeStyle) {
        self.nodeID = nodeID
        self.style = style
    }

    public func execute(on map: inout MindMap) throws {
        guard let node = map.node(id: nodeID) else {
            throw MapCommandError.nodeNotFound(nodeID)
        }
        if oldStyle == nil { oldStyle = node.style }
        guard map.updateNode(id: nodeID, { $0.style = style }) else {
            throw MapCommandError.nodeNotFound(nodeID)
        }
    }

    public func undo(on map: inout MindMap) throws {
        guard let oldStyle else { throw MapCommandError.nodeNotFound(nodeID) }
        guard map.updateNode(id: nodeID, { $0.style = oldStyle }) else {
            throw MapCommandError.nodeNotFound(nodeID)
        }
    }
}
