public final class DeleteNodesCommand: MapCommand {
    public let name = "DeleteNodes"
    public let nodeIDs: Set<NodeID>
    private struct Removal: Equatable {
        var parentID: NodeID
        var index: Int
        var node: Node
    }
    private var removals: [Removal] = []

    public init(nodeIDs: [NodeID]) {
        self.nodeIDs = Set(nodeIDs)
    }

    public func execute(on map: inout MindMap) throws {
        if nodeIDs.contains(map.root.id) {
            throw MapCommandError.cannotDeleteRoot
        }
        removals = []
        for id in nodeIDs {
            try deleteOne(id, from: &map)
        }
        // Sort by index descending when restoring later
        removals.sort { $0.index > $1.index }
    }

    public func undo(on map: inout MindMap) throws {
        // Restore deepest indices first in reverse removal order
        for removal in removals.sorted(by: { $0.index < $1.index }) {
            let ok = map.updateNode(id: removal.parentID) { parent in
                let i = min(removal.index, parent.children.count)
                parent.children.insert(removal.node, at: i)
            }
            guard ok else { throw MapCommandError.nodeNotFound(removal.parentID) }
        }
    }

    private func deleteOne(_ id: NodeID, from map: inout MindMap) throws {
        guard let parentID = map.parentID(of: id),
              let parent = map.node(id: parentID),
              let index = parent.children.firstIndex(where: { $0.id == id }) else {
            throw MapCommandError.nodeNotFound(id)
        }
        let node = parent.children[index]
        removals.append(Removal(parentID: parentID, index: index, node: node))
        let ok = map.updateNode(id: parentID) { $0.children.removeAll { $0.id == id } }
        guard ok else { throw MapCommandError.nodeNotFound(id) }
    }
}
