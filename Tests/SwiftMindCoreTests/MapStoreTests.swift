import XCTest
@testable import SwiftMindCore

final class MapStoreTests: XCTestCase {
    func testDispatchUpdatesMapAndSelection() throws {
        let store = MapStore(map: MindMap.makeEmpty(title: "T"))
        let root = store.map.root.id
        store.select(root)
        try store.dispatch(InsertChildCommand(parentID: root, text: "Kid", side: .right))
        XCTAssertEqual(store.map.root.children.count, 1)
        let child = store.map.root.children[0].id
        XCTAssertEqual(store.selection.primary, child)
        try store.undo()
        XCTAssertTrue(store.map.root.children.isEmpty)
    }

    func testSnapshotMarksSelection() {
        let store = MapStore(map: MindMap.makeEmpty(title: "T"))
        let root = store.map.root.id
        store.select(root)
        let snapshot = store.snapshot()
        XCTAssertTrue(snapshot.nodes.first { $0.id == root }!.isSelected)
        XCTAssertEqual(snapshot.nodes.count, 1)
    }
}
