public final class SetMapTitleCommand: MapCommand {
    public let name = "SetMapTitle"
    public let newTitle: String
    private var old: String?

    public init(newTitle: String) {
        self.newTitle = newTitle
    }

    public func execute(on map: inout MindMap) throws {
        if old == nil { old = map.title }
        map.title = newTitle
    }

    public func undo(on map: inout MindMap) throws {
        if let old { map.title = old }
    }
}
