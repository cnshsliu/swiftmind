public final class InsertChildCommand: MapCommand {
    public let name = "InsertChild"
    public let parentID: NodeID
    public let newNodeID: NodeID
    public let text: String
    public let side: NodeSide
    private var didInsert = false

    public init(parentID: NodeID, newNodeID: NodeID = .generate(), text: String, side: NodeSide = .auto) {
        self.parentID = parentID
        self.newNodeID = newNodeID
        self.text = text
        self.side = side
    }

    public func execute(on map: inout MindMap) throws {
        let child = Node(id: newNodeID, text: text, side: side)
        var inserted = false
        let ok = map.updateNode(id: parentID) { parent in
            parent.children.append(child)
            inserted = true
        }
        guard ok, inserted else { throw MapCommandError.nodeNotFound(parentID) }
        didInsert = true
    }

    public func undo(on map: inout MindMap) throws {
        guard didInsert else { return }
        let ok = map.updateNode(id: parentID) { parent in
            parent.children.removeAll { $0.id == newNodeID }
        }
        guard ok else { throw MapCommandError.nodeNotFound(parentID) }
    }
}
