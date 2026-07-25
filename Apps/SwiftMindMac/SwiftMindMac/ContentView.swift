import SwiftUI
import SwiftMindCore

struct ContentView: View {
    @Binding var document: SwiftMindFileDocument
    @StateObject private var session: DocumentSession

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
                    mapPlaceholder
                }
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .onChange(of: session.revision) { _, _ in
            document.map = session.exportMap()
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    addChild()
                } label: {
                    Label("Add Child", systemImage: "plus.circle")
                }
                .help("Add a child under the selected node")
                .disabled(session.store.selection.primary == nil)

                Button {
                    session.undo()
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(!session.canUndo)

                Button {
                    session.redo()
                } label: {
                    Label("Redo", systemImage: "arrow.uturn.forward")
                }
                .disabled(!session.canRedo)
            }
        }
    }

    private var mapPlaceholder: some View {
        VStack(spacing: 12) {
            Text(session.store.map.title)
                .font(.title2)
            Text(session.store.map.root.text)
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Map canvas placeholder")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text("Switch to Outline to edit the tree")
                .font(.caption2)
                .foregroundStyle(.quaternary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func addChild() {
        guard let parentID = session.store.selection.primary else { return }
        session.apply(
            InsertChildCommand(parentID: parentID, text: "New Idea")
        )
    }
}

#Preview {
    ContentView(document: .constant(SwiftMindFileDocument()))
}
