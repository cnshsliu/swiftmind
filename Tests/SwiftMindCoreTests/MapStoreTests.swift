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

    private func makeThreeChildStore() throws -> (MapStore, NodeID, [NodeID]) {
        let store = MapStore(map: MindMap.makeEmpty(title: "T"))
        let root = store.map.root.id
        for text in ["A", "B", "C"] {
            try store.dispatch(InsertChildCommand(parentID: root, text: text, side: .right))
        }
        return (store, root, store.map.root.children.map(\.id))
    }

    func testDeleteFocusesNextSibling() throws {
        let (store, _, children) = try makeThreeChildStore()
        store.select(children[0])
        try store.dispatch(DeleteNodesCommand(nodeIDs: [children[0]]))
        XCTAssertEqual(store.selection.primary, children[1])
    }

    func testDeleteLastChildFocusesPreviousSibling() throws {
        let (store, _, children) = try makeThreeChildStore()
        store.select(children[2])
        try store.dispatch(DeleteNodesCommand(nodeIDs: [children[2]]))
        XCTAssertEqual(store.selection.primary, children[1])
    }

    func testDeleteOnlyChildFocusesParent() throws {
        let store = MapStore(map: MindMap.makeEmpty(title: "T"))
        let root = store.map.root.id
        try store.dispatch(InsertChildCommand(parentID: root, text: "A", side: .right))
        let child = store.map.root.children[0].id
        store.select(child)
        try store.dispatch(DeleteNodesCommand(nodeIDs: [child]))
        XCTAssertEqual(store.selection.primary, root)
    }

    func testDeleteSkipsSiblingsDeletedInSameBatch() throws {
        let (store, root, children) = try makeThreeChildStore()
        store.select(children[0])
        try store.dispatch(DeleteNodesCommand(nodeIDs: [children[0], children[1]]))
        XCTAssertEqual(store.selection.primary, children[2])
        XCTAssertEqual(store.map.root.children.map(\.id), [children[2]])
        XCTAssertNotNil(store.map.node(id: root))
    }

    func testDeleteNonPrimarySelectedNodeKeepsPrimary() throws {
        let (store, _, children) = try makeThreeChildStore()
        store.select(children[0])
        store.select(children[1], additive: true)
        // Primary is children[1]; delete only children[0].
        try store.dispatch(DeleteNodesCommand(nodeIDs: [children[0]]))
        XCTAssertEqual(store.selection.primary, children[1])
        XCTAssertEqual(store.selection.selectedIDs, [children[1]])
    }

    func testDeleteWithEmptySelectionStaysEmpty() throws {
        let (store, _, children) = try makeThreeChildStore()
        store.clearSelection()
        // Hover-delete path: no focus, dispatch delete for one node.
        try store.dispatch(DeleteNodesCommand(nodeIDs: [children[1]]))
        XCTAssertNil(store.selection.primary)
        XCTAssertTrue(store.selection.selectedIDs.isEmpty)
    }
}
