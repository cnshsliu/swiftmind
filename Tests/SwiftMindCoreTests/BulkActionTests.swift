import XCTest
@testable import SwiftMindCore

final class BulkActionTests: XCTestCase {

    private func makeMap() -> MindMap {
        var map = MindMap.makeEmpty(title: "T")
        map.root.children = [
            Node(id: NodeID(rawValue: "n_t1"), text: "Write tests"),
            Node(id: NodeID(rawValue: "n_t2"), text: "Ship release", attributes: [NodeAttribute(name: "status", value: "wip")]),
            Node(id: NodeID(rawValue: "n_other"), text: "Random note"),
        ]
        return map
    }

    func testSetAttributeOnMatches() throws {
        var map = makeMap()
        let bus = CommandBus()
        let command = ApplyBulkActionCommand(
            rule: .textContains("release"),
            action: .setAttribute(name: "status", value: "done")
        )
        try bus.execute(command, on: &map)

        XCTAssertEqual(command.affectedCount, 1)
        XCTAssertEqual(map.node(id: NodeID(rawValue: "n_t2"))?.attributeValue(named: "status"), "done")
        XCTAssertTrue(map.attributeRegistry.contains("status"))

        try bus.undo(on: &map)
        XCTAssertEqual(map.node(id: NodeID(rawValue: "n_t2"))?.attributeValue(named: "status"), "wip")
    }

    func testAddIconOnAllTextMatches() throws {
        var map = makeMap()
        let bus = CommandBus()
        let command = ApplyBulkActionCommand(rule: .textContains("e"), action: .addIcon("star"))
        try bus.execute(command, on: &map)

        // "Write tests", "Ship release" contain "e"; root "Central Idea" and "Random note" do too.
        XCTAssertEqual(command.affectedCount, 4)
        XCTAssertTrue(map.node(id: NodeID(rawValue: "n_t1"))!.icons.contains(NodeIcon(id: "star")))

        try bus.undo(on: &map)
        XCTAssertFalse(map.node(id: NodeID(rawValue: "n_t1"))!.icons.contains(NodeIcon(id: "star")))
    }

    func testRemoveAttribute() throws {
        var map = makeMap()
        let bus = CommandBus()
        try bus.execute(
            ApplyBulkActionCommand(rule: .hasIcon("zzz"), action: .setAttribute(name: "x", value: "1")),
            on: &map
        ) // no matches → no-op
        try bus.execute(
            ApplyBulkActionCommand(
                rule: .attributeEquals(name: "status", value: "wip"),
                action: .removeAttribute(name: "status")
            ),
            on: &map
        )
        XCTAssertNil(map.node(id: NodeID(rawValue: "n_t2"))?.attributeValue(named: "status"))

        try bus.undo(on: &map)
        XCTAssertEqual(map.node(id: NodeID(rawValue: "n_t2"))?.attributeValue(named: "status"), "wip")
    }

    func testSetStyleNameAndClear() throws {
        var map = makeMap()
        let bus = CommandBus()
        try bus.execute(
            ApplyBulkActionCommand(rule: .textContains("tests"), action: .setStyleName("important")),
            on: &map
        )
        XCTAssertEqual(map.node(id: NodeID(rawValue: "n_t1"))?.styleName, "important")

        try bus.execute(
            ApplyBulkActionCommand(rule: .textContains("tests"), action: .setStyleName(nil)),
            on: &map
        )
        XCTAssertNil(map.node(id: NodeID(rawValue: "n_t1"))?.styleName)

        try bus.undo(on: &map) // undo clear → back to important
        XCTAssertEqual(map.node(id: NodeID(rawValue: "n_t1"))?.styleName, "important")
        try bus.undo(on: &map) // undo set → back to nil
        XCTAssertNil(map.node(id: NodeID(rawValue: "n_t1"))?.styleName)
    }

    func testNoMatchesIsNoOp() throws {
        var map = makeMap()
        let before = map
        let command = ApplyBulkActionCommand(rule: .textContains("zzz-no-match"), action: .addIcon("flag"))
        try command.execute(on: &map)
        XCTAssertEqual(command.affectedCount, 0)
        XCTAssertEqual(map, before)
        try command.undo(on: &map)
        XCTAssertEqual(map, before)
    }

    func testReExecuteAfterUndoUsesSameSnapshot() throws {
        var map = makeMap()
        let bus = CommandBus()
        let command = ApplyBulkActionCommand(
            rule: .textContains("release"),
            action: .setAttribute(name: "status", value: "done")
        )
        try bus.execute(command, on: &map)
        try bus.undo(on: &map)
        try bus.redo(on: &map)
        XCTAssertEqual(map.node(id: NodeID(rawValue: "n_t2"))?.attributeValue(named: "status"), "done")
    }
}
