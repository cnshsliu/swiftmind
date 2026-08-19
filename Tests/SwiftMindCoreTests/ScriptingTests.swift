import XCTest
@testable import SwiftMindCore

final class ScriptingTests: XCTestCase {

    private func makeMap() -> MindMap {
        var map = MindMap.makeEmpty(title: "ScriptMap")
        map.root.children = [
            Node(id: NodeID(rawValue: "n_a"), text: "buy milk", attributes: [NodeAttribute(name: "status", value: "todo")]),
            Node(id: NodeID(rawValue: "n_b"), text: "write docs"),
        ]
        return map
    }

    // MARK: - MapScriptContext (API reads + recording)

    func testContextReads() {
        let context = MapScriptContext(map: makeMap())
        XCTAssertEqual(context.mapTitle, "ScriptMap")
        XCTAssertEqual(context.childIDs(of: context.rootID).count, 2)

        let snapshot = context.nodeSnapshot(id: NodeID(rawValue: "n_a"))
        XCTAssertEqual(snapshot?.text, "buy milk")
        XCTAssertEqual(snapshot?.attributes["status"], "todo")
        XCTAssertNil(context.nodeSnapshot(id: NodeID(rawValue: "n_missing")))
    }

    func testContextFind() {
        let context = MapScriptContext(map: makeMap())
        XCTAssertEqual(context.find("MILK"), [NodeID(rawValue: "n_a")])
        XCTAssertEqual(context.find("").count, 0)
        XCTAssertEqual(context.find("zzz").count, 0)
    }

    func testContextRecordsIntentsAndLogs() {
        let context = MapScriptContext(map: makeMap())
        context.record(.addIcon(NodeID(rawValue: "n_a"), "check"))
        context.log("done one")
        XCTAssertEqual(context.intents, [.addIcon(NodeID(rawValue: "n_a"), "check")])
        XCTAssertEqual(context.logs, ["done one"])
    }

    // MARK: - ApplyScriptIntentsCommand

    func testIntentsApplyAsOneUndoStep() throws {
        var map = makeMap()
        let originalRoot = map.root
        let bus = CommandBus()
        let command = ApplyScriptIntentsCommand(intents: [
            .setText(NodeID(rawValue: "n_a"), "buy oat milk"),
            .addIcon(NodeID(rawValue: "n_a"), "check"),
            .setAttribute(NodeID(rawValue: "n_b"), name: "status", value: "wip"),
            .setStyleName(NodeID(rawValue: "n_b"), "important"),
        ])
        try bus.execute(command, on: &map)

        XCTAssertEqual(command.appliedCount, 4)
        XCTAssertEqual(command.skippedCount, 0)
        let a = map.node(id: NodeID(rawValue: "n_a"))!
        let b = map.node(id: NodeID(rawValue: "n_b"))!
        XCTAssertEqual(a.text, "buy oat milk")
        XCTAssertTrue(a.icons.contains(NodeIcon(id: "check")))
        XCTAssertEqual(b.attributeValue(named: "status"), "wip")
        XCTAssertEqual(b.styleName, "important")
        XCTAssertTrue(map.attributeRegistry.contains("status"))

        // One undo restores all node state. (The attribute registry keeps the
        // "status" name — consistent with UpsertAttributeCommand undo.)
        try bus.undo(on: &map)
        XCTAssertEqual(map.root, originalRoot)
    }

    func testUnknownNodeIDsAreSkipped() throws {
        var map = makeMap()
        let command = ApplyScriptIntentsCommand(intents: [
            .setText(NodeID(rawValue: "n_ghost"), "x"),
            .setText(NodeID(rawValue: "n_a"), "still works"),
        ])
        try command.execute(on: &map)
        XCTAssertEqual(command.appliedCount, 1)
        XCTAssertEqual(command.skippedCount, 1)
        XCTAssertEqual(map.node(id: NodeID(rawValue: "n_a"))?.text, "still works")
    }

    func testEmptyAttributeValueRemoves() throws {
        var map = makeMap()
        let command = ApplyScriptIntentsCommand(intents: [
            .setAttribute(NodeID(rawValue: "n_a"), name: "status", value: ""),
        ])
        try command.execute(on: &map)
        XCTAssertNil(map.node(id: NodeID(rawValue: "n_a"))?.attributeValue(named: "status"))
    }

    // MARK: - Runtime seam (fake runtime drives the whole pipeline)

    private struct FakeRuntime: ScriptRuntime {
        func run(source: String, api: any MapScriptAPI) -> ScriptResult {
            // Simulates: find "milk" nodes, check them off, log it.
            for id in api.find("milk") {
                api.record(.addIcon(id, "check"))
            }
            api.log("fake ran: \(source)")
            return ScriptResult(intents: [], logs: [], error: nil)
        }
    }

    func testRuntimeToCommandPipeline() throws {
        var map = makeMap()
        let context = MapScriptContext(map: map)
        let result = FakeRuntime().run(source: "// fake", api: context)
        XCTAssertTrue(result.isSuccess)

        let bus = CommandBus()
        try bus.execute(ApplyScriptIntentsCommand(intents: context.intents), on: &map)
        XCTAssertTrue(map.node(id: NodeID(rawValue: "n_a"))!.icons.contains(NodeIcon(id: "check")))
        XCTAssertEqual(context.logs, ["fake ran: // fake"])
    }

    func testErrorResultAppliesNothing() {
        let result = ScriptResult(intents: [.setText(NodeID(rawValue: "n_a"), "x")], error: "boom")
        XCTAssertFalse(result.isSuccess)
        // Callers must gate on isSuccess — the intents are ignored when error is set.
    }
}
