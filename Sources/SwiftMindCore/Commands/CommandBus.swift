/// Undo/redo stacks for `MapCommand`s, with opt-in coalescing: a command
/// carrying a `coalescingKey` equal to the open group at the top of the undo
/// stack merges into that group instead of pushing a new step. The group
/// keeps the FIRST command for undo (restores the pre-session state) and the
/// LATEST command for redo/execute (the note commits carry absolute values,
/// so the newest burst fully describes the final state). `endCoalescing`
/// closes the group — the next same-key command starts a fresh step — and
/// any unkeyed command in between also breaks the chain naturally.
public final class CommandBus: @unchecked Sendable {
    private var undoStack: [any MapCommand] = []
    private var redoStack: [any MapCommand] = []

    public init() {}

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public func execute(_ command: any MapCommand, on map: inout MindMap) throws {
        try command.execute(on: &map)
        if let key = command.coalescingKey,
           let group = undoStack.last as? CoalescingCommandGroup,
           group.key == key, group.isOpen {
            group.redoCommand = command
        } else if let key = command.coalescingKey {
            undoStack.append(CoalescingCommandGroup(key: key, command: command))
        } else {
            undoStack.append(command)
        }
        redoStack.removeAll()
    }

    /// Close the coalescing group with this key (top of the undo stack), so
    /// the next same-key command starts a new undo step. No-op otherwise.
    public func endCoalescing(key: String) {
        guard let group = undoStack.last as? CoalescingCommandGroup, group.key == key else { return }
        group.isOpen = false
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

/// One undo step spanning several coalesced executions. Undoes via the FIRST
/// command of the group; (re)executes via the LATEST. Created and managed by
/// `CommandBus` only — never dispatched directly.
final class CoalescingCommandGroup: MapCommand {
    let key: String
    var isOpen = true
    private let undoCommand: any MapCommand
    var redoCommand: any MapCommand

    init(key: String, command: any MapCommand) {
        self.key = key
        self.undoCommand = command
        self.redoCommand = command
    }

    var name: String { undoCommand.name }
    var coalescingKey: String? { key }

    func execute(on map: inout MindMap) throws {
        try redoCommand.execute(on: &map)
    }

    func undo(on map: inout MindMap) throws {
        try undoCommand.undo(on: &map)
    }
}
