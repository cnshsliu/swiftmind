import XCTest
@testable import SwiftMindCore

/// Sketch-board image elements: model, command undo, HTML round-trip.
final class SketchImageTests: XCTestCase {
    private func sample() -> [SketchImageElement] {
        [
            SketchImageElement(id: "i1", x: 10, y: 20, width: 100, height: 80, data: Data([1, 2, 3])),
            SketchImageElement(id: "i2", x: 200, y: 60, width: 50, height: 50, data: Data([9])),
        ]
    }

    func testCommandRoundTripUndo() throws {
        var map = MindMap.makeEmpty(title: "T")
        let nodeID = map.root.id
        let bus = CommandBus()
        try bus.execute(SetSketchImagesCommand(nodeID: nodeID, images: sample()), on: &map)
        XCTAssertEqual(map.root.sketchImages, sample())

        try bus.execute(SetSketchImagesCommand(nodeID: nodeID, images: nil), on: &map)
        XCTAssertNil(map.root.sketchImages)

        try bus.undo(on: &map)
        XCTAssertEqual(map.root.sketchImages, sample())
    }

    func testHTMLRoundTrip() throws {
        var map = MindMap.makeEmpty(title: "T")
        map.root.sketchImages = sample()
        let html = try HTMLCodec.encode(map, includeSkin: false)
        let decoded = try HTMLCodec.decode(html)
        XCTAssertEqual(decoded.root.sketchImages, sample())
    }

    func testMapOpRoundTrip() throws {
        let op = MapOp.setSketchImages(nodeID: NodeID(rawValue: "n1"), images: sample())
        XCTAssertEqual(op.name, "set-sketch-images")
        var map = MindMap.makeEmpty(title: "T")
        map.root.id = NodeID(rawValue: "n1")
        let command = try op.command(in: map)
        try command.execute(on: &map)
        XCTAssertEqual(map.root.sketchImages, sample())
    }
}
