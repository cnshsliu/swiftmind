import Foundation

/// Minimal MCP server on stdio (newline-delimited JSON-RPC 2.0,
/// protocolVersion 2025-06-18). Forwards tool calls to the running app
/// via BridgeClient. Loops until stdin closes.
enum MCPServer {
    static let protocolVersion = "2025-06-18"

    static let tools: [[String: Any]] = [
        [
            "name": "read_map",
            "description": "Read the map currently open in SwiftMind as a JSON tree, including computed formula results.",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
        ],
        [
            "name": "find_nodes",
            "description": "Case-insensitive search of titles/notes in the open map.",
            "inputSchema": [
                "type": "object",
                "properties": ["query": ["type": "string"]],
                "required": ["query"],
            ],
        ],
        [
            "name": "apply_ops",
            "description": "Apply a batch of map ops (same op objects as `swiftmind batch`) to the open map. All-or-nothing, one undo step in the app.",
            "inputSchema": [
                "type": "object",
                "properties": ["ops": ["type": "array", "items": ["type": "object"]]],
                "required": ["ops"],
            ],
        ],
        [
            "name": "get_session",
            "description": "Session state: open map path/title, selection, undo depth, brain mode.",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
        ],
        [
            "name": "new_map",
            "description": "Create a new map in the default library and open it in the app.",
            "inputSchema": [
                "type": "object",
                "properties": ["title": ["type": "string"]],
            ],
        ],
    ]

    /// MCP tool name → bridge method.
    private static let methodForTool = [
        "read_map": "read",
        "find_nodes": "find",
        "apply_ops": "applyOps",
        "get_session": "session",
        "new_map": "new",
    ]

    static func run() -> Never {
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = message["method"] as? String
            else { continue }
            let id = message["id"]  // nil for notifications

            switch method {
            case "initialize":
                guard let id else { continue }
                respond(id: id, result: [
                    "protocolVersion": protocolVersion,
                    "capabilities": ["tools": [:] as [String: Any]],
                    "serverInfo": ["name": "swiftmind", "version": swiftmindCLIVersion],
                ])
            case "notifications/initialized", "notifications/cancelled":
                continue
            case "ping":
                guard let id else { continue }
                respond(id: id, result: [:])
            case "tools/list":
                guard let id else { continue }
                respond(id: id, result: ["tools": tools])
            case "tools/call":
                guard let id else { continue }
                let params = message["params"] as? [String: Any] ?? [:]
                handleToolCall(id: id, params: params)
            default:
                guard let id else { continue }
                respondError(id: id, code: -32601, message: "method not found: \(method)")
            }
        }
        exit(0)
    }

    private static func handleToolCall(id: Any, params: [String: Any]) {
        let tool = params["name"] as? String
        guard let tool, let method = methodForTool[tool] else {
            respond(id: id, result: [
                "content": [["type": "text", "text": "unknown tool: \(tool ?? "<missing>")"]],
                "isError": true,
            ])
            return
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        do {
            let response = try BridgeClient.call(method: method, params: arguments)
            if let ok = response["ok"] as? Bool, ok,
               let result = response["result"] {
                respond(id: id, result: [
                    "content": [[
                        "type": "text",
                        "text": jsonText(result),
                    ]],
                ])
            } else {
                let error = response["error"] as? [String: Any]
                let message = error?["message"] as? String ?? "bridge error"
                respond(id: id, result: [
                    "content": [["type": "text", "text": message]],
                    "isError": true,
                ])
            }
        } catch {
            respond(id: id, result: [
                "content": [["type": "text", "text": String(describing: error)]],
                "isError": true,
            ])
        }
    }

    private static func jsonText(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: value, options: [.prettyPrinted, .sortedKeys]
        ), let text = String(data: data, encoding: .utf8) else {
            return String(describing: value)
        }
        return text
    }

    private static func respond(id: Any, result: [String: Any]) {
        write(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func respondError(id: Any, code: Int, message: String) {
        write(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private static func write(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        print(text)
        fflush(stdout)
    }
}
