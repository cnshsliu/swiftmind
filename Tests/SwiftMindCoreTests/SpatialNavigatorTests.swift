import XCTest
@testable import SwiftMindCore

final class SpatialNavigatorTests: XCTestCase {

    private func makeMap() -> MindMap {
        var map = MindMap.makeEmpty(title: "T")
        map.root.children = [
            Node(id: NodeID(rawValue: "n_a"), text: "A", children: [
                Node(id: NodeID(rawValue: "n_a1"), text: "A1"),
                Node(id: NodeID(rawValue: "n_a2"), text: "A2"),
            ]),
            Node(id: NodeID(rawValue: "n_b"), text: "B"),
            Node(id: NodeID(rawValue: "n_c"), text: "C"),
        ]
        return map
    }

    func testNextAndPreviousSibling() {
        let map = makeMap()
        XCTAssertEqual(SpatialNavigator.sibling(of: NodeID(rawValue: "n_a"), in: map, offset: 1), NodeID(rawValue: "n_b"))
        XCTAssertEqual(SpatialNavigator.sibling(of: NodeID(rawValue: "n_b"), in: map, offset: -1), NodeID(rawValue: "n_a"))
        XCTAssertEqual(SpatialNavigator.sibling(of: NodeID(rawValue: "n_b"), in: map, offset: 1), NodeID(rawValue: "n_c"))
    }

    func testSiblingAtEndsReturnsNil() {
        let map = makeMap()
        XCTAssertNil(SpatialNavigator.sibling(of: NodeID(rawValue: "n_a"), in: map, offset: -1))
        XCTAssertNil(SpatialNavigator.sibling(of: NodeID(rawValue: "n_c"), in: map, offset: 1))
    }

    func testSiblingOfRootReturnsNil() {
        let map = makeMap()
        XCTAssertNil(SpatialNavigator.sibling(of: map.root.id, in: map, offset: 1))
    }

    func testChildToFocusDefaultsToFirst() {
        let map = makeMap()
        XCTAssertEqual(
            SpatialNavigator.childToFocus(of: NodeID(rawValue: "n_a"), in: map, remembered: nil),
            NodeID(rawValue: "n_a1")
        )
    }

    func testChildToFocusUsesRememberedChild() {
        let map = makeMap()
        XCTAssertEqual(
            SpatialNavigator.childToFocus(of: NodeID(rawValue: "n_a"), in: map, remembered: NodeID(rawValue: "n_a2")),
            NodeID(rawValue: "n_a2")
        )
    }

    func testChildToFocusIgnoresStaleRememberedID() {
        let map = makeMap()
        // Remembered id belongs to a different parent → fall back to first child.
        XCTAssertEqual(
            SpatialNavigator.childToFocus(of: NodeID(rawValue: "n_a"), in: map, remembered: NodeID(rawValue: "n_b")),
            NodeID(rawValue: "n_a1")
        )
        XCTAssertEqual(
            SpatialNavigator.childToFocus(of: NodeID(rawValue: "n_a"), in: map, remembered: NodeID(rawValue: "n_deleted")),
            NodeID(rawValue: "n_a1")
        )
    }

    func testChildToFocusOnLeafReturnsNil() {
        let map = makeMap()
        XCTAssertNil(SpatialNavigator.childToFocus(of: NodeID(rawValue: "n_b"), in: map, remembered: nil))
    }
}
