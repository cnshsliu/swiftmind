import SwiftUI
import SwiftMindCore

struct OutlineMapView: View {
    @ObservedObject var session: DocumentSession

    var body: some View {
        List {
            OutlineRow(node: session.store.map.root, session: session)
        }
        .listStyle(.sidebar)
        // Force tree refresh when commands mutate the store.
        .id(session.revision)
    }
}

struct OutlineRow: View {
    let node: Node
    @ObservedObject var session: DocumentSession
    @State private var draftText: String

    init(node: Node, session: DocumentSession) {
        self.node = node
        self.session = session
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
                OutlineRow(node: child, session: session)
            }
        } label: {
            HStack(spacing: 8) {
                TextField("Title", text: $draftText)
                    .textFieldStyle(.plain)
                    .onSubmit(commitText)
                    .onExitCommand(perform: revertText)

                if !node.children.isEmpty {
                    Text("\(node.children.count)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                }
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                session.select(node.id)
            }
        }
        .onChange(of: node.text) { _, newValue in
            if draftText != newValue {
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
