import SwiftUI
import SwiftMindCore

// MARK: - Model

struct PaletteItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let run: () -> Void
}

@MainActor
enum PaletteBuilder {
    /// Maximum jump-to-node rows when the query is empty (flattened tree).
    private static let emptyQueryJumpLimit = 40

    static func items(
        session: DocumentSession,
        query: String,
        dismiss: @escaping () -> Void
    ) -> [PaletteItem] {
        var items: [PaletteItem] = []

        items.append(PaletteItem(id: "add-child", title: "Add Child", subtitle: "⌘T") {
            let parent = session.store.selection.primary ?? session.store.map.root.id
            session.apply(InsertChildCommand(parentID: parent, text: "New Idea", side: .auto))
            dismiss()
        })

        items.append(PaletteItem(id: "add-sibling", title: "Add Sibling", subtitle: "⇧⌘T") {
            guard let primary = session.store.selection.primary,
                  primary != session.store.map.root.id else { return }
            session.apply(InsertSiblingCommand(siblingID: primary, text: "New Idea", side: .auto))
            dismiss()
        })

        items.append(PaletteItem(id: "delete", title: "Delete", subtitle: "⌫") {
            let root = session.store.map.root.id
            let ids = session.store.selection.selectedIDs.filter { $0 != root }
            guard !ids.isEmpty else { return }
            session.apply(DeleteNodesCommand(nodeIDs: Array(ids)))
            dismiss()
        })

        items.append(PaletteItem(id: "fold", title: "Toggle Fold", subtitle: "⌘.") {
            guard let primary = session.store.selection.primary,
                  let node = session.store.map.node(id: primary) else { return }
            session.apply(SetFoldedCommand(nodeID: primary, isFolded: !node.isFolded))
            dismiss()
        })

        items.append(PaletteItem(id: "pin", title: "Pin", subtitle: "⇧⌘P") {
            guard let primary = session.store.selection.primary else { return }
            if let node = session.store.map.node(id: primary), node.positionPin != nil {
                dismiss()
                return
            }
            let snapshot = session.store.snapshot()
            if let visual = snapshot.nodes.first(where: { $0.id == primary }) {
                session.apply(
                    SetPinCommand(
                        nodeID: primary,
                        positionPin: Point2D(x: visual.frame.midX, y: visual.frame.midY)
                    )
                )
            } else {
                session.apply(SetPinCommand(nodeID: primary, positionPin: .zero))
            }
            dismiss()
        })

        items.append(PaletteItem(id: "unpin", title: "Unpin", subtitle: "⇧⌘P") {
            guard let primary = session.store.selection.primary,
                  let node = session.store.map.node(id: primary),
                  node.positionPin != nil else { return }
            session.apply(SetPinCommand(nodeID: primary, positionPin: nil))
            dismiss()
        })

        items.append(PaletteItem(id: "undo", title: "Undo", subtitle: "⌘Z") {
            session.undo()
            dismiss()
        })

        items.append(PaletteItem(id: "redo", title: "Redo", subtitle: "⇧⌘Z") {
            session.redo()
            dismiss()
        })

        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            let nodes = Array(flatten(session.store.map.root).prefix(emptyQueryJumpLimit))
            for node in nodes {
                let label = node.text.isEmpty ? "(untitled)" : node.text
                let nodeID = node.id
                items.append(
                    PaletteItem(
                        id: "jump-\(nodeID.rawValue)",
                        title: "Go to \(label)",
                        subtitle: "Node"
                    ) {
                        session.select(nodeID)
                        dismiss()
                    }
                )
            }
            return items
        }

        let filteredActions = items.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || ($0.subtitle?.localizedCaseInsensitiveContains(q) ?? false)
        }

        var jumpItems: [PaletteItem] = []
        for hit in MapSearch.search(map: session.store.map, query: q) {
            let label = hit.title.isEmpty ? "(untitled)" : hit.title
            let subtitle = hit.matchInNote ? "Note match" : "Node"
            let nodeID = hit.nodeID
            jumpItems.append(
                PaletteItem(
                    id: "jump-\(nodeID.rawValue)",
                    title: "Go to \(label)",
                    subtitle: subtitle
                ) {
                    session.select(nodeID)
                    dismiss()
                }
            )
        }

        return filteredActions + jumpItems
    }

    static func flatten(_ node: Node) -> [Node] {
        [node] + node.children.flatMap { flatten($0) }
    }
}

// MARK: - View

/// ⌘K command palette: filterable actions and jump-to-node.
struct CommandPaletteView: View {
    @ObservedObject var session: DocumentSession
    @Binding var isPresented: Bool

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var queryFocused: Bool

    private var items: [PaletteItem] {
        PaletteBuilder.items(session: session, query: query) {
            isPresented = false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Type a command or search nodes…", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($queryFocused)
                .padding()
                .onSubmit { runSelected() }
                .onChange(of: query) { _, _ in
                    selectedIndex = 0
                }

            Divider()

            if items.isEmpty {
                Text("No matching commands or nodes")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
            } else {
                List(Array(items.enumerated()), id: \.element.id) { index, item in
                    Button {
                        selectedIndex = index
                        item.run()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .foregroundStyle(.primary)
                                if let subtitle = item.subtitle {
                                    Text(subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 8)
                            if index == selectedIndex {
                                Image(systemName: "return")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(index == selectedIndex ? Color.accentColor.opacity(0.15) : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                }
                .listStyle(.plain)
            }
        }
        .frame(minWidth: 420, idealWidth: 480, minHeight: 360, idealHeight: 420)
        .onAppear {
            queryFocused = true
            selectedIndex = 0
        }
        .onExitCommand {
            isPresented = false
        }
        .onKeyPress(.upArrow) {
            moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveSelection(by: 1)
            return .handled
        }
    }

    private func moveSelection(by delta: Int) {
        let count = items.count
        guard count > 0 else {
            selectedIndex = 0
            return
        }
        selectedIndex = (selectedIndex + delta + count) % count
    }

    private func runSelected() {
        let list = items
        guard !list.isEmpty else { return }
        let index = min(max(0, selectedIndex), list.count - 1)
        list[index].run()
    }
}
