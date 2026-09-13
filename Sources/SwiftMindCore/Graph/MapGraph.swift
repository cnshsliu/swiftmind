import Foundation

/// Connectivity derived from node-links and the tree. Recomputed from the map;
/// never stored.
public struct MapGraph: Equatable, Sendable {
    public var ids: Set<NodeID>
    /// Target node-id → nodes that link to it.
    public var incoming: [NodeID: [NodeID]]
    /// Non-root nodes with no children, no outbound links, and no inbound node-links.
    public var orphans: Set<NodeID>
    /// Nodes that point at a missing node-id.
    public var danglingSources: Set<NodeID>

    public static func analyze(_ map: MindMap) -> MapGraph {
        var ids: Set<NodeID> = []
        var incoming: [NodeID: [NodeID]] = [:]
        var dangling: Set<NodeID> = []
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
        func orphansWalk(_ node: Node, isRoot: Bool, into set: inout Set<NodeID>) {
            if !isRoot {
                let noKids = node.children.isEmpty
                let noOut = node.links.isEmpty
                let noIn = incoming[node.id]?.isEmpty ?? true
                if noKids && noOut && noIn {
                    set.insert(node.id)
                }
            }
            for link in node.links {
                if case .node(let target) = link, !ids.contains(target) {
                    dangling.insert(node.id)
                }
            }
            for child in node.children {
                orphansWalk(child, isRoot: false, into: &set)
            }
        }
        var orphans: Set<NodeID> = []
        orphansWalk(map.root, isRoot: true, into: &orphans)
        return MapGraph(ids: ids, incoming: incoming, orphans: orphans, danglingSources: dangling)
    }

    public func backlinks(to id: NodeID) -> [NodeID] {
        incoming[id] ?? []
    }
}
