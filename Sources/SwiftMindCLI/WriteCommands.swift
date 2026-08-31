import Foundation
import SwiftMindCore

enum WriteCommands {
    static func run(command: String, path: String, flags: [String: String], bare: Set<String>, positional: [String]) throws {
        func required(_ name: String) throws -> String {
            if bare.contains(name) {
                throw CLIError.usage("\(command): --\(name) requires a value")
            }
            guard let value = flags[name] else {
                throw CLIError.usage("\(command) requires --\(name)")
            }
            return value
        }
        func id(_ name: String) throws -> NodeID {
            NodeID(rawValue: try required(name))
        }

        let ops: [MapOp]
        switch command {
        case "add-child":
            let side: NodeSide
            if let raw = flags["side"] {
                guard let parsed = NodeSide(rawValue: raw) else {
                    throw CLIError.usage("add-child: unknown --side \"\(raw)\" (auto|left|right)")
                }
                side = parsed
            } else {
                side = .auto
            }
            ops = [.addChild(
                parentID: try id("parent"),
                newNodeID: flags["id"].map { NodeID(rawValue: $0) } ?? .generate(),
                text: try required("text"),
                side: side
            )]
        case "add-sibling":
            ops = [.addSibling(
                siblingID: try id("of"),
                newNodeID: flags["id"].map { NodeID(rawValue: $0) } ?? .generate(),
                text: try required("text")
            )]
        case "set-text":
            ops = [.setText(nodeID: try id("id"), text: try required("text"))]
        case "set-note":
            ops = [.setNote(nodeID: try id("id"), markdown: try required("markdown"))]
        case "set-attr":
            ops = [.setAttribute(
                nodeID: try id("id"),
                name: try required("name"),
                value: try required("value")
            )]
        case "set-formula":
            ops = [.setFormula(nodeID: try id("id"), formula: try required("formula"))]
        case "fold":
            ops = [.setFolded(nodeID: try id("id"), isFolded: true)]
        case "unfold":
            ops = [.setFolded(nodeID: try id("id"), isFolded: false)]
        case "pin":
            guard let x = Double(try required("x")), let y = Double(try required("y")),
                  x.isFinite, y.isFinite else {
                throw CLIError.usage("pin requires finite numeric --x and --y")
            }
            ops = [.setPin(nodeID: try id("id"), position: Point2D(x: x, y: y))]
        case "unpin":
            ops = [.setPin(nodeID: try id("id"), position: nil)]
        case "move":
            let index: Int
            if let raw = flags["index"] {
                guard let parsed = Int(raw) else {
                    throw CLIError.usage("move: --index must be an integer, got \"\(raw)\"")
                }
                index = parsed
            } else {
                index = 0
            }
            ops = [.move(
                nodeID: try id("id"),
                newParentID: try id("to"),
                index: index
            )]
        case "delete":
            let ids = try required("ids")
                .split(separator: ",")
                .map { NodeID(rawValue: String($0).trimmingCharacters(in: .whitespaces)) }
            guard !ids.isEmpty else { throw CLIError.usage("delete requires --ids") }
            ops = [.delete(nodeIDs: ids)]
        case "batch":
            ops = try loadBatchOps(positional: positional)
        default:
            throw CLIError.usage("unknown command: \(command)")
        }

        var map = try MapFile.load(path)
        let affected = try BatchOps.apply(ops, to: &map)
        try MapFile.save(map, to: path)
        MapFile.printJSON(["ok": true, "affected": affected.map(\.rawValue)])
    }

    /// `swiftmind batch <file> [ops.json]` — ops from the positional JSON file
    /// or piped stdin.
    private static func loadBatchOps(positional: [String]) throws -> [MapOp] {
        let data: Data
        if let opsPath = positional.first, opsPath != "-" {
            guard let fileData = try? Data(contentsOf: URL(fileURLWithPath: opsPath)) else {
                throw CLIError.file("cannot read ops file \(opsPath)")
            }
            data = fileData
        } else {
            if isatty(STDIN_FILENO) != 0 {
                throw CLIError.usage("batch requires an ops JSON file or piped stdin")
            }
            data = FileHandle.standardInput.readDataToEndOfFile()
        }
        do {
            let ops = try JSONDecoder().decode([MapOp].self, from: data)
            guard !ops.isEmpty else { throw CLIError.usage("batch ops array is empty") }
            return ops
        } catch let error as CLIError {
            throw error
        } catch {
            throw CLIError.usage("invalid ops JSON: \(error.localizedDescription)")
        }
    }
}
