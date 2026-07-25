import XCTest
@testable import SwiftMindCore

final class MapSearchTests: XCTestCase {
    func testTitleHit() throws {
        var map = MindMap.makeEmpty(title: "T")
        let bus = CommandBus()
        let a = NodeID(rawValue: "n_alpha")
        try bus.execute(
            InsertChildCommand(parentID: map.root.id, newNodeID: a, text: "Alpha Node", side: .right),
            on: &map
        )
        let hits = MapSearch.search(map: map, query: "alpha")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].nodeID, a)
        XCTAssertEqual(hits[0].title, "Alpha Node")
        XCTAssertFalse(hits[0].matchInNote)
    }

    func testNoteOnlyHitSetsMatchInNote() throws {
        var map = MindMap.makeEmpty(title: "T")
        let bus = CommandBus()
        let a = NodeID(rawValue: "n_note")
        try bus.execute(
            InsertChildCommand(parentID: map.root.id, newNodeID: a, text: "Plain title", side: .right),
            on: &map
        )
        try bus.execute(SetNoteCommand(nodeID: a, noteMarkdown: "secret beta details"), on: &map)
        let hits = MapSearch.search(map: map, query: "beta")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].nodeID, a)
        XCTAssertTrue(hits[0].matchInNote)
    }

    func testEmptyQueryReturnsEmpty() {
        let map = MindMap.makeEmpty(title: "T")
        XCTAssertTrue(MapSearch.search(map: map, query: "").isEmpty)
        XCTAssertTrue(MapSearch.search(map: map, query: "   ").isEmpty)
    }
}
