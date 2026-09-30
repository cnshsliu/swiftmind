import Foundation

/// Sets (or clears, nil) a sketch board's background color.
public final class SetSketchBackgroundCommand: MapCommand {
    public let name = "SetSketchBackground"
    public let nodeID: NodeID
    public let background: String?
    private var oldBackground: String?
    private var stashed = false

    public init(nodeID: NodeID, background: String?) {
        self.nodeID = nodeID
        self.background = background?.isEmpty == true ? nil : background
    }

    public func execute(on map: inout MindMap) throws {
        guard let node = map.node(id: nodeID) else { throw MapCommandError.nodeNotFound(nodeID) }
        if !stashed {
            oldBackground = node.sketchBackground
            stashed = true
        }
        guard map.updateNode(id: nodeID, { $0.sketchBackground = background }) else {
            throw MapCommandError.nodeNotFound(nodeID)
        }
    }

    public func undo(on map: inout MindMap) throws {
        guard stashed else { throw MapCommandError.nodeNotFound(nodeID) }
        guard map.updateNode(id: nodeID, { $0.sketchBackground = oldBackground }) else {
            throw MapCommandError.nodeNotFound(nodeID)
        }
    }
}
