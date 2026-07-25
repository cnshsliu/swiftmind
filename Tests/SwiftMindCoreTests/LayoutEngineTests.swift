import XCTest
@testable import SwiftMindCore

final class LayoutEngineTests: XCTestCase {
    func testRootCenteredAndChildrenOffset() throws {
        var map = MindMap.makeEmpty(title: "T")
        let bus = CommandBus()
        try bus.execute(InsertChildCommand(parentID: map.root.id, text: "R", side: .right), on: &map)
        try bus.execute(InsertChildCommand(parentID: map.root.id, text: "L", side: .left), on: &map)

        let snapshot = LayoutEngine().layout(map: map)
        let rootV = snapshot.nodes.first { $0.id == map.root.id }!
        let r = map.root.children.first { $0.text == "R" }!
        let l = map.root.children.first { $0.text == "L" }!
        let rv = snapshot.nodes.first { $0.id == r.id }!
        let lv = snapshot.nodes.first { $0.id == l.id }!
        XCTAssertGreaterThan(rv.frame.midX, rootV.frame.midX)
        XCTAssertLessThan(lv.frame.midX, rootV.frame.midX)
        XCTAssertEqual(snapshot.edges.count, 2)
    }

    func testFoldedHidesDescendants() throws {
        var map = MindMap.makeEmpty(title: "T")
        let bus = CommandBus()
        let a = NodeID(rawValue: "n_a")
        try bus.execute(InsertChildCommand(parentID: map.root.id, newNodeID: a, text: "A", side: .right), on: &map)
        try bus.execute(InsertChildCommand(parentID: a, text: "Hidden", side: .right), on: &map)
        try bus.execute(SetFoldedCommand(nodeID: a, isFolded: true), on: &map)
        let snapshot = LayoutEngine().layout(map: map)
        XCTAssertNil(snapshot.nodes.first { $0.text == "Hidden" })
        XCTAssertNotNil(snapshot.nodes.first { $0.id == a })
    }

    func testSelectionFlag() {
        let map = MindMap.makeEmpty(title: "T")
        var sel = SelectionState()
        sel.select(map.root.id)
        let snapshot = LayoutEngine().layout(map: map, selection: sel)
        XCTAssertTrue(snapshot.nodes.first { $0.id == map.root.id }!.isSelected)
    }
}
