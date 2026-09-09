import SwiftUI
import SwiftMindCore

/// Sidebar list of map bookmarks → select + jump.
struct BookmarksSidebar: View {
    @ObservedObject var session: DocumentSession

    private var bookmarks: [Bookmark] {
        session.store.map.bookmarks
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("BOOKMARKS")
                    .font(Theme.sidebarCaption)
                    .foregroundStyle(.secondary)
                    .tracking(0.6)
                Spacer()
                Button {
                    bookmarkSelection()
                } label: {
                    Image(systemName: "bookmark")
                }
                .buttonStyle(.plain)
                .help("Bookmark selection")
                .disabled(session.store.selection.primary == nil)
                .accessibilityIdentifier("addBookmarkButton")
            }

            if bookmarks.isEmpty {
                Text("No bookmarks")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(bookmarks) { bookmark in
                    HStack(spacing: 6) {
                        Button {
                            jump(to: bookmark)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "bookmark.fill")
                                    .font(.caption)
                                    .foregroundStyle(Color.accentColor)
                                Text(displayLabel(for: bookmark))
                                    .lineLimit(1)
                                    .font(.callout)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("bookmark-\(bookmark.id)")
                        .contextMenu {
                            Button("Jump") { jump(to: bookmark) }
                            Button("Remove Bookmark", role: .destructive) {
                                session.apply(RemoveBookmarkCommand(bookmarkID: bookmark.id))
                            }
                        }

                        Button(role: .destructive) {
                            session.apply(RemoveBookmarkCommand(bookmarkID: bookmark.id))
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove bookmark")
                    }
                }
            }
        }
    }

    private func displayLabel(for bookmark: Bookmark) -> String {
        let trimmed = bookmark.label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let node = session.store.map.node(id: bookmark.nodeID) {
            let t = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? "(untitled)" : t
        }
        return "(missing)"
    }

    private func jump(to bookmark: Bookmark) {
        guard session.store.map.node(id: bookmark.nodeID) != nil else {
            session.showToast("Bookmark target missing", kind: .error)
            return
        }
        session.select(bookmark.nodeID)
        // Unfold ancestors so the node is on-canvas.
        unfoldPathTo(bookmark.nodeID)
    }

    private func unfoldPathTo(_ id: NodeID) {
        var current = id
        while let parent = session.store.map.parentID(of: current) {
            if let p = session.store.map.node(id: parent), p.isFolded {
                session.applyQuiet(SetFoldedCommand(nodeID: parent, isFolded: false))
            }
            current = parent
        }
    }

    private func bookmarkSelection() {
        guard let id = session.store.selection.primary,
              let node = session.store.map.node(id: id) else { return }
        let label = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let bookmark = Bookmark(
            nodeID: id,
            label: label.isEmpty ? "Bookmark" : label
        )
        session.apply(AddBookmarkCommand(bookmark: bookmark))
    }
}
