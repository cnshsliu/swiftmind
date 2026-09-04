import Foundation

/// Clipboard codecs between node subtrees and indented markdown bullets:
///
/// ```
/// - Parent
/// - Second
///   - Child
///     note line (plain indented text becomes the nearest node's note)
/// ```
///
/// Export uses two spaces per level; parse tolerates 2–4 spaces or one tab
/// per level. Plain (non-bullet) non-empty lines are collected as the note
/// body of the nearest preceding node. Round-trip preserves titles, nesting
/// and notes — ids, styles, icons and other metadata are not preserved
/// (bullets are a lossy interchange format).
public enum MarkdownOutline {
    // MARK: - Export

    public static func export(_ nodes: [Node]) -> String {
        var lines: [String] = []
        for node in nodes {
            exportNode(node, level: 0, into: &lines)
        }
        return lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
    }

    private static func exportNode(_ node: Node, level: Int, into lines: inout [String]) {
        let indent = String(repeating: "  ", count: level)
        lines.append(indent + "- " + node.text)
        let note = node.noteMarkdown.trimmingCharacters(in: .newlines)
        if !note.isEmpty {
            for noteLine in note.components(separatedBy: "\n") {
                lines.append(indent + "  " + noteLine)
            }
        }
        for child in node.children {
            exportNode(child, level: level + 1, into: &lines)
        }
    }

    // MARK: - Parse

    /// Returns nil when no line looks like a bullet (pure prose is not an
    /// outline). Prose lines before the first bullet are ignored. The first
    /// bullet's indent defines the root level.
    public static func parse(_ text: String) -> [Node]? {
        // Nodes are boxed so later mutations (children, notes) through the
        // indent stack are visible everywhere — value semantics would
        // otherwise freeze each parent at its creation-time copy.
        final class Box {
            var node: Node
            var children: [Box] = []
            init(_ n: Node) { node = n }
        }

        func materialize(_ box: Box) -> Node {
            box.node.children = box.children.map(materialize)
            return box.node
        }

        var rootLevel: Int?
        var stack: [(level: Int, box: Box)] = [] // innermost last
        var roots: [Box] = []
        var sawBullet = false

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let title = bulletTitle(in: line) {
                sawBullet = true
                let (spaces, tabs) = leadingWidth(of: rawLine)
                let level = tabs + spaces / 2
                if rootLevel == nil { rootLevel = level }
                let rel = level - rootLevel!
                while let top = stack.last, top.level >= rel {
                    stack.removeLast()
                }
                let box = Box(Node(text: title))
                if let parent = stack.last {
                    parent.box.children.append(box)
                } else {
                    roots.append(box)
                }
                stack.append((rel, box))
            } else if !line.isEmpty, sawBullet, let top = stack.last {
                top.box.node.noteMarkdown +=
                    top.box.node.noteMarkdown.isEmpty ? line : "\n" + line
            }
        }
        guard sawBullet else { return nil }
        return roots.map(materialize)
    }

    /// `- Title`, `* Title` or `+ Title` (leading whitespace already trimmed).
    private static func bulletTitle(in line: String) -> String? {
        guard line.count >= 2 else { return nil }
        let marker = line.first!
        guard marker == "-" || marker == "*" || marker == "+" else { return nil }
        let after = line.dropFirst()
        guard after.first == " " || after.first == "\t" else { return nil }
        let title = after.drop(while: { $0 == " " || $0 == "\t" })
        guard !title.isEmpty else { return nil }
        return String(title)
    }

    private static func leadingWidth(of line: String) -> (spaces: Int, tabs: Int) {
        var spaces = 0
        var tabs = 0
        for c in line {
            if c == " " { spaces += 1 } else if c == "\t" { tabs += 1 } else { break }
        }
        return (spaces, tabs)
    }
}
