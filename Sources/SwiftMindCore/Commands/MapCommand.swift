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
