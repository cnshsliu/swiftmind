import SwiftUI
import SwiftMindCore

struct ContentView: View {
    @Binding var document: SwiftMindFileDocument
    @StateObject private var session: DocumentSession
    @State private var inspectorPresented = true

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
                Text("Nodes")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text(session.store.map.root.text)
                    .lineLimit(3)
                if let primary = session.store.selection.primary {
                    Text("Selected: \(primary.rawValue)")
                        .font(.caption2)
                        .foregroundStyle(.quaternary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding()
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
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
        .toolbar {
            EditorToolbar(session: session)
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
    }
}

#Preview {
    ContentView(document: .constant(SwiftMindFileDocument()))
}
