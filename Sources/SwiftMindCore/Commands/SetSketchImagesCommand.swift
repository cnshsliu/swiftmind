import Foundation

/// Replaces a sketch board's image elements wholesale (the SetSketchCommand
/// pattern: full-state replace, one undo step).
public final class SetSketchImagesCommand: MapCommand {
    public let name = "SetSketchImages"
    public let nodeID: NodeID
    public let images: [SketchImageElement]?
    private var oldImages: [SketchImageElement]?
    private var stashed = false

    public init(nodeID: NodeID, images: [SketchImageElement]?) {
        self.nodeID = nodeID
        self.images = images
    }

    public func execute(on map: inout MindMap) throws {
        guard let node = map.node(id: nodeID) else { throw MapCommandError.nodeNotFound(nodeID) }
        if !stashed {
            oldImages = node.sketchImages
            stashed = true
        }
        guard map.updateNode(id: nodeID, {
            $0.sketchImages = (images?.isEmpty == true) ? nil : images
        }) else {
            throw MapCommandError.nodeNotFound(nodeID)
        }
    }

    public func undo(on map: inout MindMap) throws {
        guard stashed else { throw MapCommandError.nodeNotFound(nodeID) }
        guard map.updateNode(id: nodeID, {
            $0.sketchImages = oldImages
        }) else {
            throw MapCommandError.nodeNotFound(nodeID)
        }
    }
}
