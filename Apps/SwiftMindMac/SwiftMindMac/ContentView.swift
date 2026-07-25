import SwiftUI
import SwiftMindCore

struct ContentView: View {
    @Binding var document: SwiftMindFileDocument
    /// Per-window session: each ContentView owns its own store/undo stack.
    @StateObject private var session: DocumentSession
    @State private var inspectorPresented = true
    @State private var searchQuery = ""
    @State private var palettePresented = false
    @State private var mapTitleDraft = ""
    @FocusState private var searchFocused: Bool

    init(document: Binding<SwiftMindFileDocument>) {
        self._document = document
        let map = document.wrappedValue.map
        _session = StateObject(wrappedValue: DocumentSession(map: map))
        _mapTitleDraft = State(initialValue: map.title)
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

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .frame(minWidth: 780, minHeight: 480)
        .onChange(of: session.revision) { _, _ in
            document.map = session.exportMap()
            let title = session.store.map.title
            if mapTitleDraft != title {
                mapTitleDraft = title
            }
        }
        .onChange(of: document.map.id) { _, _ in
            session.syncFromDocument(document.map)
            mapTitleDraft = document.map.title
        }
        .sheet(isPresented: $palettePresented) {
            CommandPaletteView(session: session, isPresented: $palettePresented)
                .presentationBackground(.regularMaterial)
        }
        .toolbar {
            EditorToolbar(session: session)
            ToolbarItem(placement: .automatic) {
                Button {
                    palettePresented = true
                } label: {
                    Label("Command Palette", systemImage: "command")
                }
                .keyboardShortcut("k", modifiers: .command)
                .help("Command palette (⌘K)")
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    searchFocused = true
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .keyboardShortcut("f", modifiers: .command)
                .help("Focus search (⌘F)")
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    inspectorPresented.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .help("Toggle inspector")
            }
        }
        .inspector(isPresented: $inspectorPresented) {
            InspectorView(session: session)
                .inspectorColumnWidth(min: 240, ideal: 280, max: 380)
        }
        .focusedSceneValue(\.documentSession, session)
        .focusedSceneValue(\.presentCommandPalette, $palettePresented)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
            VStack(alignment: .leading, spacing: 6) {
                Text("MAP")
                    .font(Theme.sidebarCaption)
                    .foregroundStyle(.secondary)
                    .tracking(0.6)

                TextField("Untitled map", text: $mapTitleDraft)
                    .textFieldStyle(.plain)
                    .font(.title3.weight(.semibold))
                    .onSubmit { commitMapTitle() }
                    .onChange(of: mapTitleDraft) { _, newValue in
                        if newValue != session.store.map.title {
                            session.apply(SetMapTitleCommand(newTitle: newValue))
                        }
                    }
            }

            Divider().opacity(0.6)

            SearchBarView(
                session: session,
                query: $searchQuery,
                isSearchFocused: $searchFocused
            )

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 4) {
                Text("\(nodeCount) nodes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(selectedLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.ultraThinMaterial)
        .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 320)
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

                Spacer()

                Text(selectedLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.bar)

            Divider().opacity(0.5)

            Group {
                switch session.viewMode {
                case .outline:
                    OutlineMapView(session: session)
                case .map:
                    MapCanvasView(session: session)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Status strip — quiet wayfinding (Apple: status feedback without noise).
            HStack(spacing: 12) {
                Label("\(nodeCount) nodes", systemImage: "circle.grid.2x2")
                if session.store.selection.primary != nil {
                    Text("·")
                        .foregroundStyle(.quaternary)
                    Text(selectedLabel)
                        .lineLimit(1)
                }
                Spacer()
                Text("Space/⌘ drag pan · ⌥ drag pin · ⌘K palette")
                    .foregroundStyle(.tertiary)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }

    private func commitMapTitle() {
        let trimmed = mapTitleDraft
        guard trimmed != session.store.map.title else { return }
        session.apply(SetMapTitleCommand(newTitle: trimmed))
    }

    private func countNodes(_ node: Node) -> Int {
        1 + node.children.reduce(0) { $0 + countNodes($1) }
    }
}

#Preview {
    ContentView(document: .constant(SwiftMindFileDocument()))
}
