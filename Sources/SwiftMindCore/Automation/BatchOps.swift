import Foundation

/// One machine-authored map operation (CLI batch ops, future MCP calls).
public enum MapOp: Equatable, Sendable {
    case addChild(parentID: NodeID, newNodeID: NodeID, text: String, side: NodeSide)
    case addSibling(siblingID: NodeID, newNodeID: NodeID, text: String)
    case setText(nodeID: NodeID, text: String)
    case setNote(nodeID: NodeID, markdown: String)
    /// Empty value removes the attribute.
    case setAttribute(nodeID: NodeID, name: String, value: String)
    /// nil or empty formula clears it.
    case setFormula(nodeID: NodeID, formula: String?)
    case setFolded(nodeID: NodeID, isFolded: Bool)
    case setPin(nodeID: NodeID, position: Point2D?)
    case move(nodeID: NodeID, newParentID: NodeID, index: Int)
    case delete(nodeIDs: [NodeID])

    /// Wire name used by the CLI and in error reports.
    public var name: String {
        switch self {
        case .addChild: return "add-child"
        case .addSibling: return "add-sibling"
        case .setText: return "set-text"
        case .setNote: return "set-note"
        case .setAttribute: return "set-attr"
        case .setFormula: return "set-formula"
        case .setFolded(let _, let folded): return folded ? "fold" : "unfold"
        case .setPin(let _, let pos): return pos == nil ? "unpin" : "pin"
        case .move: return "move"
        case .delete: return "delete"
        }
    }
}

/// Batch failure: which op failed and why. The map is left untouched.
public struct BatchOpError: Error, Equatable {
    public let opIndex: Int
    public let opName: String
    public let message: String

    public init(opIndex: Int, opName: String, message: String) {
        self.opIndex = opIndex
        self.opName = opName
        self.message = message
    }
}

/// Applies `MapOp`s through the existing command types — all validation is inherited.
public enum BatchOps {
    /// All-or-nothing: ops run on a copy; `map` is swapped in only on full success.
    /// Returns the ids affected by the run (in op order).
    @discardableResult
    public static func apply(_ ops: [MapOp], to map: inout MindMap) throws -> [NodeID] {
        var working = map
        var affected: [NodeID] = []
        for (index, op) in ops.enumerated() {
            do {
                affected.append(contentsOf: try applyOne(op, to: &working))
            } catch {
                throw BatchOpError(
                    opIndex: index,
                    opName: op.name,
                    message: String(describing: error)
                )
            }
        }
        map = working
        return affected
    }

    private static func applyOne(_ op: MapOp, to map: inout MindMap) throws -> [NodeID] {
        switch op {
        case let .addChild(parentID, newNodeID, text, side):
            try InsertChildCommand(parentID: parentID, newNodeID: newNodeID, text: text, side: side)
                .execute(on: &map)
            return [newNodeID]
        case let .addSibling(siblingID, newNodeID, text):
            try InsertSiblingCommand(siblingID: siblingID, newNodeID: newNodeID, text: text)
                .execute(on: &map)
            return [newNodeID]
        case let .setText(nodeID, text):
            try SetTextCommand(nodeID: nodeID, newText: text).execute(on: &map)
            return [nodeID]
        case let .setNote(nodeID, markdown):
            try SetNoteCommand(nodeID: nodeID, noteMarkdown: markdown).execute(on: &map)
            return [nodeID]
        case let .setAttribute(nodeID, name, value):
            if value.isEmpty {
                guard let node = map.node(id: nodeID) else {
                    throw MapCommandError.nodeNotFound(nodeID)
                }
                let remaining = node.attributes.filter { $0.name != name }
                try SetAttributesCommand(nodeID: nodeID, attributes: remaining).execute(on: &map)
            } else {
                try UpsertAttributeCommand(
                    nodeID: nodeID,
                    attribute: NodeAttribute(name: name, value: value)
                ).execute(on: &map)
            }
            return [nodeID]
        case let .setFormula(nodeID, formula):
            let normalized = (formula ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            try SetFormulaCommand(nodeID: nodeID, formula: normalized.isEmpty ? nil : normalized)
                .execute(on: &map)
            return [nodeID]
        case let .setFolded(nodeID, isFolded):
            try SetFoldedCommand(nodeID: nodeID, isFolded: isFolded).execute(on: &map)
            return [nodeID]
        case let .setPin(nodeID, position):
            try SetPinCommand(nodeID: nodeID, positionPin: position).execute(on: &map)
            return [nodeID]
        case let .move(nodeID, newParentID, index):
            try MoveNodeCommand(nodeID: nodeID, newParentID: newParentID, index: index)
                .execute(on: &map)
            return [nodeID]
        case let .delete(nodeIDs):
            try DeleteNodesCommand(nodeIDs: nodeIDs).execute(on: &map)
            return nodeIDs
        }
    }
}
