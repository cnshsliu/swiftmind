import XCTest
@testable import SwiftMindCore

final class FormulaPersistenceTests: XCTestCase {

    // MARK: - Command

    func testSetFormulaAndUndo() throws {
        var map = MindMap.makeEmpty(title: "T")
        let bus = CommandBus()
        let root = map.root.id

        try bus.execute(SetFormulaCommand(nodeID: root, formula: "count(children)"), on: &map)
        XCTAssertEqual(map.root.formula, "count(children)")

        try bus.undo(on: &map)
        XCTAssertNil(map.root.formula)

        try bus.redo(on: &map)
        XCTAssertEqual(map.root.formula, "count(children)")
    }

    func testClearFormulaRestoresNilOnUndo() throws {
        var map = MindMap.makeEmpty(title: "T")
        let bus = CommandBus()
        let root = map.root.id

        try bus.execute(SetFormulaCommand(nodeID: root, formula: "1 + 1"), on: &map)
        try bus.execute(SetFormulaCommand(nodeID: root, formula: nil), on: &map)
        XCTAssertNil(map.root.formula)

        try bus.undo(on: &map)
        XCTAssertEqual(map.root.formula, "1 + 1")
    }

    func testSetFormulaOnMissingNodeThrows() {
        var map = MindMap.makeEmpty(title: "T")
        XCTAssertThrowsError(
            try SetFormulaCommand(nodeID: NodeID(rawValue: "n_missing"), formula: "1").execute(on: &map)
        )
    }

    // MARK: - HTML round-trip

    func testFormulaRoundTripsThroughHTML() throws {
        var map = MindMap.makeEmpty(title: "T")
        map.root.formula = "sum(children, attr: \"cost\")"
        map.root.children = [
            Node(text: "Child", attributes: [NodeAttribute(name: "cost", value: "10")])
        ]

        let html = try HTMLCodec.encode(map, includeSkin: false)
        XCTAssertTrue(html.contains("data-formula=\"sum(children, attr: &quot;cost&quot;)\""))

        let decoded = try HTMLCodec.decode(html)
        XCTAssertEqual(decoded.root.formula, "sum(children, attr: \"cost\")")
        XCTAssertNil(decoded.root.children[0].formula)
    }

    func testLegacyHTMLWithoutFormulaDecodesToNil() throws {
        let map = MindMap.makeEmpty(title: "T")
        let html = try HTMLCodec.encode(map, includeSkin: false)
        XCTAssertFalse(html.contains("data-formula"))

        let decoded = try HTMLCodec.decode(html)
        XCTAssertNil(decoded.root.formula)
    }

    func testEmptyFormulaStringIsNotEncoded() throws {
        var map = MindMap.makeEmpty(title: "T")
        map.root.formula = ""
        let html = try HTMLCodec.encode(map, includeSkin: false)
        XCTAssertFalse(html.contains("data-formula"))
    }

    // MARK: - End-to-end: stored formula evaluates after reload

    func testStoredFormulaEvaluatesAfterRoundTrip() throws {
        var map = MindMap.makeEmpty(title: "T")
        map.root.formula = "sum(children, attr: \"cost\")"
        map.root.children = [
            Node(text: "A", attributes: [NodeAttribute(name: "cost", value: "10")]),
            Node(text: "B", attributes: [NodeAttribute(name: "cost", value: "20")]),
        ]

        let decoded = try HTMLCodec.decode(HTMLCodec.encode(map, includeSkin: false))
        let result = FormulaEvaluator.evaluate(source: decoded.root.formula!, on: decoded.root)
        XCTAssertEqual(result, .number(30))
    }
}
