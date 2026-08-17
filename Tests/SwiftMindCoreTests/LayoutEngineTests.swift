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

    /// ⌘T inserts with `.auto` — layout must balance left/right, not stack all on the right.
    func testAutoSideBalancesAcrossRoot() throws {
        var map = MindMap.makeEmpty(title: "T")
        let bus = CommandBus()
        for i in 0..<4 {
            try bus.execute(
                InsertChildCommand(parentID: map.root.id, text: "C\(i)", side: .auto),
                on: &map
            )
        }

        let snap = LayoutEngine().layout(map: map)
        let rootMidX = snap.nodes.first { $0.id == map.root.id }!.frame.midX
        let children = snap.nodes.filter { $0.depth == 1 }
        XCTAssertEqual(children.count, 4)

        let rights = children.filter { $0.frame.midX > rootMidX }
        let lefts = children.filter { $0.frame.midX < rootMidX }
        // Four equal leaves → 2 left + 2 right (first prefers right on tie).
        XCTAssertEqual(rights.count, 2, "auto children should not all pile on the right")
        XCTAssertEqual(lefts.count, 2, "auto children should not all pile on the left")
    }

    /// Mode 1: deeper nodes inherit the first-level side and only grow outward.
    /// Grandchildren must not flip to the opposite side of their parent.
    func testBranchInheritsSideAndGrowsOutwardOnly() throws {
        var map = MindMap.makeEmpty(title: "T")
        let bus = CommandBus()
        let problem = NodeID(rawValue: "problem")
        try bus.execute(
            InsertChildCommand(parentID: map.root.id, newNodeID: problem, text: "Problem A", side: .left),
            on: &map
        )
        // Three kids under Problem A — even if stored as .auto / mixed, layout must stay left.
        for i in 0..<3 {
            try bus.execute(
                InsertChildCommand(parentID: problem, text: "Kid\(i)", side: .auto),
                on: &map
            )
        }
        // Sibling on the right branch of root.
        try bus.execute(
            InsertChildCommand(parentID: map.root.id, text: "RightSib", side: .right),
            on: &map
        )

        let snap = LayoutEngine().layout(map: map)
        let root = snap.nodes.first { $0.id == map.root.id }!
        let problemV = snap.nodes.first { $0.id == problem }!
        let kids = snap.nodes.filter { $0.text.hasPrefix("Kid") }
        let rightSib = snap.nodes.first { $0.text == "RightSib" }!

        XCTAssertEqual(kids.count, 3)
        XCTAssertLessThan(problemV.frame.midX, root.frame.midX, "Problem A on left of root")
        XCTAssertGreaterThan(rightSib.frame.midX, root.frame.midX)

        for kid in kids {
            XCTAssertEqual(kid.side, .left)
            // Outward: further left than Problem A (not between Problem A and root).
            XCTAssertLessThan(
                kid.frame.x + kid.frame.width,
                problemV.frame.x + 0.5,
                "\(kid.text) must sit fully left of Problem A (outward)"
            )
            XCTAssertLessThan(kid.frame.midX, problemV.frame.midX)
        }

        // Kids stack vertically without overlapping each other.
        let sorted = kids.sorted { $0.frame.midY < $1.frame.midY }
        for i in 0..<(sorted.count - 1) {
            XCTAssertLessThan(
                sorted[i].frame.y + sorted[i].frame.height,
                sorted[i + 1].frame.y + 0.5
            )
        }
    }

    /// Sibling branches must clear each other's expanded subtree height (no vertical steal).
    func testSiblingClearsExpandedSubtreeHeight() throws {
        var map = MindMap.makeEmpty(title: "T")
        let bus = CommandBus()
        let a = NodeID(rawValue: "a")
        let b = NodeID(rawValue: "b")
        try bus.execute(
            InsertChildCommand(parentID: map.root.id, newNodeID: a, text: "A", side: .right),
            on: &map
        )
        try bus.execute(
            InsertChildCommand(parentID: map.root.id, newNodeID: b, text: "B", side: .right),
            on: &map
        )
        // A has three children → tall subtree; B is a leaf sibling on the same side.
        for i in 0..<3 {
            try bus.execute(
                InsertChildCommand(parentID: a, text: "AKid\(i)", side: .auto),
                on: &map
            )
        }

        let snap = LayoutEngine().layout(map: map)
        let aV = snap.nodes.first { $0.id == a }!
        let bV = snap.nodes.first { $0.id == b }!
        let aKids = snap.nodes.filter { $0.text.hasPrefix("AKid") }
        XCTAssertEqual(aKids.count, 3)

        // Bounding Y of A's subtree vs B's frame — no overlap.
        let aTop = min(aV.frame.y, aKids.map(\.frame.y).min()!)
        let aBottom = max(
            aV.frame.y + aV.frame.height,
            aKids.map { $0.frame.y + $0.frame.height }.max()!
        )
        let bTop = bV.frame.y
        let bBottom = bV.frame.y + bV.frame.height

        let separated = aBottom <= bTop + 0.5 || bBottom <= aTop + 0.5
        XCTAssertTrue(separated, "Sibling B must clear A's expanded subtree vertically")
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
