public final class SetPinCommand: MapCommand {
    public let name = "SetPin"
    public let nodeID: NodeID
    public let positionPin: Point2D?
    /// Outer optional: not yet captured. Inner: previous pin (may be nil).
    private var old: Point2D??

    public init(nodeID: NodeID, positionPin: Point2D?) {
        self.nodeID = nodeID
        self.positionPin = positionPin
    }

    public func execute(on map: inout MindMap) throws {
        guard let node = map.node(id: nodeID) else { throw MapCommandError.nodeNotFound(nodeID) }
        if old == nil { old = .some(node.positionPin) }
        guard map.updateNode(id: nodeID, { $0.positionPin = positionPin }) else {
            throw MapCommandError.nodeNotFound(nodeID)
        }
    }

    public func undo(on map: inout MindMap) throws {
        guard let old else { throw MapCommandError.nodeNotFound(nodeID) }
        guard map.updateNode(id: nodeID, { $0.positionPin = old }) else {
            throw MapCommandError.nodeNotFound(nodeID)
        }
    }
}
