import Foundation

/// Pure traversal helpers for spatial keyboard navigation (hjkl / arrows).
/// Side resolution (which way is "outward") comes from the layout snapshot —
/// these functions only walk the tree.
public enum SpatialNavigator {

    /// Next/previous sibling within the parent's child list. nil at the ends (no wrap).
    public static func sibling(of id: NodeID, in map: MindMap, offset: Int) -> NodeID? {
        guard let parentID = map.parentID(of: id),
              let parent = map.node(id: parentID),
              let index = parent.children.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        let target = index + offset
        guard parent.children.indices.contains(target) else { return nil }
        return parent.children[target].id
    }

    /// Child to focus when moving outward: the remembered child if it is still a
    /// direct child, otherwise the first child. nil when there are no children.
    public static func childToFocus(of id: NodeID, in map: MindMap, remembered: NodeID?) -> NodeID? {
        guard let node = map.node(id: id), !node.children.isEmpty else { return nil }
        if let remembered, node.children.contains(where: { $0.id == remembered }) {
            return remembered
        }
        return node.children.first?.id
    }
}
