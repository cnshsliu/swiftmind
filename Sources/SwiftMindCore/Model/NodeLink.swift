import Foundation

public enum NodeLink: Equatable, Sendable, Codable, Hashable {
    case url(URL)
    case node(NodeID)

    public var kindLabel: String {
        switch self {
        case .url: return "url"
        case .node: return "node"
        }
    }
}
