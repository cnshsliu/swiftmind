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

    func testAddSibling() throws {
        var map = makeMap()
        let newID = NodeID(rawValue: "n_sib")
        try BatchOps.apply(
            [.addSibling(siblingID: NodeID(rawValue: "n_a"), newNodeID: newID, text: "Sib")],
            to: &map
        )
        XCTAssertEqual(
            map.root.children.map(\.id),
            [NodeID(rawValue: "n_a"), newID, NodeID(rawValue: "n_b")]
        )
    }

    func testSetNote() throws {
        var map = makeMap()
        let a = NodeID(rawValue: "n_a")
        try BatchOps.apply([.setNote(nodeID: a, markdown: "# Hello")], to: &map)
        XCTAssertEqual(map.node(id: a)?.noteMarkdown, "# Hello")
    }

    func testDeleteNonRoot() throws {
        var map = makeMap()
        try BatchOps.apply([.delete(nodeIDs: [NodeID(rawValue: "n_a")])], to: &map)
        XCTAssertNil(map.node(id: NodeID(rawValue: "n_a")))
        XCTAssertNotNil(map.node(id: NodeID(rawValue: "n_b")))
    }

    func testEmptyBatchIsNoOp() throws {
        var map = makeMap()
        let original = map
        let affected = try BatchOps.apply([], to: &map)
        XCTAssertEqual(affected, [])
        XCTAssertEqual(map, original)
    }

    private func decodeOps(_ json: String) throws -> [MapOp] {
        let data = Data(json.utf8)
        return try JSONDecoder().decode([MapOp].self, from: data)
    }

    func testDecodeAllOpKinds() throws {
        let ops = try decodeOps("""
        [
          {"op":"add-child","parent":"n_x","id":"n_new","text":"Kid","side":"left"},
          {"op":"add-sibling","sibling":"n_x","text":"Sib"},
          {"op":"set-text","id":"n_x","text":"T"},
          {"op":"set-note","id":"n_x","markdown":"M"},
          {"op":"set-attr","id":"n_x","name":"status","value":"done"},
          {"op":"set-formula","id":"n_x","formula":"count(children)"},
          {"op":"fold","id":"n_x"},
          {"op":"unfold","id":"n_x"},
          {"op":"pin","id":"n_x","x":12.5,"y":-3},
          {"op":"unpin","id":"n_x"},
          {"op":"move","id":"n_x","to":"n_y","index":2},
          {"op":"delete","ids":["n_x","n_y"]}
        ]
        """)
        XCTAssertEqual(ops.count, 12)
        XCTAssertEqual(ops[0], .addChild(
            parentID: NodeID(rawValue: "n_x"),
            newNodeID: NodeID(rawValue: "n_new"),
            text: "Kid",
            side: .left
        ))
        // add-sibling without id generates one
        if case let .addSibling(_, generated, _) = ops[1] {
            XCTAssertFalse(generated.rawValue.isEmpty)
        } else {
            XCTFail("op[1] should be addSibling")
        }
        XCTAssertEqual(ops[4], .setAttribute(nodeID: NodeID(rawValue: "n_x"), name: "status", value: "done"))
        XCTAssertEqual(ops[6], .setFolded(nodeID: NodeID(rawValue: "n_x"), isFolded: true))
        XCTAssertEqual(ops[7], .setFolded(nodeID: NodeID(rawValue: "n_x"), isFolded: false))
        XCTAssertEqual(ops[8], .setPin(nodeID: NodeID(rawValue: "n_x"), position: Point2D(x: 12.5, y: -3)))
        XCTAssertEqual(ops[9], .setPin(nodeID: NodeID(rawValue: "n_x"), position: nil))
        XCTAssertEqual(ops[10], .move(nodeID: NodeID(rawValue: "n_x"), newParentID: NodeID(rawValue: "n_y"), index: 2))
        XCTAssertEqual(ops[11], .delete(nodeIDs: [NodeID(rawValue: "n_x"), NodeID(rawValue: "n_y")]))
    }

    func testDecodeUnknownOpThrows() {
        XCTAssertThrowsError(try decodeOps(#"[{"op":"explode","id":"n_x"}]"#))
    }

    func testDecodeMissingRequiredFieldThrows() {
        XCTAssertThrowsError(try decodeOps(#"[{"op":"set-text","id":"n_x"}]"#))
    }

    func testDecodeInvalidSideThrows() {
        XCTAssertThrowsError(try decodeOps(#"[{"op":"add-child","parent":"n_x","text":"T","side":"lef"}]"#))
    }

    func testDecodeMalformedIDThrows() {
        XCTAssertThrowsError(try decodeOps(#"[{"op":"add-child","parent":"n_x","id":5,"text":"T"}]"#))
    }

    /// command(in:) must produce the same effect as BatchOps.apply.
    func testCommandInMatchesApply() throws {
        var viaApply = makeMap()
        var viaCommand = viaApply
        let rootID = viaApply.root.id
        let ops: [MapOp] = [
            .addChild(parentID: rootID, newNodeID: NodeID(rawValue: "n_new"), text: "New", side: .auto),
            .setText(nodeID: rootID, text: "Renamed"),
            .setNote(nodeID: rootID, markdown: "note"),
            .setAttribute(nodeID: rootID, name: "status", value: "done"),
            .setAttribute(nodeID: rootID, name: "status", value: ""), // removal path
            .setFormula(nodeID: rootID, formula: "count(children)"),
            .setFolded(nodeID: rootID, isFolded: true),
            .setPin(nodeID: rootID, position: Point2D(x: 1, y: 2)),
            .delete(nodeIDs: [NodeID(rawValue: "n_new")]),
        ]
        try BatchOps.apply(ops, to: &viaApply)
        for op in ops {
            try op.command(in: viaCommand).execute(on: &viaCommand)
        }
        XCTAssertEqual(viaApply, viaCommand)
        XCTAssertEqual(ops[0].affectedIDs, [NodeID(rawValue: "n_new")])
        XCTAssertEqual(ops[1].affectedIDs, [rootID])
        XCTAssertEqual(ops[8].affectedIDs, [NodeID(rawValue: "n_new")])
    }

    func testEncodeDecodeRoundTrip() throws {
        let ops: [MapOp] = [
            .addChild(parentID: NodeID(rawValue: "n_x"), newNodeID: NodeID(rawValue: "n_n"), text: "Kid", side: .left),
            .addSibling(siblingID: NodeID(rawValue: "n_x"), newNodeID: NodeID(rawValue: "n_s"), text: "Sib"),
            .setText(nodeID: NodeID(rawValue: "n_x"), text: "T"),
            .setNote(nodeID: NodeID(rawValue: "n_x"), markdown: "M"),
            .setAttribute(nodeID: NodeID(rawValue: "n_x"), name: "k", value: "v"),
            .setFormula(nodeID: NodeID(rawValue: "n_x"), formula: "count(children)"),
            .setFormula(nodeID: NodeID(rawValue: "n_x"), formula: nil),
            .setFolded(nodeID: NodeID(rawValue: "n_x"), isFolded: true),
            .setFolded(nodeID: NodeID(rawValue: "n_x"), isFolded: false),
            .setPin(nodeID: NodeID(rawValue: "n_x"), position: Point2D(x: 1.5, y: -2)),
            .setPin(nodeID: NodeID(rawValue: "n_x"), position: nil),
            .move(nodeID: NodeID(rawValue: "n_x"), newParentID: NodeID(rawValue: "n_y"), index: 1),
            .delete(nodeIDs: [NodeID(rawValue: "n_x")]),
        ]
        let data = try JSONEncoder().encode(ops)
        let decoded = try JSONDecoder().decode([MapOp].self, from: data)
        XCTAssertEqual(decoded, ops)
    }
}
