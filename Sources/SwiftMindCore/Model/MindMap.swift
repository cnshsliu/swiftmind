import Foundation

public struct MindMap: Equatable, Sendable, Codable {
    public var id: String
    public var title: String
    public var schemaVersion: Int
    public var root: Node
    public var attributeRegistry: AttributeRegistry
    public var styleSheet: StyleSheet
    public var activeFilter: MapFilter?
    public var bookmarks: [Bookmark]

    public init(
        id: String,
        title: String,
        schemaVersion: Int = 1,
        root: Node,
        attributeRegistry: AttributeRegistry = AttributeRegistry(),
        styleSheet: StyleSheet = .defaultSheet,
        activeFilter: MapFilter? = nil,
        bookmarks: [Bookmark] = []
    ) {
        self.id = id
        self.title = title
        self.schemaVersion = schemaVersion
        self.root = root
        self.attributeRegistry = attributeRegistry
        self.styleSheet = styleSheet
        self.activeFilter = activeFilter
        self.bookmarks = bookmarks
    }

    public static func makeEmpty(title: String) -> MindMap {
        let root = Node(
            text: "Central Idea",
            side: .auto,
            style: .rootDefault
        )
        return MindMap(
            id: "m_" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16)),
            title: title,
            schemaVersion: 1,
            root: root
        )
    }

    public func node(id: NodeID) -> Node? {
        find(id: id, in: root)
    }

    @discardableResult
    public mutating func updateNode(id: NodeID, _ body: (inout Node) -> Void) -> Bool {
        Self.update(id: id, in: &root, body)
    }

    public func parentID(of id: NodeID) -> NodeID? {
        parentID(of: id, in: root, parent: nil)
    }

    private func parentID(of id: NodeID, in node: Node, parent: NodeID?) -> NodeID? {
        if node.id == id { return parent }
        for child in node.children {
            if let found = parentID(of: id, in: child, parent: node.id) {
                return found
            }
        }
        return nil
    }

    private func find(id: NodeID, in node: Node) -> Node? {
        if node.id == id { return node }
        for child in node.children {
            if let found = find(id: id, in: child) { return found }
        }
        return nil
    }

    private static func update(id: NodeID, in node: inout Node, _ body: (inout Node) -> Void) -> Bool {
        if node.id == id {
            body(&node)
            return true
        }
        for i in node.children.indices {
            if update(id: id, in: &node.children[i], body) {
                return true
            }
        }
        return false
    }
}
