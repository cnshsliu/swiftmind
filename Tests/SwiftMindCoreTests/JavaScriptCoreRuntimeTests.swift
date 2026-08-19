import XCTest
@testable import SwiftMindCore

final class JavaScriptCoreRuntimeTests: XCTestCase {

    private func makeContext() -> MapScriptContext {
        var map = MindMap.makeEmpty(title: "JSMap")
        map.root.children = [
            Node(id: NodeID(rawValue: "n_a"), text: "task one", attributes: [NodeAttribute(name: "status", value: "todo")]),
            Node(id: NodeID(rawValue: "n_b"), text: "task two"),
        ]
        return MapScriptContext(map: map)
    }

    // MARK: - Reads

    func testReadAPI() {
        let context = makeContext()
        let result = JavaScriptCoreRuntime().run(source: """
            mindmap.log(mindmap.title());
            mindmap.log(mindmap.children(mindmap.rootId()).length);
            var n = mindmap.node("n_a");
            mindmap.log(n.text + "|" + n.attrs.status);
            mindmap.log(mindmap.node("n_missing") === null ? "null-ok" : "bad");
            mindmap.log(mindmap.find("TASK").length);
        """, api: context)
        XCTAssertNil(result.error)
        XCTAssertEqual(context.logs, ["JSMap", "2", "task one|todo", "null-ok", "2"])
    }

    // MARK: - Intents

    func testIntentsRecordedFromJS() {
        let context = makeContext()
        let result = JavaScriptCoreRuntime().run(source: """
            mindmap.find("task").forEach(function(id) { mindmap.addIcon(id, "check"); });
            mindmap.setText("n_a", "task one done");
            mindmap.setAttr("n_b", "status", "wip");
            mindmap.setStyle("n_a", "important");
            mindmap.setStyle("n_b", "");
        """, api: context)
        XCTAssertNil(result.error)
        XCTAssertEqual(context.intents, [
            .addIcon(NodeID(rawValue: "n_a"), "check"),
            .addIcon(NodeID(rawValue: "n_b"), "check"),
            .setText(NodeID(rawValue: "n_a"), "task one done"),
            .setAttribute(NodeID(rawValue: "n_b"), name: "status", value: "wip"),
            .setStyleName(NodeID(rawValue: "n_a"), "important"),
            .setStyleName(NodeID(rawValue: "n_b"), nil),
        ])
    }

    // MARK: - Errors

    func testThrowingScriptReportsError() {
        let context = makeContext()
        let result = JavaScriptCoreRuntime().run(source: """
            mindmap.addIcon("n_a", "check");
            throw new Error("boom");
        """, api: context)
        XCTAssertNotNil(result.error)
        // Caller gates on error: intents from the failed run are discarded.
        XCTAssertEqual(context.intents.count, 1) // recorded but must not be applied
    }

    func testSyntaxErrorReportsError() {
        let context = makeContext()
        let result = JavaScriptCoreRuntime().run(source: "var x = {", api: context)
        XCTAssertNotNil(result.error)
    }

    // MARK: - Sandbox

    func testNoRequireOrFileAccess() {
        let context = makeContext()
        let result = JavaScriptCoreRuntime().run(source: """
            mindmap.log(typeof require);
            mindmap.log(typeof fetch);
            mindmap.log(typeof process);
        """, api: context)
        XCTAssertNil(result.error)
        XCTAssertEqual(context.logs, ["undefined", "undefined", "undefined"])
    }

    func testRunawayScriptTimesOut() {
        let context = makeContext()
        let start = Date()
        let result = JavaScriptCoreRuntime().run(source: "while (true) {}", api: context, timeout: 1)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertNotNil(result.error)
        XCTAssertTrue(result.error!.contains("timed out"))
        XCTAssertLessThan(elapsed, 5)
    }

    // MARK: - Full pipeline through MapStore

    func testScriptToMapViaStore() throws {
        var map = MindMap.makeEmpty(title: "JSMap")
        map.root.children = [Node(id: NodeID(rawValue: "n_a"), text: "task one")]
        let store = MapStore(map: map)

        let context = MapScriptContext(map: store.map)
        let result = JavaScriptCoreRuntime().run(
            source: "mindmap.find('task').forEach(function(id) { mindmap.addIcon(id, 'check'); });",
            api: context
        )
        XCTAssertNil(result.error)

        try store.dispatch(ApplyScriptIntentsCommand(intents: context.intents))
        XCTAssertTrue(store.map.node(id: NodeID(rawValue: "n_a"))!.icons.contains(NodeIcon(id: "check")))
        try store.undo()
        XCTAssertFalse(store.map.node(id: NodeID(rawValue: "n_a"))!.icons.contains(NodeIcon(id: "check")))
        map = store.map // silence never-mutated warning
        _ = map
    }
}
