import Foundation
import SwiftMindCore

enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    case file(String)
    case op(String)

    var description: String {
        switch self {
        case .usage(let m), .file(let m), .op(let m): return m
        }
    }

    var code: String {
        switch self {
        case .usage: return "usage"
        case .file: return "file_error"
        case .op: return "op_error"
        }
    }

    var exitCode: Int32 {
        switch self {
        case .usage: return 1
        case .file: return 2
        case .op: return 3
        }
    }
}

enum MapFile {
    static func load(_ path: String) throws -> MindMap {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url) else {
            throw CLIError.file("cannot read \(path)")
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw CLIError.file("not UTF-8: \(path)")
        }
        do {
            return try HTMLCodec.decode(html)
        } catch {
            throw CLIError.file("not a SwiftMind map: \(path) (\(error.localizedDescription))")
        }
    }

    /// File modification date for clobber detection (nil if unreadable).
    static func modificationDate(_ path: String) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
    }

    /// Atomic write (temp file + rename via .atomic) so the app's file watcher
    /// sees exactly one change event and never a partial file.
    static func save(_ map: MindMap, to path: String) throws {        let html: String
        do {
            html = try HTMLCodec.encode(map, includeSkin: true)
        } catch {
            throw CLIError.op("encode failed: \(error.localizedDescription)")
        }
        do {
            try Data(html.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            throw CLIError.file("cannot write \(path): \(error.localizedDescription)")
        }
    }

    /// JSON tree for `read` (file mode: no computed formula values).
    static func jsonObject(for map: MindMap) -> [String: Any] {
        AgentProtocol.mapJSON(for: map)
    }

    static func printJSON(_ object: Any) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys]
        ), let text = String(data: data, encoding: .utf8) else {
            FileHandle.standardError.write(Data(#"{"error":{"code":"internal","message":"JSON encoding failed"}}"#.utf8))
            exit(3)
        }
        print(text)
    }

    static func fail(_ error: CLIError) -> Never {
        let payload: [String: Any] = ["error": ["code": error.code, "message": error.description]]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let text = String(data: data, encoding: .utf8) {
            FileHandle.standardError.write(Data((text + "\n").utf8))
        }
        exit(error.exitCode)
    }
}
