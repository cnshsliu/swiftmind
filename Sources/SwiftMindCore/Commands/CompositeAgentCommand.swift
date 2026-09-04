/// Applies a batch of agent-authored ops as ONE undoable step.
/// Execute-time rollback: if any op fails, already-executed ops are undone
/// in reverse and the map is left untouched (same guarantee as BatchOps).
public final class CompositeAgentCommand: MapCommand {
    public let name = "AgentEdit"
    public let ops: [MapOp]

    /// Ids touched by the last successful execute, in op order.
    public private(set) var affected: [NodeID] = []

    private var executed: [any MapCommand] = []

    public init(ops: [MapOp]) {
        self.ops = ops
    }

    public func execute(on map: inout MindMap) throws {
        executed = []
        affected = []
        for (index, op) in ops.enumerated() {
            let command = try op.command(in: map)
            do {
                try command.execute(on: &map)
            } catch {
                for past in executed.reversed() {
                    try? past.undo(on: &map)
                }
                executed = []
                throw BatchOpError(
                    opIndex: index,
                    opName: op.name,
                    message: String(describing: error)
                )
            }
            executed.append(command)
            affected.append(contentsOf: op.affectedIDs)
        }
    }

    public func undo(on map: inout MindMap) throws {
        for command in executed.reversed() {
            try command.undo(on: &map)
        }
    }
}
