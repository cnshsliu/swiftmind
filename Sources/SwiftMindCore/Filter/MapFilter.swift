import Foundation

/// How a filter affects the map presentation.
public enum FilterMode: String, Sendable, Codable, Equatable {
    /// Non-matching nodes omitted from layout (ancestors of matches kept).
    case hide
    /// All nodes laid out; matches flagged for highlight.
    case highlight
}

/// Simple composable filter rules (M3 — no scripts).
public enum FilterRule: Equatable, Sendable, Codable {
    case textContains(String)
    case hasIcon(String)
    case attributeEquals(name: String, value: String)
    case and([FilterRule])
    case or([FilterRule])
}

public struct MapFilter: Equatable, Sendable, Codable {
    public var mode: FilterMode
    public var rule: FilterRule

    public init(mode: FilterMode = .hide, rule: FilterRule) {
        self.mode = mode
        self.rule = rule
    }
}

public enum FilterEvaluator {
    public static func matches(_ node: Node, rule: FilterRule) -> Bool {
        switch rule {
        case .textContains(let q):
            let needle = q.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !needle.isEmpty else { return true }
            if node.text.range(of: needle, options: .caseInsensitive) != nil { return true }
            if node.noteMarkdown.range(of: needle, options: .caseInsensitive) != nil { return true }
            return false

        case .hasIcon(let iconID):
            return node.icons.contains { $0.id == iconID }

        case .attributeEquals(let name, let value):
            return node.attributes.contains { $0.name == name && $0.value == value }

        case .and(let rules):
            return rules.allSatisfy { matches(node, rule: $0) }

        case .or(let rules):
            return rules.contains { matches(node, rule: $0) }
        }
    }

    /// Node or any descendant matches (for hide-mode path-to-root visibility).
    public static func matchesIncludingDescendants(_ node: Node, rule: FilterRule) -> Bool {
        if matches(node, rule: rule) { return true }
        return node.children.contains { matchesIncludingDescendants($0, rule: rule) }
    }
}
