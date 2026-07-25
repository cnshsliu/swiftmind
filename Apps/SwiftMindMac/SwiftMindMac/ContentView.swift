import SwiftUI
import SwiftMindCore

struct ContentView: View {
    @Binding var document: SwiftMindFileDocument
    /// Per-window session: each ContentView owns its own store/undo stack.
    @StateObject private var session: DocumentSession
    @State private var inspectorPresented = true
    @State private var searchQuery = ""
    @State private var palettePresented = false
    @FocusState private var searchFocused: Bool

    init(document: Binding<SwiftMindFileDocument>) {
        self._document = document
        _session = StateObject(wrappedValue: DocumentSession(map: document.wrappedValue.map))
    }

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 8) {
                Text("SwiftMind")
                    .font(.headline)
                Text(session.store.map.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Divider()
                SearchBarView(
                    session: session,
                    query: $searchQuery,
                    isSearchFocused: $searchFocused
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding()
            .navigationSplitViewColumnWidth(min: 180, ideal: 240)
        } detail: {
            VStack(spacing: 0) {
                Picker("View", selection: $session.viewMode) {
                    ForEach(DocumentSession.ViewMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 10)
                .frame(maxWidth: 280)

                Divider()

                switch session.viewMode {
                case .outline:
                    OutlineMapView(session: session)
                case .map:
                    MapCanvasView(session: session)
                }
            }
        }
        .frame(minWidth: 720, minHeight: 420)
        .onChange(of: session.revision) { _, _ in
            document.map = session.exportMap()
        }
        .sheet(isPresented: $palettePresented) {
            CommandPaletteView(session: session, isPresented: $palettePresented)
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
                .help("Toggle style inspector")
            }
        }
        .inspector(isPresented: $inspectorPresented) {
            InspectorView(session: session)
                .inspectorColumnWidth(min: 220, ideal: 260, max: 360)
        }
        .focusedSceneValue(\.documentSession, session)
        .focusedSceneValue(\.presentCommandPalette, $palettePresented)
    }
}

#Preview {
    ContentView(document: .constant(SwiftMindFileDocument()))
}
