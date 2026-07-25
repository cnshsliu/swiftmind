import SwiftUI
import SwiftMindCore

/// Primary editor actions for the mind map (structure + undo).
/// Keyboard shortcuts are declared on app `Commands` (see SwiftMindMacApp);
/// toolbar buttons mirror the same actions for discoverability.
struct EditorToolbar: ToolbarContent {
    @ObservedObject var session: DocumentSession

    private var primary: NodeID? {
        session.store.selection.primary
    }

    private var rootID: NodeID {
        session.store.map.root.id
    }

    private var canAddSibling: Bool {
        guard let primary else { return false }
        return primary != rootID
    }

    private var canDelete: Bool {
        let ids = session.store.selection.selectedIDs
        return ids.contains { $0 != rootID }
    }

    private var canToggleFold: Bool {
        primary != nil
    }

    private var primaryIsFolded: Bool {
        guard let primary,
              let node = session.store.map.node(id: primary) else { return false }
        return node.isFolded
    }

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: addChild) {
                Label("Add Child", systemImage: "plus.circle")
            }
            .help("Add a child under the selection (⌘T)")

            Button(action: addSibling) {
                Label("Add Sibling", systemImage: "plus.square.on.square")
            }
            .help("Add a sibling after the selection (⇧⌘T)")
            .disabled(!canAddSibling)

            Button(action: deleteSelection) {
                Label("Delete", systemImage: "trash")
            }
            .help("Delete selected nodes (cannot delete root)")
            .disabled(!canDelete)

            Button(action: toggleFold) {
                Label(
                    primaryIsFolded ? "Unfold" : "Fold",
                    systemImage: primaryIsFolded
                        ? "arrow.up.left.and.arrow.down.right"
                        : "arrow.down.right.and.arrow.up.left"
                )
            }
            .help(primaryIsFolded ? "Unfold selected node (⌘.)" : "Fold selected node (⌘.)")
            .disabled(!canToggleFold)

            Button(action: { session.undo() }) {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .help("Undo (⌘Z)")
            .disabled(!session.canUndo)

            Button(action: { session.redo() }) {
                Label("Redo", systemImage: "arrow.uturn.forward")
            }
            .help("Redo (⇧⌘Z)")
            .disabled(!session.canRedo)
        }
    }

    // MARK: - Actions

    private func addChild() {
        let parentID = primary ?? rootID
        session.apply(
            InsertChildCommand(parentID: parentID, text: "New Idea", side: .auto)
        )
    }

    private func addSibling() {
        guard let primary, primary != rootID else { return }
        session.apply(
            InsertSiblingCommand(siblingID: primary, text: "New Idea", side: .auto)
        )
    }

    private func deleteSelection() {
        let ids = session.store.selection.selectedIDs.filter { $0 != rootID }
        guard !ids.isEmpty else { return }
        session.apply(DeleteNodesCommand(nodeIDs: Array(ids)))
    }

    private func toggleFold() {
        guard let primary,
              let node = session.store.map.node(id: primary) else { return }
        session.apply(SetFoldedCommand(nodeID: primary, isFolded: !node.isFolded))
    }
}
