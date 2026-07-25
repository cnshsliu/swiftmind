public struct SelectionState: Equatable, Sendable {
    public var selectedIDs: Set<NodeID>
    public var primary: NodeID?

    public init(selectedIDs: Set<NodeID> = [], primary: NodeID? = nil) {
        self.selectedIDs = selectedIDs
        self.primary = primary
    }

    public mutating func select(_ id: NodeID, additive: Bool = false) {
        if additive {
            selectedIDs.insert(id)
            primary = id
        } else {
            selectedIDs = [id]
            primary = id
        }
    }

    public mutating func clear() {
        selectedIDs = []
        primary = nil
    }
}
