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

    func testLeftAndRightPackIndependentlyWithoutStealingVerticalSlots() throws {
        var map = MindMap.makeEmpty(title: "T")
        let bus = CommandBus()
        // Three right + three left — each side should stack tightly, not share one cursor.
        for i in 0..<3 {
            try bus.execute(
                InsertChildCommand(parentID: map.root.id, text: "R\(i)", side: .right),
                on: &map
            )
        }
        for i in 0..<3 {
            try bus.execute(
                InsertChildCommand(parentID: map.root.id, text: "L\(i)", side: .left),
                on: &map
            )
        }

        let snap = LayoutEngine().layout(map: map)
        let rights = snap.nodes.filter { $0.text.hasPrefix("R") }.sorted { $0.frame.midY < $1.frame.midY }
        let lefts = snap.nodes.filter { $0.text.hasPrefix("L") }.sorted { $0.frame.midY < $1.frame.midY }
        XCTAssertEqual(rights.count, 3)
        XCTAssertEqual(lefts.count, 3)

        // Same-side siblings: monotonic Y and no overlap.
        for i in 0..<(rights.count - 1) {
            XCTAssertLessThan(rights[i].frame.y + rights[i].frame.height, rights[i + 1].frame.y + 0.5)
        }
        for i in 0..<(lefts.count - 1) {
            XCTAssertLessThan(lefts[i].frame.y + lefts[i].frame.height, lefts[i + 1].frame.y + 0.5)
        }

        // Both columns roughly centered on root midY (independent packing).
        let rootMid = snap.nodes.first { $0.id == map.root.id }!.frame.midY
        let rightSpanMid = (rights.first!.frame.midY + rights.last!.frame.midY) / 2
        let leftSpanMid = (lefts.first!.frame.midY + lefts.last!.frame.midY) / 2
        XCTAssertEqual(rightSpanMid, rootMid, accuracy: 8)
        XCTAssertEqual(leftSpanMid, rootMid, accuracy: 8)
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

    func testSelectionOverlayDoesNotMoveFrames() {
        var map = MindMap.makeEmpty(title: "T")
        let bus = CommandBus()
        try! bus.execute(InsertChildCommand(parentID: map.root.id, text: "A", side: .right), on: &map)
        let base = LayoutEngine().layout(map: map)
        var sel = SelectionState()
        sel.select(map.root.children[0].id)
        let overlaid = base.applying(selection: sel)
        XCTAssertEqual(base.nodes.map(\.frame), overlaid.nodes.map(\.frame))
        XCTAssertTrue(overlaid.nodes.first { $0.text == "A" }!.isSelected)
    }
}
