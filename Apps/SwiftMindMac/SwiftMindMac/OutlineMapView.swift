import SwiftUI
import SwiftMindCore

struct OutlineMapView: View {
    @ObservedObject var session: DocumentSession

    var body: some View {
        List {
            OutlineRow(node: session.store.map.root, session: session, depth: 0)
        }
        .listStyle(.sidebar)
        // Intentionally no .id(session.revision): full List remount stole scroll/focus.
        // Rows observe session and refresh via store-driven redraws.
    }
}

struct OutlineRow: View {
    let node: Node
    @ObservedObject var session: DocumentSession
    let depth: Int
    @State private var draftText: String
    @FocusState private var titleFocused: Bool

    init(node: Node, session: DocumentSession, depth: Int) {
        self.node = node
        self.session = session
        self.depth = depth
        _draftText = State(initialValue: node.text)
    }

    private var isSelected: Bool {
        session.store.selection.selectedIDs.contains(node.id)
    }

    private var isExpanded: Binding<Bool> {
        Binding(
            get: { !node.isFolded },
            set: { expanded in
                let folded = !expanded
                guard folded != node.isFolded else { return }
                session.apply(SetFoldedCommand(nodeID: node.id, isFolded: folded))
            }
        )
    }

    var body: some View {
        DisclosureGroup(isExpanded: isExpanded) {
            ForEach(node.children) { child in
                OutlineRow(node: child, session: session, depth: depth + 1)
            }
        } label: {
            HStack(spacing: 8) {
                if !node.icons.isEmpty {
                    HStack(spacing: 2) {
                        ForEach(Array(node.icons.prefix(3))) { icon in
                            Image(systemName: NodeIcon.sfSymbolNames[icon.id] ?? "circle")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                TextField("Title", text: $draftText)
                    .textFieldStyle(.plain)
                    .font(depth == 0 ? .body.weight(.semibold) : .body)
                    .focused($titleFocused)
                    .onSubmit(commitText)
                    .onExitCommand(perform: revertText)
                    .onChange(of: titleFocused) { _, focused in
                        if !focused { commitText() }
                    }

                if !node.noteMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Image(systemName: "note.text")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if !node.children.isEmpty {
                    Text("\(node.children.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                }
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                session.select(node.id)
            }
        }
        .onChange(of: node.text) { _, newValue in
            if !titleFocused, draftText != newValue {
                draftText = newValue
            }
        }
    }

    private func commitText() {
        let trimmed = draftText
        guard trimmed != node.text else { return }
        session.apply(SetTextCommand(nodeID: node.id, newText: trimmed))
        session.select(node.id)
    }

    private func revertText() {
        draftText = node.text
    }
}

