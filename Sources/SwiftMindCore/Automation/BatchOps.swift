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

extension MapOp: Codable {
    private enum CodingKeys: String, CodingKey {
        case op, parent, sibling, id, ids, text, side, markdown, name, value, formula, x, y, to, index
    }

    private enum WireError: Error, CustomStringConvertible, LocalizedError {
        case unknownOp(String)
        case missingField(String, op: String)
        case invalidValue(String, op: String)

        var description: String {
            switch self {
            case .unknownOp(let op): return "unknown op \"\(op)\""
            case .missingField(let field, let op): return "op \"\(op)\" missing required field \"\(field)\""
            case .invalidValue(let value, let op): return "op \"\(op)\" invalid value \"\(value)\""
            }
        }

        var errorDescription: String? { description }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let op = try c.decode(String.self, forKey: .op)

        func nodeID(_ key: CodingKeys) throws -> NodeID {
            guard let raw = try c.decodeIfPresent(String.self, forKey: key) else {
                throw WireError.missingField(key.rawValue, op: op)
            }
            return NodeID(rawValue: raw)
        }
        func string(_ key: CodingKeys) throws -> String {
            guard let value = try c.decodeIfPresent(String.self, forKey: key) else {
                throw WireError.missingField(key.rawValue, op: op)
            }
            return value
        }
        func generatedID() throws -> NodeID {
            if let raw = try c.decodeIfPresent(String.self, forKey: .id) {
                return NodeID(rawValue: raw)
            }
            return .generate()
        }

        switch op {
        case "add-child":
            let side: NodeSide
            if let raw = try c.decodeIfPresent(String.self, forKey: .side) {
                guard let parsed = NodeSide(rawValue: raw) else {
                    throw WireError.invalidValue(raw, op: op)
                }
                side = parsed
            } else {
                side = .auto
            }
            self = .addChild(
                parentID: try nodeID(.parent),
                newNodeID: try generatedID(),
                text: try string(.text),
                side: side
            )
        case "add-sibling":
            self = .addSibling(
                siblingID: try nodeID(.sibling),
                newNodeID: try generatedID(),
                text: try string(.text)
            )
        case "set-text":
            self = .setText(nodeID: try nodeID(.id), text: try string(.text))
        case "set-note":
            self = .setNote(nodeID: try nodeID(.id), markdown: try string(.markdown))
        case "set-attr":
            self = .setAttribute(
                nodeID: try nodeID(.id),
                name: try string(.name),
                value: try c.decodeIfPresent(String.self, forKey: .value) ?? ""
            )
        case "set-formula":
            self = .setFormula(
                nodeID: try nodeID(.id),
                formula: try c.decodeIfPresent(String.self, forKey: .formula)
            )
        case "fold":
            self = .setFolded(nodeID: try nodeID(.id), isFolded: true)
        case "unfold":
            self = .setFolded(nodeID: try nodeID(.id), isFolded: false)
        case "pin":
            guard let x = try c.decodeIfPresent(Double.self, forKey: .x),
                  let y = try c.decodeIfPresent(Double.self, forKey: .y) else {
                throw WireError.missingField("x/y", op: op)
            }
            self = .setPin(nodeID: try nodeID(.id), position: Point2D(x: x, y: y))
        case "unpin":
            self = .setPin(nodeID: try nodeID(.id), position: nil)
        case "move":
            self = .move(
                nodeID: try nodeID(.id),
                newParentID: try nodeID(.to),
                index: try c.decodeIfPresent(Int.self, forKey: .index) ?? 0
            )
        case "delete":
            if let ids = try c.decodeIfPresent([String].self, forKey: .ids) {
                self = .delete(nodeIDs: ids.map { NodeID(rawValue: $0) })
            } else if let raw = try c.decodeIfPresent(String.self, forKey: .id) {
                self = .delete(nodeIDs: [NodeID(rawValue: raw)])
            } else {
                throw WireError.missingField("id/ids", op: op)
            }
        default:
            throw WireError.unknownOp(op)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .op)
        switch self {
        case let .addChild(parentID, newNodeID, text, side):
            try c.encode(parentID.rawValue, forKey: .parent)
            try c.encode(newNodeID.rawValue, forKey: .id)
            try c.encode(text, forKey: .text)
            try c.encode(side.rawValue, forKey: .side)
        case let .addSibling(siblingID, newNodeID, text):
            try c.encode(siblingID.rawValue, forKey: .sibling)
            try c.encode(newNodeID.rawValue, forKey: .id)
            try c.encode(text, forKey: .text)
        case let .setText(nodeID, text):
            try c.encode(nodeID.rawValue, forKey: .id)
            try c.encode(text, forKey: .text)
        case let .setNote(nodeID, markdown):
            try c.encode(nodeID.rawValue, forKey: .id)
            try c.encode(markdown, forKey: .markdown)
        case let .setAttribute(nodeID, name, value):
            try c.encode(nodeID.rawValue, forKey: .id)
            try c.encode(name, forKey: .name)
            try c.encode(value, forKey: .value)
        case let .setFormula(nodeID, formula):
            try c.encode(nodeID.rawValue, forKey: .id)
            try c.encodeIfPresent(formula, forKey: .formula)
        case let .setFolded(nodeID, _):
            try c.encode(nodeID.rawValue, forKey: .id)
        case let .setPin(nodeID, position):
            try c.encode(nodeID.rawValue, forKey: .id)
            if let position {
                try c.encode(position.x, forKey: .x)
                try c.encode(position.y, forKey: .y)
            }
        case let .move(nodeID, newParentID, index):
            try c.encode(nodeID.rawValue, forKey: .id)
            try c.encode(newParentID.rawValue, forKey: .to)
            try c.encode(index, forKey: .index)
        case let .delete(nodeIDs):
            try c.encode(nodeIDs.map(\.rawValue), forKey: .ids)
        }
    }
}
