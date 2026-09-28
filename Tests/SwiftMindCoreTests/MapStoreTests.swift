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

    func testLayoutConfigChangeBumpsContentRevision() {
        let store = MapStore(map: MindMap.makeEmpty(title: "T"))
        let contentBefore = store.contentRevision
        var config = store.layoutConfig
        config.mediaMaxSize = 64
        store.layoutConfig = config
        XCTAssertGreaterThan(store.contentRevision, contentBefore)
        // Assigning an equal config is a no-op (no spurious re-layout).
        let afterChange = store.contentRevision
        store.layoutConfig = config
        XCTAssertEqual(store.contentRevision, afterChange)
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

    func testMeasuredNoteHeightRelayoutsOnce() {
        var map = MindMap.makeEmpty(title: "t")
        map.root.isNoteExpanded = true
        map.root.noteMarkdown = "hello"
        let store = MapStore(map: map)
        let rootID = map.root.id
        let before = store.snapshot().nodes.first { $0.id == rootID }!.frame.height
        store.updateMeasuredNoteHeight(80, for: rootID)
        let after = store.snapshot().nodes.first { $0.id == rootID }!.frame.height
        XCTAssertEqual(after, 80)
        XCTAssertNotEqual(after, before)
        let revision = store.contentRevision
        store.updateMeasuredNoteHeight(80.4, for: rootID)
        XCTAssertEqual(store.contentRevision, revision)
        XCTAssertEqual(store.snapshot().nodes.first { $0.id == rootID }!.frame.height, 80)
    }

    func testContentReplacementDropsMeasuredNoteHeights() throws {
        var map = MindMap.makeEmpty(title: "t")
        map.root.isNoteExpanded = true
        map.root.noteMarkdown = "hello"
        let store = MapStore(map: map)
        let rootID = map.root.id
        store.updateMeasuredNoteHeight(80, for: rootID)
        XCTAssertEqual(store.noteCardHeights[rootID], 80)

        // A failed command does not change the map, so the measurement stays.
        XCTAssertThrowsError(
            try store.dispatch(SetNoteCommand(nodeID: NodeID(rawValue: "missing"), noteMarkdown: "nope"))
        )
        XCTAssertEqual(store.noteCardHeights[rootID], 80)

        try store.dispatch(SetNoteCommand(nodeID: rootID, noteMarkdown: "changed"))
        XCTAssertTrue(store.noteCardHeights.isEmpty)

        store.updateMeasuredNoteHeight(80, for: rootID)
        try store.undo()
        XCTAssertTrue(store.noteCardHeights.isEmpty)

        store.updateMeasuredNoteHeight(80, for: rootID)
        try store.redo()
        XCTAssertTrue(store.noteCardHeights.isEmpty)

        store.updateMeasuredNoteHeight(80, for: rootID)
        store.replaceMap(MindMap.makeEmpty(title: "fresh"))
        XCTAssertTrue(store.noteCardHeights.isEmpty)
    }

    // MARK: - Sibling reorder (1.2 ⌥↑/⌥↓)

    func testReorderSiblingUpAndDown() throws {
        let store = MapStore(map: .makeEmpty(title: "T"))
        let root = store.map.root.id
        let a = NodeID(rawValue: "n_a"), b = NodeID(rawValue: "n_b"), c = NodeID(rawValue: "n_c")
        try store.dispatch(InsertChildCommand(parentID: root, newNodeID: a, text: "A", side: .right))
        try store.dispatch(InsertChildCommand(parentID: root, newNodeID: b, text: "B", side: .right))
        try store.dispatch(InsertChildCommand(parentID: root, newNodeID: c, text: "C", side: .right))

        func order() -> [String] {
            store.map.root.children.map(\.text)
        }

        // B up (index 1 → 0)
        try store.dispatch(MoveNodeCommand(nodeID: b, newParentID: root, index: 0))
        XCTAssertEqual(order(), ["B", "A", "C"])

        // C down (index 2 → 2 stays at end)
        try store.dispatch(MoveNodeCommand(nodeID: c, newParentID: root, index: 2))
        XCTAssertEqual(order(), ["B", "A", "C"])

        // Undo twice → original
        try store.undo()
        try store.undo()
        XCTAssertEqual(order(), ["A", "B", "C"])
    }

    func testReorderHelperMovesByOne() {
        let store = MapStore(map: .makeEmpty(title: "T"))
        let root = NodeID(rawValue: "r")
        XCTAssertEqual(MapStore.reorderTarget(current: 0, delta: -1, count: 3), 0, "first cannot move up")
        XCTAssertEqual(MapStore.reorderTarget(current: 1, delta: -1, count: 3), 0)
        XCTAssertEqual(MapStore.reorderTarget(current: 1, delta: 1, count: 3), 2)
        XCTAssertEqual(MapStore.reorderTarget(current: 2, delta: 1, count: 3), 2, "last cannot move down")
        _ = root
        _ = store
    }

    // MARK: - Fold-all (1.2 ⌘⇧.)

    func testFoldAllBelowSelectionAsOneUndoStep() throws {
        let store = MapStore(map: .makeEmpty(title: "T"))
        let root = store.map.root.id
        let a = NodeID(rawValue: "n_a"), b = NodeID(rawValue: "n_b"), c = NodeID(rawValue: "n_c")
        try store.dispatch(InsertChildCommand(parentID: root, newNodeID: a, text: "A", side: .right))
        try store.dispatch(InsertChildCommand(parentID: a, newNodeID: b, text: "B", side: .right))
        try store.dispatch(InsertChildCommand(parentID: a, newNodeID: c, text: "C", side: .right))

        func descendantsFolded() -> Bool {
            [b, c].allSatisfy { store.map.node(id: $0)?.isFolded == true }
        }

        store.select(a)
        let ops: [MapOp] = [b, c].map { .setFolded(nodeID: $0, isFolded: true) }
        try store.dispatch(CompositeAgentCommand(ops: ops))
        XCTAssertTrue(descendantsFolded())
        let html = try HTMLCodec.encode(store.map, includeSkin: false)
        XCTAssertTrue(html.contains("data-folded=\"true\""), "fold must persist")

        try store.undo()
        XCTAssertFalse(descendantsFolded(), "one undo unfolds the whole batch")
    }
}
