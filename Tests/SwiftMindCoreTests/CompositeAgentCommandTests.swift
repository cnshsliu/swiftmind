import XCTest
@testable import SwiftMindCore

final class CompositeAgentCommandTests: XCTestCase {
    private var map: MindMap!

    override func setUp() {
        map = MindMap.makeEmpty(title: "T")
    }

    private var rootID: NodeID { map.root.id }

    func testExecutesAllOpsAndCollectsAffected() throws {
        let command = CompositeAgentCommand(ops: [
            .addChild(parentID: rootID, newNodeID: NodeID(rawValue: "n_1"), text: "One", side: .auto),
            .addChild(parentID: rootID, newNodeID: NodeID(rawValue: "n_2"), text: "Two", side: .auto),
            .setText(nodeID: rootID, text: "Renamed"),
        ])
        try command.execute(on: &map)
        XCTAssertEqual(map.root.children.count, 2)
        XCTAssertEqual(map.root.text, "Renamed")
        XCTAssertEqual(command.affected, [NodeID(rawValue: "n_1"), NodeID(rawValue: "n_2"), rootID])
    }

    func testFailureRollsBackAndThrowsBatchOpError() throws {
        let original = map!
        let command = CompositeAgentCommand(ops: [
            .addChild(parentID: rootID, newNodeID: NodeID(rawValue: "n_1"), text: "One", side: .auto),
            .setText(nodeID: NodeID(rawValue: "n_ghost"), text: "boom"),
        ])
        XCTAssertThrowsError(try command.execute(on: &map)) { error in
            guard let batchError = error as? BatchOpError else {
                return XCTFail("expected BatchOpError, got \(error)")
            }
            XCTAssertEqual(batchError.opIndex, 1)
            XCTAssertEqual(batchError.opName, "set-text")
            XCTAssertTrue(batchError.message.contains("n_ghost"))
        }
        XCTAssertEqual(map, original, "failed batch must leave the map untouched")
        XCTAssertTrue(command.affected.isEmpty, "affected only reports a successful execute")
    }

    func testBuildTimeFailureRollsBack() throws {
        let original = map!
        let command = CompositeAgentCommand(ops: [
            .addChild(parentID: rootID, newNodeID: NodeID(rawValue: "n_1"), text: "One", side: .auto),
            .setAttribute(nodeID: NodeID(rawValue: "n_ghost"), name: "k", value: ""),
        ])
        XCTAssertThrowsError(try command.execute(on: &map)) { error in
            guard let batchError = error as? BatchOpError else {
                return XCTFail("expected BatchOpError, got \(error)")
            }
            XCTAssertEqual(batchError.opIndex, 1)
            XCTAssertEqual(batchError.opName, "set-attr")
            XCTAssertTrue(batchError.message.contains("n_ghost"))
        }
        XCTAssertEqual(map, original, "build-time failure must leave the map untouched")
        XCTAssertTrue(command.affected.isEmpty)
    }

    func testUndoReversesWholeBatch() throws {
        let original = map!
        let command = CompositeAgentCommand(ops: [
            .addChild(parentID: rootID, newNodeID: NodeID(rawValue: "n_1"), text: "One", side: .auto),
            .setText(nodeID: rootID, text: "Renamed"),
        ])
        try command.execute(on: &map)
        try command.undo(on: &map)
        XCTAssertEqual(map, original)
    }

    func testStoreDispatchIsOneUndoStep() throws {
        let store = MapStore(map: MindMap.makeEmpty(title: "T"))
        let original = store.map
        let rootID = store.map.root.id
        try store.dispatch(CompositeAgentCommand(ops: [
            .addChild(parentID: rootID, newNodeID: NodeID(rawValue: "n_1"), text: "One", side: .auto),
            .addChild(parentID: rootID, newNodeID: NodeID(rawValue: "n_2"), text: "Two", side: .auto),
        ]))
        XCTAssertEqual(store.map.root.children.count, 2)
        try store.undo()
        XCTAssertEqual(store.map, original)
        XCTAssertFalse(store.canUndo)
        try store.redo()
        XCTAssertEqual(store.map.root.children.count, 2)
    }
}
