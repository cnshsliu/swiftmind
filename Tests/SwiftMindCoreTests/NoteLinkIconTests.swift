import XCTest
@testable import SwiftMindCore

final class NoteLinkIconTests: XCTestCase {
    func testNodeDefaultsHaveEmptyNoteLinksIcons() {
        let n = Node(text: "Hi")
        XCTAssertEqual(n.noteMarkdown, "")
        XCTAssertTrue(n.links.isEmpty)
        XCTAssertTrue(n.icons.isEmpty)
    }

    func testNodeLinkEqualityAndKinds() {
        let url = NodeLink.url(URL(string: "https://example.com")!)
        let node = NodeLink.node(NodeID(rawValue: "n_x"))
        XCTAssertNotEqual(url, node)
        XCTAssertEqual(url, NodeLink.url(URL(string: "https://example.com")!))
    }

    func testIconRefBuiltin() {
        let icon = IconRef.builtin("flag")
        XCTAssertEqual(icon.id, "flag")
        XCTAssertTrue(IconRef.catalog.contains(where: { $0.id == "check" }))
        XCTAssertTrue(IconRef.catalog.contains(where: { $0.id == "flag" }))
    }

    func testSetNoteUndo() throws {
        var map = MindMap.makeEmpty(title: "T")
        let bus = CommandBus()
        let id = map.root.id
        try bus.execute(SetNoteCommand(nodeID: id, noteMarkdown: "hello **world**"), on: &map)
        XCTAssertEqual(map.root.noteMarkdown, "hello **world**")
        try bus.undo(on: &map)
        XCTAssertEqual(map.root.noteMarkdown, "")
    }

    func testSetLinksAndIcons() throws {
        var map = MindMap.makeEmpty(title: "T")
        let bus = CommandBus()
        let id = map.root.id
        let link = NodeLink.url(URL(string: "https://a.test")!)
        try bus.execute(SetLinksCommand(nodeID: id, links: [link]), on: &map)
        try bus.execute(SetIconsCommand(nodeID: id, icons: [.builtin("flag")]), on: &map)
        XCTAssertEqual(map.root.links, [link])
        XCTAssertEqual(map.root.icons.map(\.id), ["flag"])
    }

    func testSetPinUndo() throws {
        var map = MindMap.makeEmpty(title: "T")
        let bus = CommandBus()
        let id = map.root.id
        let p = Point2D(x: 100, y: -40)
        try bus.execute(SetPinCommand(nodeID: id, positionPin: p), on: &map)
        XCTAssertEqual(map.root.positionPin, p)
        try bus.execute(SetPinCommand(nodeID: id, positionPin: nil), on: &map)
        XCTAssertNil(map.root.positionPin)
        try bus.undo(on: &map)
        XCTAssertEqual(map.root.positionPin, p)
    }
}
