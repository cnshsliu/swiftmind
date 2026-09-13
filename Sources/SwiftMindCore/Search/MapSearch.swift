import Foundation

public struct MapSearchHit: Equatable, Sendable, Identifiable {
    public var id: NodeID { nodeID }
    public var nodeID: NodeID
    public var title: String
    /// True when the query matched noteMarkdown but not the title.
    public var matchInNote: Bool

    public init(nodeID: NodeID, title: String, matchInNote: Bool) {
        self.nodeID = nodeID
        self.title = title
        self.matchInNote = matchInNote
    }
}

public enum UniqueSearchResult: Equatable, Sendable {
    case none
    case one(MapSearchHit)
    /// Multiple hits after preferring an exact title match — do not guess.
    case ambiguous([MapSearchHit])
}

public enum MapSearch {
    /// Case-insensitive substring match on title and noteMarkdown. Empty query → [].
    public static func search(map: MindMap, query: String) -> [MapSearchHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        var hits: [MapSearchHit] = []
        walk(map.root, query: q, into: &hits)
        return hits
    }

    private static func walk(_ node: Node, query: String, into hits: inout [MapSearchHit]) {
        let titleHit = node.text.range(of: query, options: .caseInsensitive) != nil
        let noteHit = node.noteMarkdown.range(of: query, options: .caseInsensitive) != nil
        if titleHit || noteHit {
            hits.append(MapSearchHit(nodeID: node.id, title: node.text, matchInNote: noteHit && !titleHit))
        }
        for c in node.children {
            walk(c, query: query, into: &hits)
        }
    }

    /// Resolve a query to at most one node. Exact title (case-insensitive) wins
    /// when several substring hits exist; two exact titles still refuse.
    public static func resolveUnique(map: MindMap, query: String) -> UniqueSearchResult {
        let hits = search(map: map, query: query)
        switch hits.count {
        case 0: return .none
        case 1: return .one(hits[0])
        default:
            let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let exact = hits.filter { $0.title.compare(needle, options: .caseInsensitive) == .orderedSame }
            if exact.count == 1 { return .one(exact[0]) }
            return .ambiguous(exact.isEmpty ? hits : exact)
        }
    }
}
