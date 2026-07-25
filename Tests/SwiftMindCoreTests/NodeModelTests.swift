import XCTest
@testable import SwiftMindCore

final class NodeModelTests: XCTestCase {
    func testMindMapStartsWithRoot() {
        let map = MindMap.makeEmpty(title: "Demo")
        XCTAssertEqual(map.title, "Demo")
        XCTAssertEqual(map.schemaVersion, 1)
        XCTAssertEqual(map.root.text, "Central Idea")
        XCTAssertTrue(map.root.children.isEmpty)
    }

    func testFindNodeReturnsNestedChild() {
        var map = MindMap.makeEmpty(title: "T")
        let childID = NodeID(rawValue: "n_child")
        map.root.children.append(
            Node(id: childID, text: "Child", side: .right)
        )
        XCTAssertEqual(map.node(id: childID)?.text, "Child")
        XCTAssertNil(map.node(id: NodeID(rawValue: "missing")))
    }

    func testUpdateNodeTextViaPath() {
        var map = MindMap.makeEmpty(title: "T")
        let childID = NodeID(rawValue: "n_child")
        map.root.children = [Node(id: childID, text: "Old", side: .left)]
        let ok = map.updateNode(id: childID) { $0.text = "New" }
        XCTAssertTrue(ok)
        XCTAssertEqual(map.node(id: childID)?.text, "New")
    }
}
