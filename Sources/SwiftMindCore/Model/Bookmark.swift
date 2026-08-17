import Foundation

public struct Bookmark: Equatable, Sendable, Codable, Hashable, Identifiable {
    public var id: String
    public var nodeID: NodeID
    public var label: String

    public init(id: String = UUID().uuidString, nodeID: NodeID, label: String) {
        self.id = id
        self.nodeID = nodeID
        self.label = label
    }
}
