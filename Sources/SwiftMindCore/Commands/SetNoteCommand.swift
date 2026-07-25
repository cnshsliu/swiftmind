public final class SetNoteCommand: MapCommand {
    public let name = "SetNote"
    public let nodeID: NodeID
    public let noteMarkdown: String
    private var old: String?

    public init(nodeID: NodeID, noteMarkdown: String) {
        self.nodeID = nodeID
        self.noteMarkdown = noteMarkdown
    }

    public func execute(on map: inout MindMap) throws {
        guard let node = map.node(id: nodeID) else { throw MapCommandError.nodeNotFound(nodeID) }
        if old == nil { old = node.noteMarkdown }
        guard map.updateNode(id: nodeID, { $0.noteMarkdown = noteMarkdown }) else {
            throw MapCommandError.nodeNotFound(nodeID)
        }
    }

    public func undo(on map: inout MindMap) throws {
        guard let old else { throw MapCommandError.nodeNotFound(nodeID) }
        guard map.updateNode(id: nodeID, { $0.noteMarkdown = old }) else {
            throw MapCommandError.nodeNotFound(nodeID)
        }
    }
}
