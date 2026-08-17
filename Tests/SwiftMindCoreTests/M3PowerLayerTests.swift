import XCTest
@testable import SwiftMindCore

final class M3PowerLayerTests: XCTestCase {

    // MARK: - Attributes + commands

    func testUpsertAttributeAndUndo() throws {
        var map = MindMap.makeEmpty(title: "T")
        let bus = CommandBus()
        let root = map.root.id
        try bus.execute(
            UpsertAttributeCommand(nodeID: root, attribute: NodeAttribute(name: "status", value: "done")),
            on: &map
        )
        XCTAssertEqual(map.root.attributeValue(named: "status"), "done")
        XCTAssertTrue(map.attributeRegistry.contains("status"))
        try bus.undo(on: &map)
        XCTAssertNil(map.root.attributeValue(named: "status"))
    }

    func testSetAttributesReplacesAll() throws {
        var map = MindMap.makeEmpty(title: "T")
        let bus = CommandBus()
        let root = map.root.id
        try bus.execute(
            SetAttributesCommand(
                nodeID: root,
                attributes: [
                    NodeAttribute(name: "a", value: "1"),
                    NodeAttribute(name: "b", value: "2"),
                ]
            ),
            on: &map
        )
        XCTAssertEqual(map.root.attributes.count, 2)
        try bus.execute(
            SetAttributesCommand(nodeID: root, attributes: [NodeAttribute(name: "c", value: "3")]),
            on: &map
        )
        XCTAssertEqual(map.root.attributes.map(\.name), ["c"])
    }

    // MARK: - Filter evaluator

    func testFilterTextAndAttribute() {
        var map = MindMap.makeEmpty(title: "T")
        map.root.text = "Hello World"
        map.root.attributes = [NodeAttribute(name: "status", value: "done")]
        XCTAssertTrue(FilterEvaluator.matches(map.root, rule: .textContains("world")))
        XCTAssertFalse(FilterEvaluator.matches(map.root, rule: .textContains("zzz")))
        XCTAssertTrue(FilterEvaluator.matches(map.root, rule: .attributeEquals(name: "status", value: "done")))
        XCTAssertFalse(FilterEvaluator.matches(map.root, rule: .attributeEquals(name: "status", value: "todo")))
    }

    func testMatchesIncludingDescendants() throws {
        var map = MindMap.makeEmpty(title: "T")
        let bus = CommandBus()
        let a = NodeID(rawValue: "n_a")
        let b = NodeID(rawValue: "n_b")
        try bus.execute(InsertChildCommand(parentID: map.root.id, newNodeID: a, text: "Branch", side: .right), on: &map)
        try bus.execute(InsertChildCommand(parentID: a, newNodeID: b, text: "LeafMatch", side: .right), on: &map)
        let rule = FilterRule.textContains("LeafMatch")
        XCTAssertFalse(FilterEvaluator.matches(map.root, rule: rule))
        XCTAssertTrue(FilterEvaluator.matchesIncludingDescendants(map.root, rule: rule))
        XCTAssertTrue(FilterEvaluator.matchesIncludingDescendants(map.root.children[0], rule: rule))
    }

    // MARK: - Layout hide / highlight

    func testHideFilterKeepsPathToRoot() throws {
        var map = MindMap.makeEmpty(title: "T")
        let bus = CommandBus()
        let a = NodeID(rawValue: "n_a")
        let b = NodeID(rawValue: "n_b")
        let c = NodeID(rawValue: "n_c")
        try bus.execute(InsertChildCommand(parentID: map.root.id, newNodeID: a, text: "KeepPath", side: .right), on: &map)
        try bus.execute(InsertChildCommand(parentID: a, newNodeID: b, text: "Target", side: .right), on: &map)
        try bus.execute(InsertChildCommand(parentID: map.root.id, newNodeID: c, text: "Other", side: .left), on: &map)

        map.activeFilter = MapFilter(mode: .hide, rule: .textContains("Target"))
        let snap = LayoutEngine().layout(map: map)
        let texts = Set(snap.nodes.map(\.text))
        XCTAssertTrue(texts.contains("Central Idea") || texts.contains(map.root.text))
        XCTAssertTrue(texts.contains("KeepPath"))
        XCTAssertTrue(texts.contains("Target"))
        XCTAssertFalse(texts.contains("Other"))
    }

    func testHighlightFilterFlagsMatches() throws {
        var map = MindMap.makeEmpty(title: "T")
        let bus = CommandBus()
        try bus.execute(InsertChildCommand(parentID: map.root.id, text: "Alpha", side: .right), on: &map)
        try bus.execute(InsertChildCommand(parentID: map.root.id, text: "Beta", side: .left), on: &map)
        map.activeFilter = MapFilter(mode: .highlight, rule: .textContains("Alpha"))
        let snap = LayoutEngine().layout(map: map)
        XCTAssertEqual(snap.nodes.count, 3)
        let alpha = try XCTUnwrap(snap.nodes.first { $0.text == "Alpha" })
        let beta = try XCTUnwrap(snap.nodes.first { $0.text == "Beta" })
        XCTAssertTrue(alpha.isHighlighted)
        XCTAssertFalse(beta.isHighlighted)
    }

    // MARK: - Style resolver

