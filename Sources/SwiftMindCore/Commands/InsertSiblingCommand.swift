public final class InsertSiblingCommand: MapCommand {
    public let name = "InsertSibling"
    public let siblingID: NodeID
    public let newNodeID: NodeID
    public let text: String
    public let side: NodeSide
    private var parentID: NodeID?
    private var didInsert = false

    public init(
        siblingID: NodeID,
        newNodeID: NodeID = .generate(),
        text: String,
        side: NodeSide = .auto
    ) {
        self.siblingID = siblingID
        self.newNodeID = newNodeID
        self.text = text
        self.side = side
    }

    public func execute(on map: inout MindMap) throws {
        guard map.node(id: siblingID) != nil else {
            throw MapCommandError.nodeNotFound(siblingID)
        }
        guard let parentID = map.parentID(of: siblingID),
              let parent = map.node(id: parentID),
              let siblingIndex = parent.children.firstIndex(where: { $0.id == siblingID }) else {
            // Root has no parent — cannot insert a sibling of the root
            throw MapCommandError.invalidParent
        }
        self.parentID = parentID
        let child = Node(id: newNodeID, text: text, side: side)
        let insertIndex = siblingIndex + 1
        let ok = map.updateNode(id: parentID) { parent in
            parent.children.insert(child, at: min(insertIndex, parent.children.count))
        }
        guard ok else { throw MapCommandError.nodeNotFound(parentID) }
        didInsert = true
    }

    public func undo(on map: inout MindMap) throws {
        guard didInsert, let parentID else { return }
        let ok = map.updateNode(id: parentID) { parent in
            parent.children.removeAll { $0.id == newNodeID }
        }
        guard ok else { throw MapCommandError.nodeNotFound(parentID) }
    }
}
