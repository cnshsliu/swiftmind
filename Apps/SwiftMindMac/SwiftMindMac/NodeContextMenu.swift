import SwiftUI
import SwiftMindCore

/// Shared right-click actions for a node (canvas + outline).
struct NodeContextMenu: View {
    @ObservedObject var session: DocumentSession
    let nodeID: NodeID

    var body: some View {
        let rootID = session.store.map.root.id
        let node = session.store.map.node(id: nodeID)
        let isRoot = nodeID == rootID

        Button("Add Child") {
            session.select(nodeID)
            session.apply(InsertChildCommand(parentID: nodeID, text: "New Idea", side: .auto))
        }
        if !isRoot {
            Button("Add Sibling") {
                session.select(nodeID)
                session.apply(InsertSiblingCommand(siblingID: nodeID, text: "New Idea", side: .auto))
            }
        }
        Divider()
        Button("Rename") {
            session.select(nodeID)
            NotificationCenter.default.post(name: .swiftMindEditNoteInPlace, object: nodeID)
        }
        Button("Edit Note") {
            session.select(nodeID)
            NotificationCenter.default.post(name: .swiftMindToggleNoteEditor, object: nil)
        }
        if let node, !node.children.isEmpty {
            Button(node.isFolded ? "Unfold" : "Fold") {
                session.select(nodeID)
                session.apply(SetFoldedCommand(nodeID: nodeID, isFolded: !node.isFolded))
            }
        }
        if let node {
            Button(node.positionPin == nil ? "Pin" : "Unpin") {
                togglePin(node)
            }
        }
        if !isRoot {
            Divider()
            Button("Delete", role: .destructive) {
                session.apply(DeleteNodesCommand(nodeIDs: [nodeID]))
            }
        }
    }

    private func togglePin(_ node: Node) {
        session.select(nodeID)
        if node.positionPin != nil {
            session.apply(SetPinCommand(nodeID: nodeID, positionPin: nil))
            return
        }
        let snapshot = session.store.snapshot()
        if let visual = snapshot.nodes.first(where: { $0.id == nodeID }) {
            session.apply(
                SetPinCommand(
                    nodeID: nodeID,
                    positionPin: Point2D(x: visual.frame.midX, y: visual.frame.midY)
                )
            )
        } else {
            session.apply(SetPinCommand(nodeID: nodeID, positionPin: .zero))
        }
    }
}
