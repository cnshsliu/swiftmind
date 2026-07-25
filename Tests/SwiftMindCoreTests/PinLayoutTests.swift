import XCTest
@testable import SwiftMindCore

final class PinLayoutTests: XCTestCase {
    func testPinnedNodeUsesPinCoordinates() throws {
        var map = MindMap.makeEmpty(title: "T")
        let bus = CommandBus()
        let a = NodeID(rawValue: "n_a")
        try bus.execute(
            InsertChildCommand(parentID: map.root.id, newNodeID: a, text: "A", side: .right),
            on: &map
        )
        try bus.execute(SetPinCommand(nodeID: a, positionPin: Point2D(x: 200, y: -100)), on: &map)
        let snap = LayoutEngine().layout(map: map)
        let v = snap.nodes.first { $0.id == a }!
        XCTAssertEqual(v.frame.midX, 200, accuracy: 0.5)
        XCTAssertEqual(v.frame.midY, -100, accuracy: 0.5)
        XCTAssertTrue(v.isPinned)
    }

    func testMeasureWidensForIconsAndNote() throws {
        var map = MindMap.makeEmpty(title: "T")
        let bus = CommandBus()
        let a = NodeID(rawValue: "n_a")
        try bus.execute(InsertChildCommand(parentID: map.root.id, newNodeID: a, text: "A", side: .right), on: &map)
        let before = LayoutEngine().layout(map: map).nodes.first { $0.id == a }!.frame.width
        try bus.execute(SetIconsCommand(nodeID: a, icons: [.builtin("flag"), .builtin("star")]), on: &map)
        try bus.execute(SetNoteCommand(nodeID: a, noteMarkdown: "note"), on: &map)
        let after = LayoutEngine().layout(map: map).nodes.first { $0.id == a }!.frame.width
        XCTAssertGreaterThan(after, before)
    }

    func testUnpinReturnsToAutoLayoutSide() throws {
        var map = MindMap.makeEmpty(title: "T")
        let bus = CommandBus()
        let a = NodeID(rawValue: "n_a")
        try bus.execute(
            InsertChildCommand(parentID: map.root.id, newNodeID: a, text: "A", side: .right),
            on: &map
        )
        try bus.execute(SetPinCommand(nodeID: a, positionPin: Point2D(x: -999, y: 500)), on: &map)
        try bus.execute(SetPinCommand(nodeID: a, positionPin: nil), on: &map)
        let snap = LayoutEngine().layout(map: map)
        let rootV = snap.nodes.first { $0.id == map.root.id }!
        let v = snap.nodes.first { $0.id == a }!
        XCTAssertGreaterThan(v.frame.midX, rootV.frame.midX)
        XCTAssertFalse(v.isPinned)
    }
}
