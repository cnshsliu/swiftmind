import SwiftUI
import SwiftMindCore

/// Primary actions only — fold/pin live in Node menu + ⌘K (apple-design: slim chrome).
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
        session.store.selection.selectedIDs.contains { $0 != rootID }
    }

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: addChild) {
                Label("Add Child", systemImage: "plus.circle")
            }
            .help("Add child (⌘T)")
            .accessibilityIdentifier("toolbarAddChild")

            Button(action: addSibling) {
                Label("Add Sibling", systemImage: "plus.square.on.square")
            }
            .help("Add sibling (⇧⌘T)")
            .disabled(!canAddSibling)
            .accessibilityIdentifier("toolbarAddSibling")

            Button(action: deleteSelection) {
                Label("Delete", systemImage: "trash")
            }
            .help("Delete selection · ⌘Z to undo")
            .disabled(!canDelete)
            .accessibilityIdentifier("toolbarDelete")

            Button(action: { session.undo() }) {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .help("Undo (⌘Z)")
            .disabled(!session.canUndo)
            .accessibilityIdentifier("toolbarUndo")

            Button(action: { session.redo() }) {
                Label("Redo", systemImage: "arrow.uturn.forward")
            }
            .help("Redo (⇧⌘Z)")
            .disabled(!session.canRedo)
            .accessibilityIdentifier("toolbarRedo")

            ControlGroup {
                Button {
                    session.zoomOut()
                } label: {
                    Label("Zoom Out", systemImage: "minus.magnifyingglass")
                }
                .help("Zoom Out (⌘-)")
                .disabled(session.viewport.isAtMinScale)
                .accessibilityIdentifier("toolbarZoomOut")

                Button {
                    session.zoomIn()
                } label: {
                    Label("Zoom In", systemImage: "plus.magnifyingglass")
                }
                .help("Zoom In (⌘+)")
                .disabled(session.viewport.isAtMaxScale)
                .accessibilityIdentifier("toolbarZoomIn")

                Button {
                    session.resetToActualSize()
                } label: {
                    Label("Actual Size", systemImage: "1.magnifyingglass")
                }
                .help("Actual Size (⌘0)")
                .disabled(session.viewport.isActualSize)
                .accessibilityIdentifier("toolbarActualSize")
            }
        }
    }

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
}
