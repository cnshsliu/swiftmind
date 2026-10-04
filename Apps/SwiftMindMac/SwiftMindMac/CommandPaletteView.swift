import SwiftUI
import AppKit
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
        appModel: AppModel?,
        query: String,
        dismiss: @escaping () -> Void
    ) -> [PaletteItem] {
        var items: [PaletteItem] = []

        items.append(PaletteItem(id: "add-child", title: "Add Child", subtitle: "⌘T", systemImage: "plus.circle") {
            let parent = session.store.selection.primary ?? session.store.map.root.id
            session.apply(InsertChildCommand(parentID: parent, text: "New Idea", side: .auto, style: StickyNodeStyle.read()))
            dismiss()
        })

        items.append(PaletteItem(id: "add-sibling", title: "Add Sibling", subtitle: "⇧⌘T", systemImage: "plus.square.on.square") {
            guard let primary = session.store.selection.primary,
                  primary != session.store.map.root.id else { return }
            session.apply(InsertSiblingCommand(siblingID: primary, text: "New Idea", side: .auto, style: StickyNodeStyle.read()))
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

        if !session.isBrainMode {
            items.append(PaletteItem(id: "fold-all", title: "Fold All Below", subtitle: "⇧⌘.", systemImage: "rectangle.compress.vertical") {
                foldAll(session)
                dismiss()
            })
            items.append(PaletteItem(id: "rename", title: "Rename", subtitle: "↩", systemImage: "pencil") {
                let id = session.store.selection.primary
                dismiss()
                DispatchQueue.main.async {
                    session.viewMode = .map
                    session.canvasPaletteRequest = .rename(id)
                }
            })
            items.append(PaletteItem(id: "move-up", title: "Move Up", subtitle: "⌥↑", systemImage: "arrow.up") {
                moveSelection(session, delta: -1)
                dismiss()
            })
            items.append(PaletteItem(id: "move-down", title: "Move Down", subtitle: "⌥↓", systemImage: "arrow.down") {
                moveSelection(session, delta: 1)
                dismiss()
            })
        }

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

        if !session.isBrainMode {
            items.append(PaletteItem(id: "edit-note-inplace", title: "Edit Note at Node", subtitle: "⌘E", systemImage: "square.and.pencil") {
                NotificationCenter.default.post(name: .swiftMindEditNoteInPlace, object: nil)
                dismiss()
            })
            items.append(PaletteItem(id: "edit-note", title: "Edit Note", subtitle: "E", systemImage: "text.alignleft") {
                NotificationCenter.default.post(name: .swiftMindToggleNoteEditor, object: nil)
                dismiss()
            })
            items.append(PaletteItem(id: "toggle-note-expansion", title: "Toggle Note Expansion", subtitle: "X", systemImage: "rectangle.expand.vertical") {
                NotificationCenter.default.post(name: .swiftMindToggleNoteExpansion, object: nil)
                dismiss()
            })
            items.append(PaletteItem(id: "toggle-sketch", title: "Sketch", subtitle: "D", systemImage: "scribble") {
                NotificationCenter.default.post(name: .swiftMindToggleSketch, object: nil)
                dismiss()
            })
            if let id = session.store.selection.primary,
               session.store.map.node(id: id)?.sketch != nil {
                items.append(PaletteItem(id: "remove-sketch", title: "Remove Sketch", subtitle: nil, systemImage: "trash") {
                    session.apply(SetSketchCommand(nodeID: id, sketch: nil, width: nil, height: nil))
                    dismiss()
                })
            }
        }

        items.append(PaletteItem(id: "undo", title: "Undo", subtitle: "⌘Z", systemImage: "arrow.uturn.backward") {
            session.undo()
            dismiss()
        })

        items.append(PaletteItem(id: "redo", title: "Redo", subtitle: "⇧⌘Z", systemImage: "arrow.uturn.forward") {
            session.redo()
            dismiss()
        })

        if !session.isBrainMode {
            items.append(PaletteItem(id: "zoom-in", title: "Zoom In", subtitle: "⌘+", systemImage: "plus.magnifyingglass") {
                session.zoomIn()
                dismiss()
            })
            items.append(PaletteItem(id: "zoom-out", title: "Zoom Out", subtitle: "⌘-", systemImage: "minus.magnifyingglass") {
                session.zoomOut()
                dismiss()
            })
            items.append(PaletteItem(id: "zoom-actual", title: "Actual Size", subtitle: "⌘0", systemImage: "1.magnifyingglass") {
                session.resetToActualSize()
                dismiss()
            })
            items.append(PaletteItem(id: "zoom-fit", title: "Zoom to Fit", subtitle: "⌘9", systemImage: "viewfinder") {
                session.zoomToFit()
                dismiss()
            })
            items.append(PaletteItem(id: "follow", title: "Follow Mode", subtitle: "F", systemImage: "scope") {
                dismiss()
                DispatchQueue.main.async {
                    session.viewMode = .map
                    session.canvasPaletteRequest = .toggleFollow
                }
            })
            items.append(PaletteItem(id: "show-map", title: "Show Map", subtitle: nil, systemImage: "point.3.filled.connected.trianglepath.dotted") {
                session.viewMode = .map
                dismiss()
            })
            items.append(PaletteItem(id: "show-outline", title: "Show Outline", subtitle: nil, systemImage: "list.bullet") {
                session.viewMode = .outline
                dismiss()
            })
            items.append(PaletteItem(id: "find", title: "Find", subtitle: "⌘F", systemImage: "magnifyingglass") {
                NotificationCenter.default.post(name: .swiftMindPresentSearch, object: nil)
                dismiss()
            })
        }

        items.append(PaletteItem(id: "toggle-inspector", title: "Toggle Inspector", subtitle: nil, systemImage: "sidebar.trailing") {
            NotificationCenter.default.post(name: .swiftMindToggleInspector, object: nil)
            dismiss()
        })

        if !session.isBrainMode {
            items.append(PaletteItem(id: "copy", title: "Copy", subtitle: "⌘C", systemImage: "doc.on.doc") {
                ClipboardService.copySelection(from: session)
                dismiss()
            })
            items.append(PaletteItem(id: "cut", title: "Cut", subtitle: "⌘X", systemImage: "scissors") {
                ClipboardService.cutSelection(from: session)
                dismiss()
            })
            items.append(PaletteItem(id: "paste", title: "Paste", subtitle: "⌘V", systemImage: "doc.on.clipboard") {
                ClipboardService.paste(into: session)
                dismiss()
            })
        }

        if let appModel {
            items.append(PaletteItem(id: "new-map", title: "New Map", subtitle: "⌘N", systemImage: "doc.badge.plus") {
                if session.isBrainMode {
                    appModel.createMapNearSelection()
                } else {
                    appModel.createAndOpenMap()
                }
                dismiss()
            })
            items.append(PaletteItem(id: "open-map", title: "Open Map…", subtitle: "⌘O", systemImage: "folder") {
                dismiss()
                appModel.openMapPanel()
            })
            items.append(PaletteItem(id: "my-brain", title: "My Brain", subtitle: "⇧⌘B", systemImage: "brain.head.profile") {
                appModel.showBrain()
                dismiss()
            })
            items.append(PaletteItem(id: "add-vault", title: "Add Vault…", subtitle: nil, systemImage: "folder.badge.plus") {
                dismiss()
                appModel.addVaultPanel()
            })
            if !session.isBrainMode {
                items.append(PaletteItem(id: "save", title: "Save", subtitle: "⌘S", systemImage: "square.and.arrow.down") {
                    appModel.saveCurrentMap()
                    dismiss()
                })
            }
            items.append(PaletteItem(id: "help", title: "SwiftMind Help", subtitle: nil, systemImage: "questionmark.circle") {
                appModel.openHelpMap(fresh: true)
                dismiss()
            })
        }

        if session.isBrainMode {
            items.append(PaletteItem(id: "open-selection", title: "Open Selection", subtitle: "⌘↩", systemImage: "arrow.right.circle") {
                appModel?.activateSelection()
                dismiss()
            })
            if let id = session.store.selection.primary,
               let node = session.store.map.node(id: id),
               let path = BrainMapBuilder.path(of: node),
               let kind = BrainMapBuilder.kind(of: node) {
                if kind == .map {
                    items.append(PaletteItem(id: "copy-map", title: "Copy to…", subtitle: nil, systemImage: "doc.on.doc") {
                        NotificationCenter.default.post(
                            name: .swiftMindTransferMap,
                            object: nil,
                            userInfo: ["path": path, "move": false]
                        )
                        dismiss()
                    })
                    items.append(PaletteItem(id: "move-map", title: "Move to…", subtitle: nil, systemImage: "folder") {
                        NotificationCenter.default.post(
                            name: .swiftMindTransferMap,
                            object: nil,
                            userInfo: ["path": path, "move": true]
                        )
                        dismiss()
                    })
                    items.append(PaletteItem(id: "show-finder", title: "Show in Finder", subtitle: nil, systemImage: "arrow.up.forward.app") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        dismiss()
                    })
                } else if kind == .vault {
                    items.append(PaletteItem(id: "detach-vault", title: "Remove from My Brain", subtitle: nil, systemImage: "minus.circle") {
                        NotificationCenter.default.post(
                            name: .swiftMindDetachVault,
                            object: nil,
                            userInfo: ["path": path]
                        )
                        dismiss()
                    })
                }
            }
        }

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

        if !session.isBrainMode {
            items.append(PaletteItem(id: "capture", title: "Capture…", subtitle: "⇧⌘I → Inbox", systemImage: "tray.and.arrow.down") {
                dismiss()
                appModel?.promptCapture()
            })
            items.append(PaletteItem(id: "filter-orphan", title: "Filter Orphans", subtitle: "is:orphan", systemImage: "circle.dotted") {
                session.applyQuiet(SetFilterCommand(filter: MapFilter(mode: .highlight, rule: .orphan)))
                dismiss()
            })
            items.append(PaletteItem(id: "filter-dangling", title: "Filter Dangling Links", subtitle: "is:dangling", systemImage: "link.badge.plus") {
                session.applyQuiet(SetFilterCommand(filter: MapFilter(mode: .highlight, rule: .danglingLink)))
                dismiss()
            })
            for issue in MapDoctor.inspect(session.store.map).prefix(20) {
                let title = "Doctor: \(issue.message)"
                let nodeID = issue.nodeID
                items.append(PaletteItem(id: "doctor-\(issue.id)", title: title, subtitle: issue.kind.rawValue, systemImage: "stethoscope") {
                    if let nodeID { session.select(nodeID) }
                    dismiss()
                })
            }
        }

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

    /// Same rule as the Node menu: fold every descendant of the selection
    /// (a leaf folds the branch above it). One undo step.
    private static func foldAll(_ session: DocumentSession) {
        guard !session.isBrainMode,
              let id = session.store.selection.primary,
              let node = session.store.map.node(id: id) else { return }
        let target = node.children.isEmpty
            ? session.store.map.parentID(of: id).flatMap { session.store.map.node(id: $0) }
            : node
        guard let target, !target.children.isEmpty else {
            NSSound.beep()
            return
        }
        var descendants: [NodeID] = []
        func collect(_ node: Node) {
            for child in node.children {
                descendants.append(child.id)
                collect(child)
            }
        }
        collect(target)
        let foldTo = !descendants.allSatisfy { session.store.map.node(id: $0)?.isFolded == true }
        let ops: [MapOp] = descendants.map { .setFolded(nodeID: $0, isFolded: foldTo) }
        session.apply(CompositeAgentCommand(ops: ops))
    }

    private static func moveSelection(_ session: DocumentSession, delta: Int) {
        guard let id = session.store.selection.primary,
              id != session.store.map.root.id,
              let parentID = session.store.map.parentID(of: id),
              let parent = session.store.map.node(id: parentID),
              let current = parent.children.firstIndex(where: { $0.id == id })
        else {
            NSSound.beep()
            return
        }
        let target = MapStore.reorderTarget(current: current, delta: delta, count: parent.children.count)
        guard target != current else {
            NSSound.beep()
            return
        }
        session.apply(MoveNodeCommand(nodeID: id, newParentID: parentID, index: target))
    }
}

// MARK: - View

/// ⌘K command palette — instant keyboard UI (no open animation frills).
struct CommandPaletteView: View {
    @ObservedObject var session: DocumentSession
    var appModel: AppModel?
    @Binding var isPresented: Bool

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var queryFocused: Bool

    private var items: [PaletteItem] {
        PaletteBuilder.items(session: session, appModel: appModel, query: query) {
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
