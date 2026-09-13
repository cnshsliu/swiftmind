import XCTest
@testable import SwiftMindCore

final class MapGraphDoctorTests: XCTestCase {
    func testOrphanAndBacklink() throws {
        var map = MindMap.makeEmpty(title: "T")
        let bus = CommandBus()
        let a = NodeID(rawValue: "n_a")
        let b = NodeID(rawValue: "n_b")
        let c = NodeID(rawValue: "n_orphan")
        try bus.execute(InsertChildCommand(parentID: map.root.id, newNodeID: a, text: "A", side: .right), on: &map)
        try bus.execute(InsertChildCommand(parentID: map.root.id, newNodeID: b, text: "B", side: .left), on: &map)
        try bus.execute(InsertChildCommand(parentID: map.root.id, newNodeID: c, text: "Lonely", side: .right), on: &map)
        try bus.execute(SetLinksCommand(nodeID: a, links: [.node(b)]), on: &map)

        let graph = MapGraph.analyze(map)
        XCTAssertTrue(graph.orphans.contains(c))
        XCTAssertFalse(graph.orphans.contains(a))
        XCTAssertFalse(graph.orphans.contains(b))
        XCTAssertEqual(graph.backlinks(to: b), [a])
        XCTAssertTrue(FilterEvaluator.matches(map.node(id: c)!, rule: .orphan, graph: graph))
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
