public protocol MapCommand {
    var name: String { get }
    func execute(on map: inout MindMap) throws
    func undo(on map: inout MindMap) throws
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
