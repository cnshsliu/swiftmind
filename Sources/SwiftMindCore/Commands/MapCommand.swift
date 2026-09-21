public protocol MapCommand {
    var name: String { get }
    /// When non-nil, consecutive executions carrying the same key coalesce
    /// into ONE undo step on the bus (the note editor's debounced commits use
    /// this to make a whole editing session a single ⌘Z). Default: nil —
    /// never coalesces.
    var coalescingKey: String? { get }
    func execute(on map: inout MindMap) throws
    func undo(on map: inout MindMap) throws
}

extension MapCommand {
    public var coalescingKey: String? { nil }
}

public enum MapCommandError: Error, Equatable {
    case nodeNotFound(NodeID)
    case cannotDeleteRoot
    case invalidParent
}

extension MapCommandError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .nodeNotFound(let id): return "node not found: \(id.rawValue)"
        case .cannotDeleteRoot: return "cannot delete the root node"
        case .invalidParent: return "invalid parent (missing node or it would create a cycle)"
        }
    }
}
