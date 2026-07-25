import XCTest
@testable import SwiftMindCore

final class CommandBusTests: XCTestCase {
    func testSetTextUndoRedo() throws {
        var map = MindMap.makeEmpty(title: "T")
        let rootID = map.root.id
        let bus = CommandBus()
        try bus.execute(SetTextCommand(nodeID: rootID, newText: "Hello"), on: &map)
        XCTAssertEqual(map.root.text, "Hello")
        try bus.undo(on: &map)
        XCTAssertEqual(map.root.text, "Central Idea")
        try bus.redo(on: &map)
        XCTAssertEqual(map.root.text, "Hello")
    }

    func testInsertChildAndDelete() throws {
        var map = MindMap.makeEmpty(title: "T")
        let bus = CommandBus()
        let childID = NodeID(rawValue: "n_fixed_child")
        try bus.execute(
            InsertChildCommand(parentID: map.root.id, newNodeID: childID, text: "A", side: .right),
            on: &map
        )
        XCTAssertEqual(map.root.children.count, 1)
        XCTAssertEqual(map.root.children[0].text, "A")
        try bus.execute(DeleteNodesCommand(nodeIDs: [childID]), on: &map)
        XCTAssertTrue(map.root.children.isEmpty)
        try bus.undo(on: &map)
        XCTAssertEqual(map.root.children.count, 1)
    }

    func testCannotDeleteRoot() throws {
        var map = MindMap.makeEmpty(title: "T")
        let bus = CommandBus()
        XCTAssertThrowsError(
            try bus.execute(DeleteNodesCommand(nodeIDs: [map.root.id]), on: &map)
        )
    }
}
