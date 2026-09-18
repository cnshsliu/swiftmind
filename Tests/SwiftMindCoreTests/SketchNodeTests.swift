import XCTest
@testable import SwiftMindCore

/// Sketch (drawing) node: model, command, op wire, layout sizing, HTML persistence.
final class SketchNodeTests: XCTestCase {
    private let payload = Data("fake-pkdrawing-bytes".utf8)

    private func makeMapWithSketchNode(
        text: String = "",
        sketch: Data? = Data("fake-pkdrawing-bytes".utf8),
        width: Double? = 120,
        height: Double? = 80
    ) throws -> (MindMap, NodeID) {
        var map = MindMap.makeEmpty(title: "S")
        let id = NodeID(rawValue: "n_sketch")
        try InsertChildCommand(parentID: map.root.id, newNodeID: id, text: text, side: .right)
            .execute(on: &map)
        try SetSketchCommand(nodeID: id, sketch: sketch, width: width, height: height)
            .execute(on: &map)
        return (map, id)
    }

    // MARK: - Model

    func testNodeSketchDefaultsNil() {
        let node = Node(text: "A")
        XCTAssertNil(node.sketch)
        XCTAssertNil(node.sketchWidth)
        XCTAssertNil(node.sketchHeight)
    }

    func testCodableDecodesMissingSketchKeys() throws {
        // Old documents lack the keys entirely — decode must yield nils.
        var node = Node(text: "A")
        node.sketch = payload
        node.sketchWidth = 10
        node.sketchHeight = 10
        let encoded = try JSONEncoder().encode(node)
        var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        object.removeValue(forKey: "sketch")
        object.removeValue(forKey: "sketchWidth")
        object.removeValue(forKey: "sketchHeight")
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(Node.self, from: stripped)
        XCTAssertEqual(decoded.text, "A")
        XCTAssertNil(decoded.sketch)
        XCTAssertNil(decoded.sketchWidth)
        XCTAssertNil(decoded.sketchHeight)
    }

    // MARK: - Command

    func testSetSketchUndoRedo() throws {
        var map = MindMap.makeEmpty(title: "T")
        let id = NodeID(rawValue: "n_s")
        try InsertChildCommand(parentID: map.root.id, newNodeID: id, text: "S", side: .right)
            .execute(on: &map)
        let bus = CommandBus()

        try bus.execute(SetSketchCommand(nodeID: id, sketch: payload, width: 100, height: 60), on: &map)
        XCTAssertEqual(map.node(id: id)?.sketch, payload)
        XCTAssertEqual(map.node(id: id)?.sketchWidth, 100)
        XCTAssertEqual(map.node(id: id)?.sketchHeight, 60)

        try bus.undo(on: &map)
        XCTAssertNil(map.node(id: id)?.sketch)
        XCTAssertNil(map.node(id: id)?.sketchWidth)

        try bus.redo(on: &map)
        XCTAssertEqual(map.node(id: id)?.sketch, payload)
    }

    func testSetSketchNilRemoves() throws {
        var (map, id) = try makeMapWithSketchNode()
        try SetSketchCommand(nodeID: id, sketch: nil, width: nil, height: nil).execute(on: &map)
        XCTAssertNil(map.node(id: id)?.sketch)
        XCTAssertNil(map.node(id: id)?.sketchWidth)
        XCTAssertNil(map.node(id: id)?.sketchHeight)
    }

    func testSetSketchUnknownNodeThrows() {
        var map = MindMap.makeEmpty(title: "T")
        XCTAssertThrowsError(
            try SetSketchCommand(nodeID: NodeID(rawValue: "n_missing"), sketch: payload, width: 1, height: 1)
                .execute(on: &map)
        )
    }

    // MARK: - MapOp

    func testMapOpSetSketch() throws {
        let op = MapOp.setSketch(nodeID: NodeID(rawValue: "n_x"), data: payload, width: 50, height: 50)
        XCTAssertEqual(op.name, "set-sketch")
        XCTAssertEqual(op.affectedIDs, [NodeID(rawValue: "n_x")])

        var map = MindMap.makeEmpty(title: "T")
        let id = NodeID(rawValue: "n_x")
        try InsertChildCommand(parentID: map.root.id, newNodeID: id, text: "X", side: .right)
            .execute(on: &map)
        try BatchOps.apply([.setSketch(nodeID: id, data: payload, width: 50, height: 50)], to: &map)
        XCTAssertEqual(map.node(id: id)?.sketch, payload)
    }

    func testMapOpSetSketchWireRoundTrip() throws {
        let op = MapOp.setSketch(nodeID: NodeID(rawValue: "n_w"), data: payload, width: 123.5, height: 45.5)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(op)
        let decoded = try decoder.decode(MapOp.self, from: data)
        XCTAssertEqual(decoded, op)
    }

    // MARK: - Layout

