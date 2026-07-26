import SwiftUI
import SwiftMindCore

struct ContentView: View {
    @Binding var document: SwiftMindFileDocument
    @StateObject private var session: DocumentSession
    @State private var inspectorPresented = true
    @State private var searchQuery = ""
    @State private var palettePresented = false
    @State private var mapTitleDraft = ""
    @FocusState private var searchFocused: Bool
    @FocusState private var mapTitleFocused: Bool

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

    private var isFreshMap: Bool {
        session.store.map.root.children.isEmpty
            && session.store.map.root.text == "Central Idea"
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .frame(minWidth: 780, minHeight: 480)
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
        .onChange(of: session.revision) { _, _ in
            document.map = session.exportMap()
            let title = session.store.map.title
            if !mapTitleFocused, mapTitleDraft != title {
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
        // Keyboard shortcuts still registered on app Commands.
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
                Text("MAP")
                    .font(Theme.sidebarCaption)
                    .foregroundStyle(.secondary)
                    .tracking(0.6)

                TextField("Untitled map", text: $mapTitleDraft)
                    .textFieldStyle(.plain)
                    .font(.title3.weight(.semibold))
                    .focused($mapTitleFocused)
                    .onSubmit { commitMapTitle() }
                    .onChange(of: mapTitleFocused) { _, focused in
                        if !focused { commitMapTitle() }
                    }
            }

            Divider().opacity(0.5)

            SearchBarView(
                session: session,
                query: $searchQuery,
                isSearchFocused: $searchFocused
            )

            Spacer(minLength: 0)

            Text("\(nodeCount) nodes")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Trust system sidebar material — avoid stacking ultraThin on top.
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
                .labelsHidden()
                .accessibilityLabel("View mode")

                Spacer()
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
            }

            // Single status strip for selection (not repeated in sidebar/header).
            HStack(spacing: 10) {
                Label("\(nodeCount)", systemImage: "circle.grid.2x2")
                    .help("Node count")
                Text("·")
                    .foregroundStyle(.quaternary)
                Text(selectedLabel)
                    .lineLimit(1)
                Spacer()
                if session.canUndo {
                    Text("⌘Z undo")
                        .foregroundStyle(.tertiary)
                }
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
        session.applyQuiet(SetMapTitleCommand(newTitle: trimmed))
    }

    private func countNodes(_ node: Node) -> Int {
        1 + node.children.reduce(0) { $0 + countNodes($1) }
    }
}

#Preview {
    ContentView(document: .constant(SwiftMindFileDocument()))
}
