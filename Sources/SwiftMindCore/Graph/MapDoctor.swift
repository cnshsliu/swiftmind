import Foundation

public struct MapHealthIssue: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable, Equatable {
        case danglingNodeLink
        case emptyTitle
        case formulaError
        case staleBookmark
        case duplicateID
        case orphan
    }

    public var kind: Kind
    public var nodeID: NodeID?
    public var message: String

    public var id: String { "\(kind.rawValue)-\(nodeID?.rawValue ?? "_")-\(message)" }

    public init(kind: Kind, nodeID: NodeID?, message: String) {
        self.kind = kind
        self.nodeID = nodeID
        self.message = message
    }
}

/// Vault health: dangling links, empty titles, formula errors, stale bookmarks,
/// duplicate ids, orphans. All derived from the map; never stored.
public enum MapDoctor {
    public static func inspect(_ map: MindMap) -> [MapHealthIssue] {
        let graph = MapGraph.analyze(map)
        var issues: [MapHealthIssue] = []
        var seen: [NodeID: Int] = [:]
        var engine = FormulaEngine()

        func walk(_ node: Node) {
            seen[node.id, default: 0] += 1
            if node.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(MapHealthIssue(
                    kind: .emptyTitle,
                    nodeID: node.id,
                    message: "Empty title"
                ))
            }
            for link in node.links {
                if case .node(let target) = link, !graph.ids.contains(target) {
                    issues.append(MapHealthIssue(
                        kind: .danglingNodeLink,
                        nodeID: node.id,
                        message: "Link to missing node \(target.rawValue)"
                    ))
                }
            }
            if graph.orphans.contains(node.id) {
                issues.append(MapHealthIssue(
                    kind: .orphan,
                    nodeID: node.id,
                    message: "Orphan: nothing links here and it links nowhere"
                ))
            }
            if let value = engine.result(for: node.id, in: map), case .error(let message) = value {
                issues.append(MapHealthIssue(
                    kind: .formulaError,
                    nodeID: node.id,
                    message: "#ERR: \(message)"
                ))
            }
            for child in node.children {
                walk(child)
            }
        }
        walk(map.root)

        for (id, count) in seen where count > 1 {
            issues.append(MapHealthIssue(
                kind: .duplicateID,
                nodeID: id,
                message: "Duplicate id \(id.rawValue) (\(count)×)"
            ))
        }
        for bookmark in map.bookmarks where map.node(id: bookmark.nodeID) == nil {
            issues.append(MapHealthIssue(
                kind: .staleBookmark,
                nodeID: bookmark.nodeID,
                message: "Bookmark “\(bookmark.label)” points at a missing node"
            ))
        }
        return issues
    }
}
