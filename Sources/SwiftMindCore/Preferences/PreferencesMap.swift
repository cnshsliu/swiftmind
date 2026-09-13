import Foundation

/// Session chrome (zoom/pan) stored as a SwiftMind map — same HTML codec as
/// documents, not undoable, not mixed into the user's map file.
///
/// Structure:
///   SwiftMind Preferences
///     View
///       <one child per document, attrs: map-id, scale, offset-x, offset-y>
public enum PreferencesMap {
    public static let mapID = "m_swiftmind_preferences"
    public static let viewNodeID = NodeID(rawValue: "n_prefs_view")

    public static func makeEmpty() -> MindMap {
        let view = Node(id: viewNodeID, text: "View", side: .right)
        let root = Node(
            id: NodeID(rawValue: "n_prefs_root"),
            text: "SwiftMind Preferences",
            side: .auto,
            style: .rootDefault,
            children: [view]
        )
        return MindMap(id: mapID, title: "SwiftMind Preferences", root: root)
    }

    public static func viewport(forMapID mapID: String, in prefs: MindMap) -> CanvasViewport? {
        guard let view = prefs.node(id: viewNodeID) else { return nil }
        guard let node = view.children.first(where: { $0.attributeValue(named: "map-id") == mapID }) else {
            return nil
        }
        let scale = Double(node.attributeValue(named: "scale") ?? "") ?? 1
        let ox = Double(node.attributeValue(named: "offset-x") ?? "") ?? 0
        let oy = Double(node.attributeValue(named: "offset-y") ?? "") ?? 0
        return CanvasViewport(scale: scale, offset: Point2D(x: ox, y: oy))
    }

    public static func upsertViewport(
        mapID: String,
        title: String,
        viewport: CanvasViewport,
        into prefs: inout MindMap
    ) {
        if prefs.node(id: viewNodeID) == nil {
            prefs.root.children.insert(Node(id: viewNodeID, text: "View", side: .right), at: 0)
        }
        let label = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let attrs = [
            NodeAttribute(name: "map-id", value: mapID),
            NodeAttribute(name: "scale", value: format(viewport.scale)),
            NodeAttribute(name: "offset-x", value: format(viewport.offset.x)),
            NodeAttribute(name: "offset-y", value: format(viewport.offset.y)),
        ]
        var found = false
        _ = prefs.updateNode(id: viewNodeID) { view in
            if let i = view.children.firstIndex(where: { $0.attributeValue(named: "map-id") == mapID }) {
                view.children[i].text = label.isEmpty ? mapID : label
                view.children[i].attributes = attrs
                found = true
            }
        }
        if !found {
            let child = Node(
                text: label.isEmpty ? mapID : label,
                attributes: attrs,
                side: .right
            )
            _ = prefs.updateNode(id: viewNodeID) { view in
                view.children.append(child)
            }
        }
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.6g", value)
    }
}