    func testLayoutSizesSketchNodeFromContent() throws {
        var (map, id) = try makeMapWithSketchNode(sketch: payload, width: 120, height: 80)
        let snap = LayoutEngine().layout(map: map)
        let v = snap.nodes.first { $0.id == id }!
        let cfg = LayoutConfig()
        XCTAssertEqual(v.frame.width, 120 + cfg.paddingX * 2, accuracy: 0.5)
        XCTAssertEqual(v.frame.height, 80 + 16, accuracy: 0.5)
        XCTAssertTrue(v.hasSketch)
        XCTAssertEqual(v.sketchSize?.x, 120)
        XCTAssertEqual(v.sketchSize?.y, 80)
    }

    func testLayoutClampsRunawaySketch() throws {
        var (map, id) = try makeMapWithSketchNode(width: 5000, height: 5000)
        let snap = LayoutEngine().layout(map: map)
        let v = snap.nodes.first { $0.id == id }!
        let cfg = LayoutConfig()
        XCTAssertEqual(v.frame.width, cfg.sketchMaxSize + cfg.paddingX * 2, accuracy: 0.5)
        XCTAssertEqual(v.frame.height, cfg.sketchMaxSize + 16, accuracy: 0.5)
    }

    func testLayoutTitleStripAddedWhenTextPresent() throws {
        var (map, id) = try makeMapWithSketchNode(text: "Titled", width: 100, height: 50)
        let snap = LayoutEngine().layout(map: map)
        let withTitle = snap.nodes.first { $0.id == id }!
        XCTAssertEqual(withTitle.frame.height, 50 + 16 + LayoutConfig().sketchTitleLineHeight, accuracy: 0.5)

        var (map2, id2) = try makeMapWithSketchNode(text: "", width: 100, height: 50)
        let snap2 = LayoutEngine().layout(map: map2)
        let noTitle = snap2.nodes.first { $0.id == id2 }!
        XCTAssertEqual(noTitle.frame.height, 50 + 16, accuracy: 0.5)
    }

    func testLayoutEmptySketchPlaceholder() throws {
        var (map, id) = try makeMapWithSketchNode(width: nil, height: nil)
        let snap = LayoutEngine().layout(map: map)
        let v = snap.nodes.first { $0.id == id }!
        let cfg = LayoutConfig()
        XCTAssertEqual(v.frame.width, cfg.sketchMinSize + cfg.paddingX * 2, accuracy: 0.5)
        XCTAssertEqual(v.frame.height, cfg.sketchMinSize + 16, accuracy: 0.5)
        XCTAssertTrue(v.hasSketch)
        XCTAssertNil(v.sketchSize)
    }

    func testSketchSuppressesExpandedNoteCard() throws {
        var (map, id) = try makeMapWithSketchNode(width: 100, height: 60)
        try SetNoteCommand(nodeID: id, noteMarkdown: "note body").execute(on: &map)
        try SetNoteExpandedCommand(nodeID: id, isNoteExpanded: true).execute(on: &map)
        let snap = LayoutEngine().layout(map: map)
        let v = snap.nodes.first { $0.id == id }!
        XCTAssertTrue(v.hasNote)
        XCTAssertFalse(v.isNoteExpanded, "sketch wins over the note card")
        // Sized as a sketch (60 + 16), not as an expanded note card.
        XCTAssertEqual(v.frame.height, 60 + 16, accuracy: 0.5)
        XCTAssertEqual(v.frame.width, 100 + LayoutConfig().paddingX * 2, accuracy: 0.5)
    }

    // MARK: - HTML persistence

    func testSketchRoundTripsThroughHTML() throws {
        var (map, id) = try makeMapWithSketchNode(text: "Diagram", width: 123.5, height: 88.25)
        try SetNoteCommand(nodeID: id, noteMarkdown: "with note too").execute(on: &map)
        let html = try HTMLCodec.encode(map, includeSkin: false)
        XCTAssertTrue(html.contains("node-sketch"))
        let decoded = try HTMLCodec.decode(html)
        XCTAssertEqual(decoded.node(id: id)?.sketch, payload)
        XCTAssertEqual(decoded.node(id: id)?.sketchWidth, 123.5)
        XCTAssertEqual(decoded.node(id: id)?.sketchHeight, 88.25)
        XCTAssertEqual(decoded.node(id: id)?.noteMarkdown, "with note too")
    }

    func testOldHTMLWithoutSketchDecodesNil() throws {
        var (map, id) = try makeMapWithSketchNode(width: nil, height: nil)
        // Force no sketch at all.
        try SetSketchCommand(nodeID: id, sketch: nil, width: nil, height: nil).execute(on: &map)
        let html = try HTMLCodec.encode(map, includeSkin: false)
        XCTAssertFalse(html.contains("node-sketch"))
        let decoded = try HTMLCodec.decode(html)
        XCTAssertNil(decoded.node(id: id)?.sketch)
    }

    func testCorruptedSketchBase64Tolerated() throws {
        var (map, _) = try makeMapWithSketchNode(width: 100, height: 60)
        let html = try HTMLCodec.encode(map, includeSkin: false)
        // Corrupt the payload inside the hidden div (base64 chars -> invalid).
        let broken = html.replacingOccurrences(of: "fake-pkdrawing-bytes", with: "!!!not-base64!!!")
        let decoded = try HTMLCodec.decode(broken)
        // File still loads; the sketch is dropped.
        XCTAssertEqual(decoded.root.children.count, map.root.children.count)
    }
}
