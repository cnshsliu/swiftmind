import Foundation
import SwiftMindCore

enum WriteCommands {
    static func run(command: String, path: String, flags: [String: String]) throws {
        func required(_ name: String) throws -> String {
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
            let side = flags["side"].flatMap { NodeSide(rawValue: $0) } ?? .auto
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
                value: flags["value"] ?? ""
            )]
        case "set-formula":
            ops = [.setFormula(nodeID: try id("id"), formula: flags["formula"])]
        case "fold":
            ops = [.setFolded(nodeID: try id("id"), isFolded: true)]
        case "unfold":
            ops = [.setFolded(nodeID: try id("id"), isFolded: false)]
        case "pin":
            guard let x = Double(try required("x")), let y = Double(try required("y")) else {
                throw CLIError.usage("pin requires numeric --x and --y")
            }
            ops = [.setPin(nodeID: try id("id"), position: Point2D(x: x, y: y))]
        case "unpin":
            ops = [.setPin(nodeID: try id("id"), position: nil)]
        case "move":
            ops = [.move(
                nodeID: try id("id"),
                newParentID: try id("to"),
                index: flags["index"].flatMap { Int($0) } ?? 0
            )]
        case "delete":
            let ids = try required("ids")
                .split(separator: ",")
                .map { NodeID(rawValue: String($0).trimmingCharacters(in: .whitespaces)) }
            guard !ids.isEmpty else { throw CLIError.usage("delete requires --ids") }
            ops = [.delete(nodeIDs: ids)]
        case "batch":
            ops = try loadBatchOps(path: path, flags: flags)
        default:
            throw CLIError.usage("unknown command: \(command)")
        }

        var map = try MapFile.load(path)
        let affected = try BatchOps.apply(ops, to: &map)
        try MapFile.save(map, to: path)
        MapFile.printJSON(["ok": true, "affected": affected.map(\.rawValue)])
    }

    /// `swiftmind batch <file> [ops.json]` — ops from the positional JSON file
    /// or stdin ("-"). Flags arrive positionally after <file>, so we re-read
    /// Process arguments for a non-flag third argument.
    private static func loadBatchOps(path: String, flags: [String: String]) throws -> [MapOp] {
        let positional = CommandLine.arguments.dropFirst(3).filter { !$0.hasPrefix("--") }
        let data: Data
        if let opsPath = positional.first, opsPath != "-" {
            guard let fileData = try? Data(contentsOf: URL(fileURLWithPath: opsPath)) else {
                throw CLIError.file("cannot read ops file \(opsPath)")
            }
            data = fileData
        } else {
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
