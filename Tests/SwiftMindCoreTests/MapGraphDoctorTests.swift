import XCTest
@testable import SwiftMindCore

final class MapGraphDoctorTests: XCTestCase {
    func testLinkedNodesAndLonelyLeafAreNotOrphans() throws {
        var map = MindMap.makeEmpty(title: "T")
        let bus = CommandBus()
        let a = NodeID(rawValue: "n_a")
        let b = NodeID(rawValue: "n_b")
        let c = NodeID(rawValue: "n_lonely_leaf")
        try bus.execute(InsertChildCommand(parentID: map.root.id, newNodeID: a, text: "A", side: .right), on: &map)
        try bus.execute(InsertChildCommand(parentID: map.root.id, newNodeID: b, text: "B", side: .left), on: &map)
        try bus.execute(InsertChildCommand(parentID: map.root.id, newNodeID: c, text: "Lonely", side: .right), on: &map)
        try bus.execute(SetLinksCommand(nodeID: a, links: [.node(b)]), on: &map)

        // Orphan = unreachable from the root, NOT "leaf without links".
        // Every node lives under the single root tree, so a well-formed
        // map has no orphans — a lonely leaf is simply a leaf.
        let graph = MapGraph.analyze(map)
        XCTAssertTrue(graph.orphans.isEmpty)
        XCTAssertFalse(FilterEvaluator.matches(map.node(id: c)!, rule: .orphan, graph: graph))
        XCTAssertEqual(graph.backlinks(to: b), [a])

        let issues = MapDoctor.inspect(map)
        XCTAssertFalse(issues.contains { $0.kind == .orphan })
    }

    func testDanglingLinkAndDoctor() throws {
        var map = MindMap.makeEmpty(title: "T")
        let bus = CommandBus()
        let a = NodeID(rawValue: "n_src")
        try bus.execute(InsertChildCommand(parentID: map.root.id, newNodeID: a, text: "Src", side: .right), on: &map)
        try bus.execute(SetLinksCommand(nodeID: a, links: [.node(NodeID(rawValue: "n_missing"))]), on: &map)
        map.bookmarks = [Bookmark(nodeID: NodeID(rawValue: "n_gone"), label: "Gone")]

        let issues = MapDoctor.inspect(map)
        XCTAssertTrue(issues.contains { $0.kind == .danglingNodeLink && $0.nodeID == a })
        XCTAssertTrue(issues.contains { $0.kind == .staleBookmark })
        let graph = MapGraph.analyze(map)
        XCTAssertTrue(graph.danglingSources.contains(a))
    }

    func testEmptyTitleAndFormulaError() throws {
        var map = MindMap.makeEmpty(title: "T")
        let bus = CommandBus()
        let a = NodeID(rawValue: "n_blank")
        try bus.execute(InsertChildCommand(parentID: map.root.id, newNodeID: a, text: "x", side: .right), on: &map)
        try bus.execute(SetTextCommand(nodeID: a, newText: "   "), on: &map)
        try bus.execute(SetFormulaCommand(nodeID: a, formula: "not a formula (("), on: &map)
        let issues = MapDoctor.inspect(map)
        XCTAssertTrue(issues.contains { $0.kind == .emptyTitle && $0.nodeID == a })
        XCTAssertTrue(issues.contains { $0.kind == .formulaError && $0.nodeID == a })
    }
}
