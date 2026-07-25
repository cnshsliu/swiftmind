import Foundation

public struct NodeID: Hashable, Sendable, Codable, Equatable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func generate() -> NodeID {
        let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return NodeID(rawValue: "n_" + String(uuid.prefix(16)))
    }
}
