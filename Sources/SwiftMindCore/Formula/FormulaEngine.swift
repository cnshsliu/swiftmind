import Foundation

/// Memoizing formula evaluator for a map.
///
/// Every DSL feature (`attr`, aggregates over `children`, `progress()`) reads only
/// the node's **own subtree**, so a formula result is a pure function of that subtree.
/// The cache therefore stores the subtree alongside the result and validates by
/// equality: editing a sibling never invalidates this node's entry, editing anything
/// in the subtree (or an ancestor's) does — exactly the dependency cone of the DSL.
/// No revision keys, no changed-node tracking, and undo restores cache hits for free.
///
/// Caveat: future cross-node references (e.g. `node("id")`) would break this
/// invariant and require a different invalidation strategy.
public struct FormulaEngine: Equatable, Sendable {

    private struct Entry: Equatable, Sendable {
        var subtree: Node
        var result: FormulaValue
    }

    private var cache: [NodeID: Entry] = [:]

    /// Total evaluations performed (cache misses). Exposed for tests / perf checks.
    public private(set) var evaluationCount = 0

    public init() {}

    /// Evaluates the node's formula (memoized). Returns nil when the node has no formula.
    public mutating func result(for nodeID: NodeID, in map: MindMap) -> FormulaValue? {
        guard let node = map.node(id: nodeID) else {
            cache[nodeID] = nil
            return nil
        }
        guard let formula = node.formula, !formula.isEmpty else {
            cache[nodeID] = nil
            return nil
        }
        if let cached = cache[nodeID], cached.subtree == node {
            return cached.result
        }
        let value = FormulaEvaluator.evaluate(source: formula, on: node)
        cache[nodeID] = Entry(subtree: node, result: value)
        evaluationCount += 1
        return value
    }

    /// Results for every node with a formula, memoized. Drops entries for deleted nodes.
    public mutating func results(in map: MindMap) -> [NodeID: FormulaValue] {
        let formulaNodes = Self.collectFormulaNodes(from: map.root)
        let live = Set(formulaNodes.map(\.id))
        cache = cache.filter { live.contains($0.key) }

        var out: [NodeID: FormulaValue] = [:]
        for node in formulaNodes {
            if let value = result(for: node.id, in: map) {
                out[node.id] = value
            }
        }
        return out
    }

    public mutating func invalidateAll() {
        cache.removeAll()
    }

    private static func collectFormulaNodes(from node: Node) -> [Node] {
        let own = (node.formula?.isEmpty == false) ? [node] : []
        return own + node.children.flatMap { collectFormulaNodes(from: $0) }
    }
}
