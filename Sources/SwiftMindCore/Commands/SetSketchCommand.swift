import Foundation

public final class SetSketchCommand: MapCommand {
    public let name = "SetSketch"
    public let nodeID: NodeID
    /// nil removes the sketch entirely.
    public let sketch: Data?
    public let width: Double?
    public let height: Double?
    private var oldSketch: Data?
    private var oldWidth: Double?
    private var oldHeight: Double?
    /// Distinguishes "never executed" from "original sketch was nil" (undo guard).
    private var stashed = false

    public init(nodeID: NodeID, sketch: Data?, width: Double? = nil, height: Double? = nil) {
        self.nodeID = nodeID
        self.sketch = sketch
        self.width = width
        self.height = height
    }

    public func execute(on map: inout MindMap) throws {
        guard let node = map.node(id: nodeID) else { throw MapCommandError.nodeNotFound(nodeID) }
        if !stashed {
            oldSketch = node.sketch
            oldWidth = node.sketchWidth
            oldHeight = node.sketchHeight
            stashed = true
        }
        guard map.updateNode(id: nodeID, {
            $0.sketch = sketch
            $0.sketchWidth = width
            $0.sketchHeight = height
        }) else {
            throw MapCommandError.nodeNotFound(nodeID)
        }
    }

    public func undo(on map: inout MindMap) throws {
        guard stashed else { throw MapCommandError.nodeNotFound(nodeID) }
        guard map.updateNode(id: nodeID, {
            $0.sketch = oldSketch
            $0.sketchWidth = oldWidth
            $0.sketchHeight = oldHeight
        }) else {
            throw MapCommandError.nodeNotFound(nodeID)
        }
    }
}
