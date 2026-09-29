import XCTest
@testable import SwiftMindCore

/// PPT-style shape elements: model, command undo, HTML round-trip, heights.
final class SketchShapeTests: XCTestCase {
    private func sampleShapes() -> [SketchShape] {
        [
            SketchShape(
                id: "s1", kind: .rect,
                x: 10, y: 20, width: 120, height: 60,
                strokeColor: "#FF0000", strokeWidth: 3
            ),
            SketchShape(
                id: "s2", kind: .diamond,
                x: 200, y: 40, width: 90, height: 90,
                strokeColor: "#000000", strokeWidth: 1.5,
                fillColor: "#FFF685",
                text: "判断?", fontFamily: "Helvetica", fontSize: 16,
                textColor: "#000000"
            ),
        ]
    }

    func testCommandRoundTripUndo() throws {
        var map = MindMap.makeEmpty(title: "T")
        let nodeID = map.root.id
        let bus = CommandBus()
        try bus.execute(SetSketchShapesCommand(nodeID: nodeID, shapes: sampleShapes()), on: &map)
        XCTAssertEqual(map.root.sketchShapes, sampleShapes())

        try bus.execute(SetSketchShapesCommand(nodeID: nodeID, shapes: nil), on: &map)
        XCTAssertNil(map.root.sketchShapes)

        try bus.undo(on: &map)
        XCTAssertEqual(map.root.sketchShapes, sampleShapes())
        try bus.undo(on: &map)
        XCTAssertNil(map.root.sketchShapes)
    }

    func testEmptyArrayNormalizesToNil() throws {
        var map = MindMap.makeEmpty(title: "T")
        try SetSketchShapesCommand(nodeID: map.root.id, shapes: []).execute(on: &map)
        XCTAssertNil(map.root.sketchShapes)
    }

    func testHTMLRoundTrip() throws {
        var map = MindMap.makeEmpty(title: "T")
        map.root.sketchShapes = sampleShapes()
        let html = try HTMLCodec.encode(map, includeSkin: false)
        let decoded = try HTMLCodec.decode(html)
        XCTAssertEqual(decoded.root.sketchShapes, sampleShapes())
    }

    func testLegacyFileWithoutShapesDecodes() throws {
        let html = """
        <article class="swiftmind-map" data-map-id="legacy2">
        <section><ul><li data-node-id="root"><span class="node-title">Old</span></li></ul></section>
        </article>
        """
        let decoded = try HTMLCodec.decode(html)
        XCTAssertNil(decoded.root.sketchShapes)
    }

    func testMapOpRoundTrip() throws {
        let op = MapOp.setSketchShapes(nodeID: NodeID(rawValue: "n1"), shapes: sampleShapes())
        XCTAssertEqual(op.name, "set-sketch-shapes")
        XCTAssertEqual(op.affectedIDs, [NodeID(rawValue: "n1")])

        var map = MindMap.makeEmpty(title: "T")
        map.root.id = NodeID(rawValue: "n1")
        let command = try op.command(in: map)
        try command.execute(on: &map)
        XCTAssertEqual(map.root.sketchShapes, sampleShapes())
    }

    /// Shape commits are sketch-only: measured note-card heights survive.
    func testShapeCommitKeepsMeasuredNoteHeights() throws {
        var map = MindMap.makeEmpty(title: "T")
        let bus = CommandBus()
        try bus.execute(InsertChildCommand(parentID: map.root.id, text: "N"), on: &map)
        let child = map.root.children[0].id
        try bus.execute(SetNoteExpandedCommand(nodeID: child, isNoteExpanded: true), on: &map)
        let store = MapStore(map: map)
        store.updateMeasuredNoteHeight(222, for: child)

        try store.dispatch(CompositeAgentCommand(ops: [
            .setSketchShapes(nodeID: child, shapes: sampleShapes()),
        ]))
        XCTAssertEqual(store.noteCardHeights[child], 222,
                       "shape commits must not clear measured note heights")
    }
}
