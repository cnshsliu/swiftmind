public final class CommandBus: @unchecked Sendable {
    private var undoStack: [any MapCommand] = []
    private var redoStack: [any MapCommand] = []

    public init() {}

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public func execute(_ command: any MapCommand, on map: inout MindMap) throws {
        try command.execute(on: &map)
        undoStack.append(command)
        redoStack.removeAll()
    }

    public func undo(on map: inout MindMap) throws {
        guard let command = undoStack.popLast() else { return }
        try command.undo(on: &map)
        redoStack.append(command)
    }

    public func redo(on map: inout MindMap) throws {
        guard let command = redoStack.popLast() else { return }
        try command.execute(on: &map)
        undoStack.append(command)
    }

    public func clearHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
    }
}
