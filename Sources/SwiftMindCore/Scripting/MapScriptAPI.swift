import Foundation

/// Immutable node view handed to scripts (value type — a script can never hold
/// a live reference into the map).
public struct NodeScriptSnapshot: Equatable, Sendable {
    public var id: NodeID
    public var text: String
    public var note: String
    public var attributes: [String: String]
    public var icons: [String]

    public init(node: Node) {
        self.id = node.id
        self.text = node.text
        self.note = node.noteMarkdown
        self.attributes = Dictionary(uniqueKeysWithValues: node.attributes.map { ($0.name, $0.value) })
        self.icons = node.icons.map(\.id)
    }
}

/// The bridge a `ScriptRuntime` uses to read the map and record intents.
/// Read methods return value snapshots; mutations are only ever *recorded*.
public protocol MapScriptAPI: AnyObject {
    var mapTitle: String { get }
    var rootID: NodeID { get }
    func nodeSnapshot(id: NodeID) -> NodeScriptSnapshot?
    func childIDs(of id: NodeID) -> [NodeID]
    /// Title/note substring search, case-insensitive.
    func find(_ query: String) -> [NodeID]
    func record(_ intent: ScriptIntent)
    func log(_ message: String)
}

/// Core-side implementation: holds the map by value, accumulates intents + logs.
public final class MapScriptContext: MapScriptAPI {
    public let map: MindMap
    public private(set) var intents: [ScriptIntent] = []
    public private(set) var logs: [String] = []

    public init(map: MindMap) {
        self.map = map
    }

    public var mapTitle: String { map.title }
    public var rootID: NodeID { map.root.id }

    public func nodeSnapshot(id: NodeID) -> NodeScriptSnapshot? {
        map.node(id: id).map(NodeScriptSnapshot.init(node:))
    }

    public func childIDs(of id: NodeID) -> [NodeID] {
        map.node(id: id)?.children.map(\.id) ?? []
    }

    public func find(_ query: String) -> [NodeID] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        return Self.findMatches(in: map.root, needle: needle)
    }

    public func record(_ intent: ScriptIntent) {
        intents.append(intent)
    }

    public func log(_ message: String) {
        logs.append(message)
    }

    private static func findMatches(in node: Node, needle: String) -> [NodeID] {
        let hit =
            node.text.range(of: needle, options: .caseInsensitive) != nil
            || node.noteMarkdown.range(of: needle, options: .caseInsensitive) != nil
        return (hit ? [node.id] : []) + node.children.flatMap { findMatches(in: $0, needle: needle) }
    }
}
