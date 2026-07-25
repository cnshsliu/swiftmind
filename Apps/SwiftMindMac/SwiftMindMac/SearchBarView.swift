import SwiftUI
import SwiftMindCore

/// Sidebar search over node titles and notes; selecting a hit updates the session selection.
struct SearchBarView: View {
    @ObservedObject var session: DocumentSession
    @Binding var query: String
    var isSearchFocused: FocusState<Bool>.Binding

    @State private var hits: [MapSearchHit] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search titles & notes", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused(isSearchFocused)
                .onSubmit {
                    if let first = hits.first {
                        session.select(first.nodeID)
                    }
                }
                .onChange(of: query) { _, q in
                    refreshHits(query: q)
                }
                .onChange(of: session.revision) { _, _ in
                    refreshHits(query: query)
                }

            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Type to search")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else if hits.isEmpty {
                Text("No matches")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                List(hits) { hit in
                    Button {
                        session.select(hit.nodeID)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hit.title.isEmpty ? "(untitled)" : hit.title)
                                .lineLimit(2)
                                .foregroundStyle(.primary)
                            if hit.matchInNote {
                                Text("Note match")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.sidebar)
                .frame(maxHeight: .infinity)
            }
        }
    }

    private func refreshHits(query: String) {
        hits = MapSearch.search(map: session.store.map, query: query)
    }
}
