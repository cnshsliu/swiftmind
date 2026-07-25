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
}
