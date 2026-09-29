import XCTest
@testable import SwiftMindCore

/// Sketch-board text elements: model, command undo, HTML round-trip.
final class SketchTextTests: XCTestCase {
    private func sampleTexts() -> [SketchText] {
        [
            SketchText(
                id: "t1",
                text: "hello", x: 10, y: 20,
                fontFamily: "Helvetica", fontSize: 18,
                color: "#FF0000", background: nil, width: 42, height: 22
            ),
            SketchText(
                id: "t2",
                text: "sticky\nnote", x: 100, y: 80,
                fontFamily: "Chalkboard SE", fontSize: 14,
                color: "#000000", background: "#FFF685", width: 90, height: 60
            ),
        ]
    }

    func testCommandRoundTripUndo() throws {
        var map = MindMap.makeEmpty(title: "T")
        let nodeID = map.root.id
        let bus = CommandBus()
        try bus.execute(
            SetSketchTextsCommand(nodeID: nodeID, texts: sampleTexts()),
            on: &map
        )
        XCTAssertEqual(map.root.sketchTexts, sampleTexts())

        try bus.execute(
            SetSketchTextsCommand(nodeID: nodeID, texts: nil),
            on: &map
        )
        XCTAssertNil(map.root.sketchTexts)

        try bus.undo(on: &map)
        XCTAssertEqual(map.root.sketchTexts, sampleTexts())
        try bus.undo(on: &map)
        XCTAssertNil(map.root.sketchTexts)
    }

    func testEmptyArrayNormalizesToNil() throws {
        var map = MindMap.makeEmpty(title: "T")
        try SetSketchTextsCommand(nodeID: map.root.id, texts: []).execute(on: &map)
        XCTAssertNil(map.root.sketchTexts, "empty text arrays should not persist")
    }

    func testHTMLRoundTrip() throws {
        var map = MindMap.makeEmpty(title: "T")
        map.root.sketch = Data([1, 2, 3])
        map.root.sketchWidth = 100
        map.root.sketchHeight = 80
        map.root.sketchTexts = sampleTexts()

        let html = try HTMLCodec.encode(map, includeSkin: false)
        let decoded = try HTMLCodec.decode(html)
        XCTAssertEqual(decoded.root.sketchTexts, sampleTexts())
        XCTAssertEqual(decoded.root.sketch, Data([1, 2, 3]))
        XCTAssertEqual(decoded.root.sketchWidth, 100)

        // A single text edits in place (id-stable update path).
        var updated = sampleTexts()
        updated[0].text = "edited"
        map.root.sketchTexts = updated
        let html2 = try HTMLCodec.encode(map, includeSkin: false)
        let decoded2 = try HTMLCodec.decode(html2)
        XCTAssertEqual(decoded2.root.sketchTexts, updated)
        XCTAssertNotEqual(decoded2.root.sketchTexts, sampleTexts())
    }

    func testLegacyFileWithoutTextsDecodes() throws {
        // Hand-written pre-text file: no node-sketch-texts div anywhere.
        let html = """
        <article class="swiftmind-map" data-map-id="legacy">
        <section><ul><li data-node-id="root"><span class="node-title">Old</span></li></ul></section>
        </article>
        """
        let decoded = try HTMLCodec.decode(html)
        XCTAssertNil(decoded.root.sketchTexts)
    }

    func testMapOpRoundTrip() throws {
        let op = MapOp.setSketchTexts(nodeID: NodeID(rawValue: "n1"), texts: sampleTexts())
        XCTAssertEqual(op.name, "set-sketch-texts")
        XCTAssertEqual(op.affectedIDs, [NodeID(rawValue: "n1")])

        var map = MindMap.makeEmpty(title: "T")
        map.root.id = NodeID(rawValue: "n1")
        let command = try op.command(in: map)
        try command.execute(on: &map)
        XCTAssertEqual(map.root.sketchTexts, sampleTexts())
    }
}
