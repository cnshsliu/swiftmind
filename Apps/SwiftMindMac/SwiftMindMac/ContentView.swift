import SwiftUI
import SwiftMindCore

struct ContentView: View {
    @ObservedObject var appModel: AppModel

    var body: some View {
        // Recreate when session instance swaps (brain ↔ map).
        SessionWorkspace(appModel: appModel, session: appModel.session)
            .id(ObjectIdentifier(appModel.session))
            .onReceive(NotificationCenter.default.publisher(for: .swiftMindOpenMapURL)) { note in
                if let url = note.object as? URL {
                    appModel.openMap(at: url)
                }
            }
    }
}

/// Bound to a concrete `DocumentSession` for the lifetime of that session object.
private struct SessionWorkspace: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var session: DocumentSession

    @State private var inspectorPresented = true
    @State private var searchQuery = ""
    @State private var palettePresented = false
    @State private var mapTitleDraft = ""
    @FocusState private var searchFocused: Bool
    @FocusState private var mapTitleFocused: Bool

    init(appModel: AppModel, session: DocumentSession) {
        self.appModel = appModel
        self.session = session
        _mapTitleDraft = State(initialValue: session.store.map.title)
    }

    private var nodeCount: Int {
        countNodes(session.store.map.root)
    }

    private var selectedLabel: String {
        guard let id = session.store.selection.primary,
              let node = session.store.map.node(id: id) else {
            return "No selection"
        }
        let t = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "(untitled)" : t
    }

    private var isFreshMap: Bool {
        !session.isBrainMode
            && session.store.map.root.children.isEmpty
            && session.store.map.root.text == "Central Idea"
    }

    private var windowTitle: String {
        if session.isBrainMode { return "My Brain" }
        if let url = appModel.currentMapURL {
            var name = url.lastPathComponent
            if name.hasSuffix(".swiftmind.html") {
                name = String(name.dropLast(".swiftmind.html".count))
            }
            return name
        }
        return session.store.map.title
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .frame(minWidth: 780, minHeight: 480)
        .navigationTitle(windowTitle)
        .overlay(alignment: .top) {
            if let toast = session.toast {
                StatusToastBanner(toast: toast)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture { session.dismissToast() }
                    .zIndex(100)
            }
        }
        .animation(.easeOut(duration: 0.18), value: session.toast?.id)
        .onChange(of: session.contentRevision) { _, _ in
            let title = session.store.map.title
            if !mapTitleFocused, mapTitleDraft != title {
                mapTitleDraft = title
            }
        }
        .sheet(isPresented: $palettePresented) {
            CommandPaletteView(session: session, isPresented: $palettePresented)
                .presentationBackground(.regularMaterial)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    appModel.showBrain()
                } label: {
                    Label("My Brain", systemImage: "brain.head.profile")
                }
                .help("My Brain — vaults and maps")
                .accessibilityIdentifier("toolbarMyBrain")
            }

            if !session.isBrainMode {
                EditorToolbar(session: session)
            } else {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        appModel.addVaultPanel()
                    } label: {
                        Label("Add Vault", systemImage: "folder.badge.plus")
                    }
                    .help("Add a folder as a mindmap vault")
                    .accessibilityIdentifier("toolbarAddVault")

                    Button {
                        appModel.createMapNearSelection()
                    } label: {
                        Label("New Map", systemImage: "doc.badge.plus")
                    }
                    .help("New map in selected vault/folder")
                    .accessibilityIdentifier("toolbarNewMap")

                    Button {
                        appModel.activateSelection()
                    } label: {
                        Label("Open", systemImage: "arrow.right.circle")
                    }
                    .help("Open map or expand folder (Return)")
                }
            }

            ToolbarItem(placement: .automatic) {
                ControlGroup {
                    Button {
                        palettePresented = true
                    } label: {
                        Label("Commands", systemImage: "command")
                    }
                    .help("Command palette (⌘K)")

                    Button {
                        searchFocused = true
                    } label: {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                    .help("Focus search (⌘F)")

                    Button {
                        inspectorPresented.toggle()
                    } label: {
                        Label("Inspector", systemImage: "sidebar.trailing")
                    }
                    .help("Toggle inspector")
                }
            }
        }
        .inspector(isPresented: $inspectorPresented) {
            InspectorView(session: session)
                .inspectorColumnWidth(min: 240, ideal: 280, max: 380)
        }
        .focusedSceneValue(\.documentSession, session)
        .focusedSceneValue(\.presentCommandPalette, $palettePresented)
        .focusedSceneValue(\.appModel, appModel)
        .background(
            Button("") { palettePresented = true }
                .keyboardShortcut("k", modifiers: .command)
                .opacity(0)
                .allowsHitTesting(false)
        )
        .background(
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .allowsHitTesting(false)
        )
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
            VStack(alignment: .leading, spacing: 6) {
                Text(session.isBrainMode ? "MY BRAIN" : "MAP")
                    .font(Theme.sidebarCaption)
                    .foregroundStyle(.secondary)
                    .tracking(0.6)

                if session.isBrainMode {
                    Text("Vaults & maps")
                        .font(.title3.weight(.semibold))
                        .accessibilityIdentifier("mapTitleField")
                    Text("Double-click a map to open · folders fold")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    TextField("Untitled map", text: $mapTitleDraft)
                        .textFieldStyle(.plain)
                        .font(.title3.weight(.semibold))
                        .focused($mapTitleFocused)
                        .accessibilityLabel("Map title")
                        .accessibilityIdentifier("mapTitleField")
                        .onSubmit { commitMapTitle() }
                        .onChange(of: mapTitleFocused) { _, focused in
                            if !focused { commitMapTitle() }
                        }
                    if let url = appModel.currentMapURL {
                        Text(url.path.replacingOccurrences(
                            of: FileManager.default.homeDirectoryForCurrentUser.path,
                            with: "~"
                        ))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                    }
                }
            }

            Divider().opacity(0.5)

            if session.isBrainMode {
                brainVaultList
            } else {
                SearchBarView(
                    session: session,
                    query: $searchQuery,
                    isSearchFocused: $searchFocused
                )

                Divider().opacity(0.5)

                FilterBarView(session: session)

                Divider().opacity(0.5)

                BookmarksSidebar(session: session)
            }

            Spacer(minLength: 0)

            Text(nodeCountLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 320)
    }

    private var brainVaultList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("VAULTS")
                .font(Theme.sidebarCaption)
                .foregroundStyle(.secondary)
                .tracking(0.6)

            if appModel.library.vaultURLs.isEmpty {
                Text("No vaults yet")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(appModel.library.vaultURLs, id: \.path) { url in
                    Button {
                        selectBrainPath(url.path)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(Color.accentColor)
                            Text(url.lastPathComponent)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Button {
                appModel.addVaultPanel()
            } label: {
                Label("Add Vault…", systemImage: "plus")
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: - Detail

    private var detail: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("View", selection: $session.viewMode) {
                    ForEach(DocumentSession.ViewMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
                .labelsHidden()
                .accessibilityLabel("View mode")
                .accessibilityIdentifier("viewModePicker")

                Spacer()

                if session.isBrainMode {
                    Text("My Brain")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.bar)

            Divider().opacity(0.4)

            ZStack {
                Group {
                    switch session.viewMode {
                    case .outline:
                        OutlineMapView(session: session)
                    case .map:
                        MapCanvasView(session: session)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if isFreshMap, session.viewMode == .map {
                    VStack(spacing: 6) {
                        Text("Start mapping")
                            .font(.headline)
                        Text("⌘T add child · Double-click rename · ⌘K commands")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .allowsHitTesting(false)
                    .offset(y: 120)
                }

                if session.isBrainMode, session.store.map.root.children.isEmpty {
                    VStack(spacing: 8) {
                        Text("Your vaults appear here")
                            .font(.headline)
                        Text("Add a vault folder, then double-click maps to open")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Add Vault…") {
                            appModel.addVaultPanel()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }

            HStack(spacing: 10) {
                Label("\(nodeCount)", systemImage: "circle.grid.2x2")
                    .help("Node count")
                    .accessibilityIdentifier("nodeCountLabel")
                Text("·")
                    .foregroundStyle(.quaternary)
                Text(selectedLabel)
                    .lineLimit(1)
                    .accessibilityIdentifier("selectedNodeLabel")
                Spacer()
                if session.isBrainMode {
                    Text("Return open · ⌘. fold")
                        .foregroundStyle(.tertiary)
                } else if session.canUndo {
                    Text("⌘Z undo")
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
            .accessibilityIdentifier("statusStrip")
        }
    }

    private var nodeCountLabel: String {
        let total = nodeCount
        if session.store.map.activeFilter != nil {
            let visible = session.store.snapshot().nodes.count
            return "\(visible)/\(total) nodes"
        }
        return "\(total) nodes"
    }

    private func commitMapTitle() {
        guard !session.isBrainMode else { return }
        let trimmed = mapTitleDraft
        guard trimmed != session.store.map.title else { return }
        session.applyQuiet(SetMapTitleCommand(newTitle: trimmed))
    }

    private func countNodes(_ node: Node) -> Int {
        1 + node.children.reduce(0) { $0 + countNodes($1) }
    }

    private func selectBrainPath(_ path: String) {
        func find(_ node: Node) -> NodeID? {
            if BrainMapBuilder.path(of: node) == path { return node.id }
            for c in node.children {
                if let id = find(c) { return id }
            }
            return nil
        }
        if let id = find(session.store.map.root) {
            session.select(id)
        }
    }
}
