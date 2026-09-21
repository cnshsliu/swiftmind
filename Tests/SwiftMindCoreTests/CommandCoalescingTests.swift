import XCTest
@testable import SwiftMindCore

/// Coalescing (spec 2026-09-21, 2c): the note editor's debounced commits all
/// carry the session key `note-edit:<nodeID>`; the bus merges them into ONE
/// undo step — first command's undo, latest command's redo.
final class CommandCoalescingTests: XCTestCase {
    private func makeStoreWithChild() throws -> (MapStore, NodeID) {
        let store = MapStore(map: .makeEmpty(title: "T"))
        let child = NodeID(rawValue: "n_coal")
        try store.dispatch(
            InsertChildCommand(parentID: store.map.root.id, newNodeID: child, text: "A", side: .right)
        )
        return (store, child)
    }

    private func noteKey(_ id: NodeID) -> String { "note-edit:\(id.rawValue)" }

    private func dispatchNote(_ store: MapStore, _ id: NodeID, _ markdown: String) throws {
        try store.dispatch(
            CompositeAgentCommand(ops: [.setNote(nodeID: id, markdown: markdown)], coalescingKey: noteKey(id))
        )
    }

    func testSameKeyCommitsMergeIntoOneUndoStep() throws {
        let (store, id) = try makeStoreWithChild()
        try dispatchNote(store, id, "one")
        try dispatchNote(store, id, "one two")
        try dispatchNote(store, id, "one two three")
        XCTAssertEqual(store.map.node(id: id)?.noteMarkdown, "one two three")

        // One ⌘Z reverts the whole session (insert-child still on the stack).
        try store.undo()
        XCTAssertEqual(store.map.node(id: id)?.noteMarkdown, "")
        XCTAssertNotNil(store.map.node(id: id), "undo must not reach the insert below the session")

        // Redo applies the LATEST burst, not the first.
        try store.redo()
        XCTAssertEqual(store.map.node(id: id)?.noteMarkdown, "one two three")
    }

    func testUnkeyedCommandBetweenBreaksCoalescing() throws {
        let (store, id) = try makeStoreWithChild()
        try dispatchNote(store, id, "one")
        try store.dispatch(SetFoldedCommand(nodeID: id, isFolded: true))
        try dispatchNote(store, id, "two")
        try store.undo()
        XCTAssertEqual(store.map.node(id: id)?.noteMarkdown, "one", "second commit is its own step")
        try store.undo()
        XCTAssertFalse(store.map.node(id: id)!.isFolded)
        try store.undo()
        XCTAssertEqual(store.map.node(id: id)?.noteMarkdown, "")
    }

    func testEndCoalescingStartsNewGroup() throws {
        let (store, id) = try makeStoreWithChild()
        try dispatchNote(store, id, "one")
        store.endCoalescing(key: noteKey(id))
        try dispatchNote(store, id, "two")
        try store.undo()
        XCTAssertEqual(store.map.node(id: id)?.noteMarkdown, "one", "post-close commit is a new step")
        try store.undo()
        XCTAssertEqual(store.map.node(id: id)?.noteMarkdown, "")
    }

    func testDifferentKeysDoNotMerge() throws {
        let store = MapStore(map: .makeEmpty(title: "T"))
        let a = NodeID(rawValue: "n_key_a")
        let b = NodeID(rawValue: "n_key_b")
        try store.dispatch(InsertChildCommand(parentID: store.map.root.id, newNodeID: a, text: "A", side: .right))
        try store.dispatch(InsertChildCommand(parentID: store.map.root.id, newNodeID: b, text: "B", side: .right))
        try store.dispatch(CompositeAgentCommand(ops: [.setNote(nodeID: a, markdown: "1")], coalescingKey: noteKey(a)))
        try store.dispatch(CompositeAgentCommand(ops: [.setNote(nodeID: b, markdown: "2")], coalescingKey: noteKey(b)))
        try store.undo()
        XCTAssertEqual(store.map.node(id: b)?.noteMarkdown, "")
        XCTAssertEqual(store.map.node(id: a)?.noteMarkdown, "1", "different keys stay separate steps")
    }

    func testEndCoalescingOnUnknownKeyIsNoOp() throws {
        let (store, id) = try makeStoreWithChild()
        try dispatchNote(store, id, "one")
        store.endCoalescing(key: "note-edit:nobody")
        try dispatchNote(store, id, "two")
        try store.undo()
        XCTAssertEqual(store.map.node(id: id)?.noteMarkdown, "", "group stayed open for the real key")
    }

    func testUndoOrderAcrossGroupBoundary() throws {
        let (store, id) = try makeStoreWithChild()
        try dispatchNote(store, id, "one")
        store.endCoalescing(key: noteKey(id))
        try dispatchNote(store, id, "two")
        try dispatchNote(store, id, "three")
        // New group coalesced: undo → "one", undo → "", undo → child insert gone.
        try store.undo()
        XCTAssertEqual(store.map.node(id: id)?.noteMarkdown, "one")
        try store.undo()
        XCTAssertEqual(store.map.node(id: id)?.noteMarkdown, "")
        try store.undo()
        XCTAssertNil(store.map.node(id: id))
        XCTAssertFalse(store.canUndo)
    }
}
