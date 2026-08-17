import XCTest
@testable import SwiftMindCore

final class FormulaEngineTests: XCTestCase {

    private func makeStore() -> (MapStore, NodeID, NodeID, NodeID) {
        // root(formula: sum of costs) → [childA(formula: own cost, cost=10), childB(cost=20)]
        let childA = Node(
            id: NodeID(rawValue: "n_a"),
            text: "A",
            attributes: [NodeAttribute(name: "cost", value: "10")],
            formula: "attr(\"cost\") * 2"
        )
        let childB = Node(
            id: NodeID(rawValue: "n_b"),
            text: "B",
            attributes: [NodeAttribute(name: "cost", value: "20")]
        )
        var map = MindMap.makeEmpty(title: "T")
        map.root.formula = "sum(children, attr: \"cost\")"
        map.root.children = [childA, childB]
        return (MapStore(map: map), map.root.id, childA.id, childB.id)
    }

    func testResultsEvaluateAllFormulas() {
        let (store, root, childA, _) = makeStore()
        let results = store.formulaResults()
        XCTAssertEqual(results[root], .number(30))
        XCTAssertEqual(results[childA], .number(20))
    }

    func testNoFormulaReturnsNil() {
        let (store, _, _, childB) = makeStore()
        XCTAssertNil(store.formulaValue(for: childB))
    }

    func testBrokenFormulaSurfacesAsErrorValue() {
        var map = MindMap.makeEmpty(title: "T")
        map.root.formula = "attr(\"nope\")"
        let store = MapStore(map: map)
        XCTAssertEqual(store.formulaValue(for: map.root.id), .error("unknown attribute \"nope\""))
    }

    /// Core dependency property: a formula reads only its own subtree, so editing a
    /// sibling must NOT re-evaluate it, while the ancestor (whose subtree contains the
    /// edit) MUST re-evaluate. Cycles are structurally impossible: the dependency cone
    /// always points downward into the tree.
    func testSiblingEditDoesNotInvalidateSiblingFormula() throws {
        var engine = FormulaEngine()
        let (_, _, childA, childB) = makeStore()
        // Work directly on a mutable map copy so we can observe the engine.
        var map = MindMap.makeEmpty(title: "T")
        map.root.formula = "sum(children, attr: \"cost\")"
        map.root.children = [
            Node(id: childA, text: "A", attributes: [NodeAttribute(name: "cost", value: "10")], formula: "attr(\"cost\") * 2"),
            Node(id: childB, text: "B", attributes: [NodeAttribute(name: "cost", value: "20")]),
        ]
        let root = map.root.id

        _ = engine.results(in: map)
        XCTAssertEqual(engine.evaluationCount, 2)

        // Edit childB's text (a sibling of childA, inside root's subtree).
        map.updateNode(id: childB) { $0.text = "B renamed" }
        let results = engine.results(in: map)

        // root re-evaluated (its subtree changed), childA served from cache.
        XCTAssertEqual(engine.evaluationCount, 3)
        XCTAssertEqual(results[childA], .number(20))
        XCTAssertEqual(results[root], .number(30))
    }

    func testSubtreeEditInvalidatesOwnFormula() {
        var engine = FormulaEngine()
        var map = MindMap.makeEmpty(title: "T")
        let child = Node(
            id: NodeID(rawValue: "n_a"),
            text: "A",
            attributes: [NodeAttribute(name: "cost", value: "10")],
            formula: "attr(\"cost\")"
        )
        map.root.children = [child]

        XCTAssertEqual(engine.result(for: child.id, in: map), .number(10))
        XCTAssertEqual(engine.evaluationCount, 1)

        map.updateNode(id: child.id) { $0.attributes = [NodeAttribute(name: "cost", value: "42")] }
        XCTAssertEqual(engine.result(for: child.id, in: map), .number(42))
        XCTAssertEqual(engine.evaluationCount, 2)
    }

    func testMemoizationAvoidsRepeatEvaluation() {
        var engine = FormulaEngine()
        let map = MindMap.makeEmpty(title: "T")
        var root = map.root
        root.formula = "count(children)"
        let memoMap = MindMap(id: map.id, title: map.title, root: root)

        XCTAssertEqual(engine.result(for: root.id, in: memoMap), .number(0))
        XCTAssertEqual(engine.result(for: root.id, in: memoMap), .number(0))
        XCTAssertEqual(engine.evaluationCount, 1)
    }

    func testDeletedNodeEntryIsPruned() {
        var engine = FormulaEngine()
        var map = MindMap.makeEmpty(title: "T")
        let child = Node(id: NodeID(rawValue: "n_a"), text: "A", formula: "1 + 1")
        map.root.children = [child]

        XCTAssertEqual(engine.results(in: map).count, 1)
        map.root.children = []
        XCTAssertTrue(engine.results(in: map).isEmpty)
    }

    func testUndoRestoresCachedResultThroughStore() throws {
        let (store, root, _, childB) = makeStore()
        XCTAssertEqual(store.formulaValue(for: root), .number(30))

        try store.dispatch(
            SetAttributesCommand(nodeID: childB, attributes: [NodeAttribute(name: "cost", value: "99")])
        )
        XCTAssertEqual(store.formulaValue(for: root), .number(109))

        try store.undo()
        XCTAssertEqual(store.formulaValue(for: root), .number(30))
    }
}