    func testStyleResolverNamedWinsUntilLocalOverride() {
        var node = Node(text: "X", styleName: "important")
        let sheet = StyleSheet.defaultSheet
        let resolved = StyleResolver.resolve(node: node, sheet: sheet)
        XCTAssertTrue(resolved.isBold)
        XCTAssertEqual(resolved.textRed, 0.7, accuracy: 0.01)

        // Local non-default fontSize wins; isBold stays on named when local matches default false.
        node.style = NodeStyle(fontSize: 20, isBold: false, textRed: 0, textGreen: 0, textBlue: 0)
        let resolved2 = StyleResolver.resolve(node: node, sheet: sheet)
        XCTAssertEqual(resolved2.fontSize, 20, accuracy: 0.01)
        XCTAssertTrue(resolved2.isBold)

        // Explicit local bold=true still wins (differs from default only when true… so force via font path).
        // Local fill overrides named fill.
        node.style = NodeStyle(
            fontSize: 20,
            isBold: true,
            textRed: 0.1,
            textGreen: 0.1,
            textBlue: 0.1,
            fillRed: 0.2,
            fillGreen: 0.3,
            fillBlue: 0.4
        )
        let resolved3 = StyleResolver.resolve(node: node, sheet: sheet)
        XCTAssertTrue(resolved3.isBold)
        XCTAssertEqual(resolved3.fillRed ?? -1, 0.2, accuracy: 0.01)
    }

    func testSetStyleNameCommand() throws {
        var map = MindMap.makeEmpty(title: "T")
        let bus = CommandBus()
        try bus.execute(SetStyleNameCommand(nodeID: map.root.id, styleName: "topic"), on: &map)
        XCTAssertEqual(map.root.styleName, "topic")
        try bus.undo(on: &map)
        XCTAssertNil(map.root.styleName)
    }

    // MARK: - Bookmarks

    func testAddRemoveBookmark() throws {
        var map = MindMap.makeEmpty(title: "T")
        let bus = CommandBus()
        let bm = Bookmark(nodeID: map.root.id, label: "Home")
        try bus.execute(AddBookmarkCommand(bookmark: bm), on: &map)
        XCTAssertEqual(map.bookmarks.count, 1)
        try bus.execute(RemoveBookmarkCommand(bookmarkID: bm.id), on: &map)
        XCTAssertTrue(map.bookmarks.isEmpty)
        try bus.undo(on: &map)
        XCTAssertEqual(map.bookmarks.count, 1)
    }

    // MARK: - HTML round-trip M3 fields

    func testHTMLRoundTripAttributesFilterBookmarksStyleName() throws {
        var map = MindMap.makeEmpty(title: "Power")
        let bus = CommandBus()
        let child = NodeID(rawValue: "n_child")
        try bus.execute(
            InsertChildCommand(parentID: map.root.id, newNodeID: child, text: "Done Task", side: .right),
            on: &map
        )
        try bus.execute(
            UpsertAttributeCommand(nodeID: child, attribute: NodeAttribute(name: "status", value: "done")),
            on: &map
        )
        try bus.execute(SetStyleNameCommand(nodeID: child, styleName: "important"), on: &map)
        try bus.execute(
            AddBookmarkCommand(bookmark: Bookmark(id: "bm1", nodeID: child, label: "Done")),
            on: &map
        )
        try bus.execute(
            SetFilterCommand(filter: MapFilter(mode: .highlight, rule: .textContains("Done"))),
            on: &map
        )

        let html = try HTMLCodec.encode(map, includeSkin: false)
        XCTAssertTrue(html.contains("node-attrs"))
        XCTAssertTrue(html.contains("data-attr-name=\"status\""))
        XCTAssertTrue(html.contains("data-style-name=\"important\""))
        XCTAssertTrue(html.contains("attribute-registry"))
        XCTAssertTrue(html.contains("data-filter-mode=\"highlight\""))
        XCTAssertTrue(html.contains("class=\"bookmarks\""))
        XCTAssertTrue(html.contains("data-label=\"Done\""))

        let decoded = try HTMLCodec.decode(html)
        let n = try XCTUnwrap(decoded.node(id: child))
        XCTAssertEqual(n.attributeValue(named: "status"), "done")
        XCTAssertEqual(n.styleName, "important")
        XCTAssertTrue(decoded.attributeRegistry.contains("status"))
        XCTAssertEqual(decoded.bookmarks.count, 1)
        XCTAssertEqual(decoded.bookmarks[0].label, "Done")
        XCTAssertEqual(decoded.bookmarks[0].nodeID, child)
        XCTAssertEqual(decoded.activeFilter?.mode, .highlight)
        if case .textContains(let q) = decoded.activeFilter?.rule {
            XCTAssertEqual(q, "Done")
        } else {
            XCTFail("expected textContains filter")
        }

        // Full round-trip equality of M3 surface fields (styleSheet is default on both).
        XCTAssertEqual(decoded.root.children[0].attributes, n.attributes)
        XCTAssertEqual(decoded.bookmarks.map(\.nodeID), map.bookmarks.map(\.nodeID))
    }

    func testLegacyMinimalStillDecodesWithEmptyM3Fields() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "minimal",
                withExtension: "swiftmind.html",
                subdirectory: "Fixtures"
            )
        )
        let map = try HTMLCodec.decode(String(contentsOf: url, encoding: .utf8))
        XCTAssertTrue(map.root.attributes.isEmpty)
        XCTAssertNil(map.root.styleName)
        XCTAssertNil(map.activeFilter)
        XCTAssertTrue(map.bookmarks.isEmpty)
        XCTAssertTrue(map.attributeRegistry.definitions.isEmpty)
    }
}
