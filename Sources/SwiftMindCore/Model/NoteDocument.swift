import Foundation

/// Virtual-H1 view of a node's note: the document shown in the floating
/// editor is `# <title>` + blank line + body (`noteMarkdown`). Storage keeps
/// title and body in separate fields; this is the split/join layer.
/// Spec: docs/superpowers/specs/2026-09-04-note-markdown-doc-design.md
public enum NoteDocument {
    /// Document text for the editor — the first line is always `# <title>`.
    public static func compose(title: String, body: String) -> String {
        let head = "# \(title)"
        let trimmed = body.trimmingCharacters(in: .newlines)
        return trimmed.isEmpty ? head + "\n" : head + "\n\n" + trimmed + "\n"
    }

    /// Inverse of `compose`. `title` is nil when the first line is not a
    /// well-formed H1 (`# ` + non-empty text) — callers keep the existing
    /// node title in that case, so deleting the H1 never erases a title.
    public static func split(_ document: String) -> (title: String?, body: String) {
        guard !document.isEmpty else { return (nil, "") }
        var lines = document.components(separatedBy: "\n")
        let first = lines[0]
        guard first == "#" || first.hasPrefix("# ") else {
            return (nil, document)
        }
        let rawTitle = first == "#" ? "" : String(first.dropFirst(2))
        let title = rawTitle.trimmingCharacters(in: .whitespaces)
        lines.removeFirst()
        // Drop the blank separator line(s) between the H1 and the body.
        while let head = lines.first, head.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        var body = lines.joined(separator: "\n")
        while body.hasSuffix("\n") { body.removeLast() }
        return (title.isEmpty ? nil : title, body)
    }
}
