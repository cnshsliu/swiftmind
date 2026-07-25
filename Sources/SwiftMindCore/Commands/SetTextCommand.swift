public final class SetTextCommand: MapCommand {
    public let name = "SetText"
    public let nodeID: NodeID
    public let newText: String
    private var oldText: String?

    public init(nodeID: NodeID, newText: String) {
        self.nodeID = nodeID
        self.newText = newText
    }

    public func execute(on map: inout MindMap) throws {
        guard let node = map.node(id: nodeID) else {
            throw MapCommandError.nodeNotFound(nodeID)
        }
        if oldText == nil { oldText = node.text }
        guard map.updateNode(id: nodeID, { $0.text = newText }) else {
            throw MapCommandError.nodeNotFound(nodeID)
        }
    }

    public func undo(on map: inout MindMap) throws {
        guard let oldText else { throw MapCommandError.nodeNotFound(nodeID) }
        guard map.updateNode(id: nodeID, { $0.text = oldText }) else {
            throw MapCommandError.nodeNotFound(nodeID)
        }
    }
}
