import Foundation

/// Per-node attribute value (string storage; type is advisory via registry).
public struct NodeAttribute: Equatable, Sendable, Codable, Hashable, Identifiable {
    public var name: String
    public var value: String

    public var id: String { name }

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public enum AttributeValueType: String, Sendable, Codable, Equatable {
    case string
    case number
    case bool
}

/// Map-level attribute definition (registry entry).
public struct AttributeDefinition: Equatable, Sendable, Codable, Hashable, Identifiable {
    public var name: String
    public var valueType: AttributeValueType

    public var id: String { name }

    public init(name: String, valueType: AttributeValueType = .string) {
        self.name = name
        self.valueType = valueType
    }
}

public struct AttributeRegistry: Equatable, Sendable, Codable {
    public var definitions: [AttributeDefinition]

    public init(definitions: [AttributeDefinition] = []) {
        self.definitions = definitions
    }

    public func contains(_ name: String) -> Bool {
        definitions.contains { $0.name == name }
    }

    public mutating func ensureRegistered(_ name: String, type: AttributeValueType = .string) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !contains(trimmed) else { return }
        definitions.append(AttributeDefinition(name: trimmed, valueType: type))
        definitions.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
