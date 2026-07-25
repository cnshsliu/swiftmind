public final class MoveNodeCommand: MapCommand {
    public let name = "MoveNode"
    public let nodeID: NodeID
    public let newParentID: NodeID
    public let index: Int
    private var oldParentID: NodeID?
    private var oldIndex: Int?
    private var movedNode: Node?

    public init(nodeID: NodeID, newParentID: NodeID, index: Int) {
        self.nodeID = nodeID
        self.newParentID = newParentID
        self.index = index
    }

    public func execute(on map: inout MindMap) throws {
        if nodeID == map.root.id { throw MapCommandError.cannotDeleteRoot }
        // Prevent moving into own descendant (or onto self)
        if isDescendant(nodeID, possibleDescendant: newParentID, map: map) {
            throw MapCommandError.invalidParent
        }
        guard let oldParent = map.parentID(of: nodeID),
              let parentNode = map.node(id: oldParent),
              let idx = parentNode.children.firstIndex(where: { $0.id == nodeID }) else {
            throw MapCommandError.nodeNotFound(nodeID)
        }
        oldParentID = oldParent
        oldIndex = idx
        movedNode = parentNode.children[idx]
        guard map.updateNode(id: oldParent, { $0.children.removeAll { $0.id == nodeID } }) else {
            throw MapCommandError.nodeNotFound(nodeID)
        }
        guard let moving = movedNode else { throw MapCommandError.nodeNotFound(nodeID) }
        guard map.updateNode(id: newParentID, { parent in
            let i = min(max(0, index), parent.children.count)
            parent.children.insert(moving, at: i)
        }) else {
            throw MapCommandError.nodeNotFound(newParentID)
        }
    }

    public func undo(on map: inout MindMap) throws {
        guard let oldParentID, let oldIndex, let movedNode else {
            throw MapCommandError.nodeNotFound(nodeID)
        }
        guard map.updateNode(id: newParentID, { $0.children.removeAll { $0.id == nodeID } }) else {
            throw MapCommandError.nodeNotFound(newParentID)
        }
        guard map.updateNode(id: oldParentID, { parent in
            let i = min(oldIndex, parent.children.count)
            parent.children.insert(movedNode, at: i)
        }) else {
            throw MapCommandError.nodeNotFound(oldParentID)
        }
    }

    private func isDescendant(_ ancestor: NodeID, possibleDescendant: NodeID, map: MindMap) -> Bool {
        guard let node = map.node(id: ancestor) else { return false }
        return contains(possibleDescendant, in: node)
    }

    private func contains(_ id: NodeID, in node: Node) -> Bool {
        if node.id == id { return true }
        return node.children.contains { contains(id, in: $0) }
    }
}
