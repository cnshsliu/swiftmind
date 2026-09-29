import Foundation

/// Replaces a sketch board's shape elements wholesale (the SetSketchCommand
/// pattern: full-state replace, one undo step).
public final class SetSketchShapesCommand: MapCommand {
    public let name = "SetSketchShapes"
    public let nodeID: NodeID
    public let shapes: [SketchShape]?
    private var oldShapes: [SketchShape]?
    /// Distinguishes "never executed" from "original shapes were nil" (undo guard).
    private var stashed = false

    public init(nodeID: NodeID, shapes: [SketchShape]?) {
        self.nodeID = nodeID
        self.shapes = shapes
    }

    public func execute(on map: inout MindMap) throws {
        guard let node = map.node(id: nodeID) else { throw MapCommandError.nodeNotFound(nodeID) }
        if !stashed {
            oldShapes = node.sketchShapes
            stashed = true
        }
        guard map.updateNode(id: nodeID, {
            $0.sketchShapes = (shapes?.isEmpty == true) ? nil : shapes
        }) else {
            throw MapCommandError.nodeNotFound(nodeID)
        }
    }

    public func undo(on map: inout MindMap) throws {
        guard stashed else { throw MapCommandError.nodeNotFound(nodeID) }
        guard map.updateNode(id: nodeID, {
            $0.sketchShapes = oldShapes
        }) else {
            throw MapCommandError.nodeNotFound(nodeID)
        }
    }
}
