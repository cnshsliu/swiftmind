import Foundation
import SwiftMindCore

// swiftmind <command> <file> [flags]
// Commands: read, find, validate, add-child, add-sibling, set-text, set-note,
//           set-attr, set-formula, fold, unfold, pin, unpin, move, delete, batch

let args = Array(CommandLine.arguments.dropFirst())

/// Bumped on every CLI behavior change; keep in sync before running
/// scripts/install-cli.sh so `swiftmind --version` reflects the installed build.
let swiftmindCLIVersion = "1.1.0"

if args.first == "--version" || args.first == "version" {
    print("swiftmind \(swiftmindCLIVersion)")
    exit(0)
}

func usage() -> Never {
    MapFile.fail(.usage("""
    usage: swiftmind <command> <file> [flags]
      swiftmind --version              print the CLI version
      read <file>                      print the map as a JSON tree
      find <file> --query <text>       search titles/notes, print matching node ids
      validate <file>                  decode + re-encode check
      add-child <file> --parent <id> --text <t> [--side auto|left|right] [--id <newid>]
      add-sibling <file> --of <id> --text <t> [--id <newid>]
      set-text <file> --id <id> --text <t>
      set-note <file> --id <id> --markdown <md>
      set-attr <file> --id <id> --name <n> --value <v>   (empty value removes)
      set-formula <file> --id <id> --formula <f>          (empty clears)
      fold|unfold <file> --id <id>
      pin <file> --id <id> --x <n> --y <n> | unpin <file> --id <id>
      move <file> --id <id> --to <parentId> [--index <n>]
      delete <file> --ids <id,id,...>
      batch <file> [ops.json]          ops from file or stdin; all-or-nothing
    """))
}

/// Parse `--flag value` pairs; bare `--flag` (no value) and positionals are
/// reported separately so commands can reject ambiguous input.
func parseArgs(_ args: [String]) -> (flags: [String: String], bare: Set<String>, positional: [String]) {
    var flags: [String: String] = [:]
    var bare: Set<String> = []
    var positional: [String] = []
    var i = 0
    while i < args.count {
        let arg = args[i]
        if arg.hasPrefix("--") {
            let name = String(arg.dropFirst(2))
            if i + 1 < args.count, !args[i + 1].hasPrefix("--") {
                flags[name] = args[i + 1]
                i += 2
            } else {
                bare.insert(name)
                i += 1
            }
        } else {
            positional.append(arg)
            i += 1
        }
    }
    return (flags, bare, positional)
}

guard args.count >= 2 else { usage() }
let command = args[0]
let path = args[1]
let parsed = parseArgs(Array(args.dropFirst(2)))
let flags = parsed.flags

do {
    switch command {
    case "read":
        let map = try MapFile.load(path)
        MapFile.printJSON(MapFile.jsonObject(for: map))
    case "validate":
        let map = try MapFile.load(path)
        _ = try HTMLCodec.encode(map, includeSkin: false)
        MapFile.printJSON(["ok": true, "file": path])
    case "find":
        guard let query = flags["query"] else {
            throw CLIError.usage("find requires --query")
        }
        let map = try MapFile.load(path)
        let hits = MapSearch.search(map: map, query: query)
        MapFile.printJSON(hits.map {
            ["id": $0.nodeID.rawValue, "title": $0.title, "matchInNote": $0.matchInNote]
        })
    default:
        try WriteCommands.run(command: command, path: path, flags: parsed.flags, bare: parsed.bare, positional: parsed.positional)
    }
} catch let error as CLIError {
    MapFile.fail(error)
} catch let error as BatchOpError {
    let payload: [String: Any] = ["error": [
        "code": "op_error",
        "message": error.message,
        "opIndex": error.opIndex,
        "op": error.opName,
    ]]
    if let data = try? JSONSerialization.data(withJSONObject: payload),
       let text = String(data: data, encoding: .utf8) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    } else {
        FileHandle.standardError.write(Data("op_error at op \(error.opIndex)\n".utf8))
    }
    exit(3)
} catch {
    MapFile.fail(.op(error.localizedDescription))
}
