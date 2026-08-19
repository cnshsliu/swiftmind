/// Applies a `BulkAction` to every node matching a filter rule, as ONE undoable step.
/// Prior state of every affected node is captured on first execute, so undo restores
/// the map exactly.
public final class ApplyBulkActionCommand: MapCommand {
    public let name = "ApplyBulkAction"
    public let rule: FilterRule
    public let action: BulkAction

    private struct PriorState {
        var attributes: [NodeAttribute]
        var icons: [NodeIcon]
        var styleName: String?
    }

    private var didCapture = false
    private var prior: [NodeID: PriorState] = [:]

    /// Number of nodes the action was applied to (valid after execute).
    public private(set) var affectedCount = 0

    public init(rule: FilterRule, action: BulkAction) {
        self.rule = rule
        self.action = action
    }

    public func execute(on map: inout MindMap) throws {
        if !didCapture {
            for id in Self.matchingIDs(in: map.root, rule: rule) {
                guard let node = map.node(id: id) else { continue }
                prior[id] = PriorState(attributes: node.attributes, icons: node.icons, styleName: node.styleName)
            }
            didCapture = true
            affectedCount = prior.count
        }
        for id in prior.keys {
            map.updateNode(id: id) { action.apply(to: &$0) }
        }
        if case .setAttribute(let name, _) = action {
            map.attributeRegistry.ensureRegistered(name)
        }
    }

    public func undo(on map: inout MindMap) throws {
        guard didCapture else { return }
        for (id, state) in prior {
            map.updateNode(id: id) { node in
                node.attributes = state.attributes
                node.icons = state.icons
                node.styleName = state.styleName
            }
        }
    }

    private static func matchingIDs(in node: Node, rule: FilterRule) -> [NodeID] {
        let own = FilterEvaluator.matches(node, rule: rule) ? [node.id] : []
        return own + node.children.flatMap { matchingIDs(in: $0, rule: rule) }
    }
}
