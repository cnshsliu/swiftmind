import Foundation

/// Map-level conditional style rule: when a node matches `condition`, layer the
/// named style `styleName` over its named base style (before local overrides win).
public struct ConditionalStyleRule: Equatable, Sendable, Codable, Identifiable {
    public enum Condition: Equatable, Sendable, Codable {
        /// Node carries the given icon id (e.g. "check").
        case hasIcon(String)
        /// Node attribute equals a value (e.g. status=done).
        case attributeEquals(name: String, value: String)
    }

    public var id: String
    public var condition: Condition
    public var styleName: String

    public init(id: String = UUID().uuidString, condition: Condition, styleName: String) {
        self.id = id
        self.condition = condition
        self.styleName = styleName
    }

    public func matches(_ node: Node) -> Bool {
        switch condition {
        case .hasIcon(let iconID):
            return node.icons.contains { $0.id == iconID }
        case .attributeEquals(let name, let value):
            return node.attributeValue(named: name) == value
        }
    }
}
