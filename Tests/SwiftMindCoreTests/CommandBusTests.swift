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

    func testMoveNodeReparents() throws {
        var map = MindMap.makeEmpty(title: "T")
        let bus = CommandBus()
        let a = NodeID(rawValue: "n_a")
        let b = NodeID(rawValue: "n_b")
        try bus.execute(InsertChildCommand(parentID: map.root.id, newNodeID: a, text: "A", side: .right), on: &map)
        try bus.execute(InsertChildCommand(parentID: map.root.id, newNodeID: b, text: "B", side: .right), on: &map)
        try bus.execute(MoveNodeCommand(nodeID: b, newParentID: a, index: 0), on: &map)
        XCTAssertEqual(map.node(id: a)?.children.map(\.id), [b])
        XCTAssertEqual(map.root.children.map(\.id), [a])
    }

    func testSetFoldedAndStyle() throws {
        var map = MindMap.makeEmpty(title: "T")
        let bus = CommandBus()
        try bus.execute(SetFoldedCommand(nodeID: map.root.id, isFolded: true), on: &map)
        XCTAssertTrue(map.root.isFolded)
        var style = NodeStyle.default
        style.isBold = true
        style.fontSize = 18
        try bus.execute(SetStyleCommand(nodeID: map.root.id, style: style), on: &map)
        XCTAssertEqual(map.root.style.fontSize, 18)
        XCTAssertTrue(map.root.style.isBold)
    }

    func testInsertSiblingAfterKnownChild() throws {
        var map = MindMap.makeEmpty(title: "T")
        let bus = CommandBus()
        let a = NodeID(rawValue: "n_sib_a")
        let b = NodeID(rawValue: "n_sib_b")
        let c = NodeID(rawValue: "n_sib_c")
        try bus.execute(InsertChildCommand(parentID: map.root.id, newNodeID: a, text: "A", side: .right), on: &map)
        try bus.execute(InsertChildCommand(parentID: map.root.id, newNodeID: c, text: "C", side: .right), on: &map)
        try bus.execute(
            InsertSiblingCommand(siblingID: a, newNodeID: b, text: "B", side: .right),
            on: &map
        )
        XCTAssertEqual(map.root.children.map(\.id), [a, b, c])
        XCTAssertEqual(map.root.children[1].text, "B")
        try bus.undo(on: &map)
        XCTAssertEqual(map.root.children.map(\.id), [a, c])
    }

    func testSetMapTitleUndoRedo() throws {
        var map = MindMap.makeEmpty(title: "Original")
        let bus = CommandBus()
        try bus.execute(SetMapTitleCommand(newTitle: "Renamed"), on: &map)
        XCTAssertEqual(map.title, "Renamed")
        try bus.undo(on: &map)
        XCTAssertEqual(map.title, "Original")
        try bus.redo(on: &map)
        XCTAssertEqual(map.title, "Renamed")
    }
}
