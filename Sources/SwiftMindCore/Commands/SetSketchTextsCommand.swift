import Foundation

/// Replaces a sketch board's text elements wholesale (the SetSketchCommand
/// pattern: full-state replace, one undo step). Empty array removes texts.
public final class SetSketchTextsCommand: MapCommand {
    public let name = "SetSketchTexts"
    public let nodeID: NodeID
    public let texts: [SketchText]?
    private var oldTexts: [SketchText]?
    /// Distinguishes "never executed" from "original texts were nil" (undo guard).
    private var stashed = false

    public init(nodeID: NodeID, texts: [SketchText]?) {
        self.nodeID = nodeID
        self.texts = texts
    }

    public func execute(on map: inout MindMap) throws {
        guard let node = map.node(id: nodeID) else { throw MapCommandError.nodeNotFound(nodeID) }
        if !stashed {
            oldTexts = node.sketchTexts
            stashed = true
        }
        guard map.updateNode(id: nodeID, {
            $0.sketchTexts = (texts?.isEmpty == true) ? nil : texts
        }) else {
            throw MapCommandError.nodeNotFound(nodeID)
        }
    }

    public func undo(on map: inout MindMap) throws {
        guard stashed else { throw MapCommandError.nodeNotFound(nodeID) }
        guard map.updateNode(id: nodeID, {
            $0.sketchTexts = oldTexts
        }) else {
            throw MapCommandError.nodeNotFound(nodeID)
        }
    }
}
