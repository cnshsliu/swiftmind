public final class SetFormulaCommand: MapCommand {
    public let name = "SetFormula"
    public let nodeID: NodeID
    /// Formula source; nil clears the formula.
    public let formula: String?
    private var didCapture = false
    private var old: String?

    public init(nodeID: NodeID, formula: String?) {
        self.nodeID = nodeID
        self.formula = formula
    }

    public func execute(on map: inout MindMap) throws {
        guard let node = map.node(id: nodeID) else { throw MapCommandError.nodeNotFound(nodeID) }
        if !didCapture {
            old = node.formula
            didCapture = true
        }
        guard map.updateNode(id: nodeID, { $0.formula = formula }) else {
            throw MapCommandError.nodeNotFound(nodeID)
        }
    }

    public func undo(on map: inout MindMap) throws {
        guard didCapture else { throw MapCommandError.nodeNotFound(nodeID) }
        guard map.updateNode(id: nodeID, { $0.formula = old }) else {
            throw MapCommandError.nodeNotFound(nodeID)
        }
    }
}
