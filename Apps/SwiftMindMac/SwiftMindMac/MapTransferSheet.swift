import AppKit
import SwiftUI
import SwiftMindCore

struct MapTransferRequest: Identifiable {
    let id = UUID()
    let source: URL
    let move: Bool
}

/// Copy or move a mind map, pictures included, into a vault folder under a new name.
struct MapTransferSheet: View {
    let source: URL
    let move: Bool
    let folders: [(title: String, url: URL)]
    let onCommit: (URL, String) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @State private var destinationPath: String

    init(
        source: URL,
        move: Bool,
        folders: [(title: String, url: URL)],
        onCommit: @escaping (URL, String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.source = source
        self.move = move
        self.folders = folders
        self.onCommit = onCommit
        self.onCancel = onCancel
        var base = source.lastPathComponent
        if base.lowercased().hasSuffix(".swiftmind.html") {
            base = String(base.dropLast(".swiftmind.html".count))
        }
        _name = State(initialValue: base)
        let parent = source.deletingLastPathComponent().standardizedFileURL.path
        let match = folders.first { $0.url.standardizedFileURL.path == parent }?.url.path
            ?? folders.first?.url.path
            ?? ""
        _destinationPath = State(initialValue: match)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(move ? "Move Mind Map" : "Copy Mind Map")
                .font(.headline)
            Text("The .swiftmind.assets folder next to it moves with the file.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("mapTransferName")
            Text("Destination")
                .font(.subheadline)
            if folders.isEmpty {
                Text("Add a vault folder in Settings → Vaults first.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Destination", selection: $destinationPath) {
                    ForEach(folders, id: \.url.path) { folder in
                        Text(folder.title).tag(folder.url.path)
                    }
                }
                .labelsHidden()
                .accessibilityIdentifier("mapTransferDestination")
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(move ? "Move" : "Copy") {
                    guard let folder = folders.first(where: { $0.url.path == destinationPath }) else { return }
                    onCommit(folder.url, name)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || destinationPath.isEmpty)
                .accessibilityIdentifier("mapTransferCommit")
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}

/// Right-click a map in My Brain.
struct BrainMapFileMenu: View {
    let node: Node

    var body: some View {
        if BrainMapBuilder.kind(of: node) == .vault, let path = BrainMapBuilder.path(of: node) {
            Button("Remove from My Brain") {
                NotificationCenter.default.post(
                    name: .swiftMindDetachVault,
                    object: nil,
                    userInfo: ["path": path]
                )
            }
        }
        if BrainMapBuilder.kind(of: node) == .map, let path = BrainMapBuilder.path(of: node) {
            Button("Copy to…") {
                NotificationCenter.default.post(
                    name: .swiftMindTransferMap,
                    object: nil,
                    userInfo: ["path": path, "move": false]
                )
            }
            Button("Move to…") {
                NotificationCenter.default.post(
                    name: .swiftMindTransferMap,
                    object: nil,
                    userInfo: ["path": path, "move": true]
                )
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
    }
}
