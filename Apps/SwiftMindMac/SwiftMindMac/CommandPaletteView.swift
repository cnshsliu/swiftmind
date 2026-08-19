import SwiftUI
import SwiftMindCore

// MARK: - Model

struct PaletteItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let systemImage: String
    let run: () -> Void
}

@MainActor
enum PaletteBuilder {
    private static let emptyQueryJumpLimit = 40

    static func items(
        session: DocumentSession,
        query: String,
        dismiss: @escaping () -> Void
    ) -> [PaletteItem] {
        var items: [PaletteItem] = []

        items.append(PaletteItem(id: "add-child", title: "Add Child", subtitle: "⌘T", systemImage: "plus.circle") {
            let parent = session.store.selection.primary ?? session.store.map.root.id
            session.apply(InsertChildCommand(parentID: parent, text: "New Idea", side: .auto))
            dismiss()
        })

        items.append(PaletteItem(id: "add-sibling", title: "Add Sibling", subtitle: "⇧⌘T", systemImage: "plus.square.on.square") {
            guard let primary = session.store.selection.primary,
                  primary != session.store.map.root.id else { return }
            session.apply(InsertSiblingCommand(siblingID: primary, text: "New Idea", side: .auto))
            dismiss()
        })

        items.append(PaletteItem(id: "delete", title: "Delete", subtitle: "⌫", systemImage: "trash") {
            let root = session.store.map.root.id
            let ids = session.store.selection.selectedIDs.filter { $0 != root }
            guard !ids.isEmpty else { return }
            session.apply(DeleteNodesCommand(nodeIDs: Array(ids)))
            dismiss()
        })

        items.append(PaletteItem(id: "fold", title: "Toggle Fold", subtitle: "⌘.", systemImage: "arrow.up.left.and.arrow.down.right") {
            guard let primary = session.store.selection.primary,
                  let node = session.store.map.node(id: primary) else { return }
            session.apply(SetFoldedCommand(nodeID: primary, isFolded: !node.isFolded))
            dismiss()
        })

        items.append(PaletteItem(id: "pin", title: "Pin", subtitle: "⇧⌘P", systemImage: "pin") {
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

        items.append(PaletteItem(id: "unpin", title: "Unpin", subtitle: "⇧⌘P", systemImage: "pin.slash") {
            guard let primary = session.store.selection.primary,
                  let node = session.store.map.node(id: primary),
                  node.positionPin != nil else { return }
            session.apply(SetPinCommand(nodeID: primary, positionPin: nil))
            dismiss()
        })

        items.append(PaletteItem(id: "undo", title: "Undo", subtitle: "⌘Z", systemImage: "arrow.uturn.backward") {
            session.undo()
            dismiss()
        })

        items.append(PaletteItem(id: "redo", title: "Redo", subtitle: "⇧⌘Z", systemImage: "arrow.uturn.forward") {
            session.redo()
            dismiss()
        })

        items.append(PaletteItem(id: "bookmark", title: "Bookmark Selection", subtitle: nil, systemImage: "bookmark") {
            guard let id = session.store.selection.primary,
                  let node = session.store.map.node(id: id) else { return }
            let label = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
            session.apply(
                AddBookmarkCommand(
                    bookmark: Bookmark(nodeID: id, label: label.isEmpty ? "Bookmark" : label)
                )
            )
            dismiss()
        })

        items.append(PaletteItem(id: "clear-filter", title: "Clear Filter", subtitle: nil, systemImage: "line.3.horizontal.decrease.circle") {
            session.applyQuiet(SetFilterCommand(filter: nil))
            dismiss()
        })

        items.append(PaletteItem(id: "run-script", title: "Run Script…", subtitle: "Sandboxed JS (L3)", systemImage: "play.rectangle") {
            dismiss()
            ScriptRunner.runViaOpenPanel(session: session)
        })

        for (name, _) in session.store.map.styleSheet.styles.sorted(by: { $0.key < $1.key }) {
            let styleKey = name
            items.append(
                PaletteItem(
                    id: "style-\(styleKey)",
                    title: "Apply Style: \(styleKey.capitalized)",
                    subtitle: "Named style",
                    systemImage: "paintpalette"
                ) {
                    guard let id = session.store.selection.primary else { return }
                    session.applyQuiet(SetStyleNameCommand(nodeID: id, styleName: styleKey))
                    dismiss()
                }
            )
        }

        items.append(
            PaletteItem(
                id: "style-clear",
                title: "Clear Named Style",
                subtitle: "Named style",
                systemImage: "paintbrush"
            ) {
                guard let id = session.store.selection.primary else { return }
                session.applyQuiet(SetStyleNameCommand(nodeID: id, styleName: nil))
                dismiss()
            }
        )

        for bookmark in session.store.map.bookmarks {
            let bm = bookmark
            let label = bm.label.isEmpty
                ? (session.store.map.node(id: bm.nodeID)?.text ?? "Bookmark")
                : bm.label
            items.append(
                PaletteItem(
                    id: "goto-bookmark-\(bm.id)",
                    title: "Go to: \(label)",
                    subtitle: "Bookmark",
                    systemImage: "bookmark.fill"
                ) {
                    session.select(bm.nodeID)
                    dismiss()
                }
            )
        }

        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            let nodes = Array(flatten(session.store.map.root).prefix(emptyQueryJumpLimit))
            for node in nodes {
                let label = node.text.isEmpty ? "(untitled)" : node.text
                let nodeID = node.id
                items.append(
                    PaletteItem(
                        id: "jump-\(nodeID.rawValue)",
                        title: label,
                        subtitle: "Go to node",
                        systemImage: "arrow.right.circle"
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
            let subtitle = hit.matchInNote ? "In note" : "Go to node"
            let nodeID = hit.nodeID
            jumpItems.append(
                PaletteItem(
                    id: "jump-\(nodeID.rawValue)",
                    title: label,
                    subtitle: subtitle,
                    systemImage: hit.matchInNote ? "note.text" : "arrow.right.circle"
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

/// ⌘K command palette — instant keyboard UI (no open animation frills).
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
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Command or node…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($queryFocused)
                    .accessibilityIdentifier("paletteQueryField")
                    .onSubmit { runSelected() }
                    .onChange(of: query) { _, _ in
                        selectedIndex = 0
                    }
                Text("esc")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.secondary.opacity(0.12))
                    )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider().opacity(0.5)

            if items.isEmpty {
                ContentUnavailableView(
                    "No matches",
                    systemImage: "magnifyingglass",
                    description: Text("Try another command or node title.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(Array(items.enumerated()), id: \.element.id) { index, item in
                        Button {
                            selectedIndex = index
                            item.run()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: item.systemImage)
                                    .font(.body)
                                    .foregroundStyle(index == selectedIndex ? Color.accentColor : Color.secondary)
                                    .frame(width: 22)
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
                                if let subtitle = item.subtitle, subtitle.contains("⌘") || subtitle.contains("⇧") || subtitle == "⌫" {
                                    Text(subtitle)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(index == selectedIndex ? Color.accentColor.opacity(0.14) : Color.clear)
                                .padding(.horizontal, 4)
                        )
                        .id(index)
                    }
                    .listStyle(.plain)
                    .onChange(of: selectedIndex) { _, idx in
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(idx, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 440, idealWidth: 500, minHeight: 380, idealHeight: 440)
        .background(.regularMaterial)
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
