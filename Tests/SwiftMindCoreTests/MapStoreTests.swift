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

    func testSelectDoesNotBumpContentRevision() throws {
        let store = MapStore(map: MindMap.makeEmpty(title: "T"))
        let root = store.map.root.id
        try store.dispatch(InsertChildCommand(parentID: root, text: "A", side: .right))
        let contentBefore = store.contentRevision
        let child = store.map.root.children[0].id
        let frameBefore = store.snapshot().nodes.first { $0.id == child }!.frame
        store.select(child)
        XCTAssertEqual(store.contentRevision, contentBefore)
        XCTAssertGreaterThan(store.selectionRevision, 0)
        let frameAfter = store.snapshot().nodes.first { $0.id == child }!.frame
        XCTAssertEqual(frameBefore, frameAfter)
        XCTAssertTrue(store.snapshot().nodes.first { $0.id == child }!.isSelected)
    }
}
