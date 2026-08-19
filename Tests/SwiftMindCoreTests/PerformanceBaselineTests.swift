import XCTest
@testable import SwiftMindCore

/// Performance baseline (M3 Task 11): decides whether viewport culling is needed.
/// Assertion bound is deliberately generous — this documents the baseline, it is
/// not a tight regression gate. Check the printed timings when maps feel slow.
final class PerformanceBaselineTests: XCTestCase {

    /// Wide+deep map: 40 children × 50 grandchildren = 2041 nodes.
    private func makeLargeMap() -> MindMap {
        var map = MindMap.makeEmpty(title: "Perf")
        map.root.children = (0..<40).map { i in
            Node(
                id: NodeID(rawValue: "n_\(i)"),
                text: "Branch \(i)",
                children: (0..<50).map { j in
                    Node(id: NodeID(rawValue: "n_\(i)_\(j)"), text: "Leaf \(i).\(j)")
                }
            )
        }
        return map
    }

    func testLayoutTwoThousandNodesBaseline() {
        let map = makeLargeMap()
        let engine = LayoutEngine()

        let start = Date()
        let snapshot = engine.layout(map: map, selection: SelectionState())
        let elapsed = Date().timeIntervalSince(start)

        print("BASELINE layout \(snapshot.nodes.count) nodes: \(String(format: "%.3f", elapsed))s")
        XCTAssertEqual(snapshot.nodes.count, 2041)
        XCTAssertLessThan(elapsed, 2.0, "Layout regression: 2k nodes should layout well under 2s")
    }

    func testFormulaEvaluationBaseline() {
        var map = makeLargeMap()
        map.root.formula = "count(children)"
        map.root.children[0].formula = "progress()"

        var engine = FormulaEngine()
        let start = Date()
        let results = engine.results(in: map)
        let elapsed = Date().timeIntervalSince(start)

        print("BASELINE formulas on 2041-node map: \(String(format: "%.3f", elapsed))s")
        XCTAssertEqual(results.count, 2)
        XCTAssertLessThan(elapsed, 1.0)
    }
}
