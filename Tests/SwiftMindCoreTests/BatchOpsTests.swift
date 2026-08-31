import XCTest
@testable import SwiftMindCore

final class BatchOpsTests: XCTestCase {
    private func makeMap() -> MindMap {
        var map = MindMap.makeEmpty(title: "T")
        map.root.children = [
            Node(id: NodeID(rawValue: "n_a"), text: "A"),
            Node(id: NodeID(rawValue: "n_b"), text: "B"),
        ]
        return map
    }

    func testApplySingleSetText() throws {
        var map = makeMap()
        let affected = try BatchOps.apply([.setText(nodeID: NodeID(rawValue: "n_a"), text: "A2")], to: &map)
        XCTAssertEqual(map.node(id: NodeID(rawValue: "n_a"))?.text, "A2")
        XCTAssertEqual(affected, [NodeID(rawValue: "n_a")])
    }

    func testAddChildReturnsNewID() throws {
        var map = makeMap()
        let newID = NodeID(rawValue: "n_new")
        let affected = try BatchOps.apply(
            [.addChild(parentID: NodeID(rawValue: "n_a"), newNodeID: newID, text: "Kid", side: .auto)],
            to: &map
        )
        XCTAssertEqual(map.node(id: NodeID(rawValue: "n_a"))?.children.map(\.id), [newID])
        XCTAssertEqual(affected, [newID])
    }

    func testSetAttributeUpsertAndEmptyValueRemoves() throws {
        var map = makeMap()
        let a = NodeID(rawValue: "n_a")
        try BatchOps.apply([.setAttribute(nodeID: a, name: "status", value: "done")], to: &map)
        XCTAssertEqual(map.node(id: a)?.attributes.first?.value, "done")
        try BatchOps.apply([.setAttribute(nodeID: a, name: "status", value: "wip")], to: &map)
        XCTAssertEqual(map.node(id: a)?.attributes.count, 1)
        XCTAssertEqual(map.node(id: a)?.attributes.first?.value, "wip")
        try BatchOps.apply([.setAttribute(nodeID: a, name: "status", value: "")], to: &map)
        XCTAssertEqual(map.node(id: a)?.attributes.count, 0)
    }

    func testSetFormulaEmptyClears() throws {
        var map = makeMap()
        let a = NodeID(rawValue: "n_a")
        try BatchOps.apply([.setFormula(nodeID: a, formula: "count(children)")], to: &map)
        XCTAssertEqual(map.node(id: a)?.formula, "count(children)")
        try BatchOps.apply([.setFormula(nodeID: a, formula: "")], to: &map)
        XCTAssertNil(map.node(id: a)?.formula)
    }

    func testAtomicityFailureLeavesMapUntouched() throws {
        var map = makeMap()
        let original = map
        let ops: [MapOp] = [
            .setText(nodeID: NodeID(rawValue: "n_a"), text: "CHANGED"),
            .setText(nodeID: NodeID(rawValue: "n_missing"), text: "boom"),
        ]
        XCTAssertThrowsError(try BatchOps.apply(ops, to: &map)) { error in
            guard let batchError = error as? BatchOpError else {
                return XCTFail("expected BatchOpError, got \(error)")
            }
            XCTAssertEqual(batchError.opIndex, 1)
            XCTAssertEqual(batchError.opName, "set-text")
        }
        XCTAssertEqual(map, original, "failed batch must leave the map byte-identical")
    }

    func testDeleteRootIsRejected() throws {
        var map = makeMap()
        XCTAssertThrowsError(
            try BatchOps.apply([.delete(nodeIDs: [map.root.id])], to: &map)
        )
    }

    func testMoveAndFoldAndPin() throws {
        var map = makeMap()
        let a = NodeID(rawValue: "n_a")
        let b = NodeID(rawValue: "n_b")
        try BatchOps.apply([
            .move(nodeID: a, newParentID: b, index: 0),
            .setFolded(nodeID: b, isFolded: true),
            .setPin(nodeID: b, position: Point2D(x: 10, y: -20)),
        ], to: &map)
        XCTAssertEqual(map.node(id: b)?.children.map(\.id), [a])
        XCTAssertEqual(map.node(id: b)?.isFolded, true)
        XCTAssertEqual(map.node(id: b)?.positionPin, Point2D(x: 10, y: -20))
        try BatchOps.apply([.setPin(nodeID: b, position: nil)], to: &map)
        XCTAssertNil(map.node(id: b)?.positionPin)
    }
}
