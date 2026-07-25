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
            Text("SEARCH")
                .font(Theme.sidebarCaption)
                .foregroundStyle(.secondary)
                .tracking(0.6)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                    .font(.body)
                TextField("Titles & notes", text: $query)
                    .textFieldStyle(.plain)
                    .focused(isSearchFocused)
                    .onSubmit {
                        if let first = hits.first {
                            session.select(first.nodeID)
                        }
                    }
                if !query.isEmpty {
                    Button {
                        query = ""
                        hits = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.85))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .strokeBorder(Theme.hairline.opacity(0.6), lineWidth: 0.5)
            )
            .onChange(of: query) { _, q in
                refreshHits(query: q)
            }
            .onChange(of: session.revision) { _, _ in
                refreshHits(query: query)
            }

            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("⌘F to focus")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
            } else if hits.isEmpty {
                Text("No matches")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(hits) { hit in
                            Button {
                                session.select(hit.nodeID)
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Image(systemName: hit.matchInNote ? "note.text" : "circle.fill")
                                        .font(.system(size: hit.matchInNote ? 11 : 6))
                                        .foregroundStyle(hit.matchInNote ? Color.secondary : Color.accentColor)
                                        .frame(width: 14)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(hit.title.isEmpty ? "(untitled)" : hit.title)
                                            .font(.callout)
                                            .lineLimit(2)
                                            .foregroundStyle(.primary)
                                            .multilineTextAlignment(.leading)
                                        if hit.matchInNote {
                                            Text("In note")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(isSelected(hit) ? Color.accentColor.opacity(0.14) : Color.clear)
                            )
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    private func isSelected(_ hit: MapSearchHit) -> Bool {
        session.store.selection.primary == hit.nodeID
    }

    private func refreshHits(query: String) {
        hits = MapSearch.search(map: session.store.map, query: query)
    }
}
