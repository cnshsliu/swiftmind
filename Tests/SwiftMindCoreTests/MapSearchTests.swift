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

    func testResolveUniquePrefersExactTitle() throws {
        var map = MindMap.makeEmpty(title: "T")
        let bus = CommandBus()
        let exact = NodeID(rawValue: "n_exact")
        let other = NodeID(rawValue: "n_other")
        try bus.execute(InsertChildCommand(parentID: map.root.id, newNodeID: exact, text: "Zoom", side: .right), on: &map)
        try bus.execute(InsertChildCommand(parentID: map.root.id, newNodeID: other, text: "Zoom controls", side: .left), on: &map)
        if case .one(let hit) = MapSearch.resolveUnique(map: map, query: "Zoom") {
            XCTAssertEqual(hit.nodeID, exact)
        } else {
            XCTFail("expected unique exact title")
        }
    }

    func testResolveUniqueRefusesTwoExactTitles() throws {
        var map = MindMap.makeEmpty(title: "T")
        let bus = CommandBus()
        try bus.execute(InsertChildCommand(parentID: map.root.id, newNodeID: NodeID(rawValue: "n_1"), text: "Same", side: .right), on: &map)
        try bus.execute(InsertChildCommand(parentID: map.root.id, newNodeID: NodeID(rawValue: "n_2"), text: "Same", side: .left), on: &map)
        if case .ambiguous(let hits) = MapSearch.resolveUnique(map: map, query: "Same") {
            XCTAssertEqual(hits.count, 2)
        } else {
            XCTFail("expected ambiguous")
        }
    }

    func testResolveUniqueNone() {
        let map = MindMap.makeEmpty(title: "T")
        XCTAssertEqual(MapSearch.resolveUnique(map: map, query: "nope"), UniqueSearchResult.none)
    }

    func testEmptyQueryReturnsEmpty() {
        let map = MindMap.makeEmpty(title: "T")
        XCTAssertTrue(MapSearch.search(map: map, query: "").isEmpty)
        XCTAssertTrue(MapSearch.search(map: map, query: "   ").isEmpty)
    }
}
