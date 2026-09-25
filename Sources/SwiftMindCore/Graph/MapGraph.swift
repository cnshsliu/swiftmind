import Foundation

/// Connectivity derived from node-links and the tree. Recomputed from the map;
/// never stored.
public struct MapGraph: Equatable, Sendable {
    public var ids: Set<NodeID>
    /// Target node-id → nodes that link to it.
    public var incoming: [NodeID: [NodeID]]
    /// Nodes unreachable from the root (empty in a well-formed single-tree
    /// map; kept for import/registry paths that can introduce strays).
    public var orphans: Set<NodeID>
    /// Nodes that point at a missing node-id.
    public var danglingSources: Set<NodeID>

    public static func analyze(_ map: MindMap) -> MapGraph {
        var ids: Set<NodeID> = []
        var incoming: [NodeID: [NodeID]] = [:]
        func walk(_ node: Node) {
            ids.insert(node.id)
            for link in node.links {
                if case .node(let target) = link {
                    incoming[target, default: []].append(node.id)
                }
            }
            for child in node.children {
                walk(child)
            }
        }
        walk(map.root)
        // Dangling sources: links that point at an id no node carries
        // (`ids` is complete only after the full walk, so filter here).
        let dangling = Set(
            incoming.compactMap { key, sources in ids.contains(key) ? nil : sources }.flatMap { $0 }
        )
        // Orphan = unreachable from the root. The node universe IS the root
        // walk (single-tree model: every node lives under `map.root`), so a
        // well-formed map can never hold one — the set is empty by
        // construction until a future import/registry path can add strays;
        // then subtract the reachable walk from that universe here.
        // (This previously flagged leaves with no links in or out, which
        // reported ordinary healthy leaves as broken.)
        let orphans = Set<NodeID>()
        return MapGraph(ids: ids, incoming: incoming, orphans: orphans, danglingSources: dangling)
    }

    public func backlinks(to id: NodeID) -> [NodeID] {
        incoming[id] ?? []
    }
}
