import XCTest
@testable import SwiftMindCore

final class ConditionalStyleRuleTests: XCTestCase {

    // MARK: - Matching

    func testHasIconMatches() {
        let rule = ConditionalStyleRule(condition: .hasIcon("check"), styleName: "note")
        let done = Node(text: "a", icons: [NodeIcon(id: "check")])
        let open = Node(text: "b")
        XCTAssertTrue(rule.matches(done))
        XCTAssertFalse(rule.matches(open))
    }

    func testAttributeEqualsMatches() {
        let rule = ConditionalStyleRule(condition: .attributeEquals(name: "status", value: "done"), styleName: "note")
        let done = Node(text: "a", attributes: [NodeAttribute(name: "status", value: "done")])
        let other = Node(text: "b", attributes: [NodeAttribute(name: "status", value: "wip")])
        let missing = Node(text: "c")
        XCTAssertTrue(rule.matches(done))
        XCTAssertFalse(rule.matches(other))
        XCTAssertFalse(rule.matches(missing))
    }

    // MARK: - Resolver

    func testRuleLayersOverNamedStyle() {
        var sheet = StyleSheet.defaultSheet
        sheet.rules = [ConditionalStyleRule(condition: .hasIcon("check"), styleName: "note")]
        let node = Node(text: "a", icons: [NodeIcon(id: "check")])

        let resolved = StyleResolver.resolve(node: node, sheet: sheet)
        let noteStyle = sheet.style(named: "note")!
        XCTAssertEqual(resolved.fontSize, noteStyle.fontSize)
        XCTAssertEqual(resolved.textRed, noteStyle.textRed)
    }

    func testNonMatchingRuleLeavesStyleAlone() {
        var sheet = StyleSheet.defaultSheet
        sheet.rules = [ConditionalStyleRule(condition: .hasIcon("check"), styleName: "note")]
        let node = Node(text: "a")

        XCTAssertEqual(StyleResolver.resolve(node: node, sheet: sheet), NodeStyle.default)
    }

    func testLocalStyleStillWinsOverRule() {
        var sheet = StyleSheet.defaultSheet
        sheet.rules = [ConditionalStyleRule(condition: .hasIcon("check"), styleName: "note")]
        var node = Node(text: "a", icons: [NodeIcon(id: "check")])
        node.style.fontSize = 22 // local override

        let resolved = StyleResolver.resolve(node: node, sheet: sheet)
        XCTAssertEqual(resolved.fontSize, 22)
    }

    func testLaterRuleLayersOverEarlier() {
        var sheet = StyleSheet.defaultSheet
        sheet.rules = [
            ConditionalStyleRule(condition: .hasIcon("check"), styleName: "note"),
            ConditionalStyleRule(condition: .hasIcon("check"), styleName: "important"),
        ]
        let node = Node(text: "a", icons: [NodeIcon(id: "check")])

        let resolved = StyleResolver.resolve(node: node, sheet: sheet)
        // Later rule's fill layers over the earlier rule (note has no fill).
        XCTAssertEqual(resolved.fillRed, sheet.style(named: "important")!.fillRed)
        // Merge semantics: an overlay field equal to NodeStyle.default counts as
        // "unset" (same rule as named-style overlays), so important's fontSize 14
        // does not erase note's 12. Documented behavior, not an accident.
        XCTAssertEqual(resolved.fontSize, sheet.style(named: "note")!.fontSize)
    }

    func testRuleWithUnknownStyleNameIsIgnored() {
        var sheet = StyleSheet.defaultSheet
        sheet.rules = [ConditionalStyleRule(condition: .hasIcon("check"), styleName: "ghost")]
        let node = Node(text: "a", icons: [NodeIcon(id: "check")])
        XCTAssertEqual(StyleResolver.resolve(node: node, sheet: sheet), NodeStyle.default)
    }

    // MARK: - Command

    func testSetStyleRulesAndUndo() throws {
        var map = MindMap.makeEmpty(title: "T")
        let bus = CommandBus()
        let rule = ConditionalStyleRule(condition: .hasIcon("check"), styleName: "note")

        try bus.execute(SetStyleRulesCommand(rules: [rule]), on: &map)
        XCTAssertEqual(map.styleSheet.rules, [rule])

        try bus.undo(on: &map)
        XCTAssertTrue(map.styleSheet.rules.isEmpty)

        try bus.redo(on: &map)
        XCTAssertEqual(map.styleSheet.rules, [rule])
    }

    // MARK: - HTML round-trip

    func testRulesRoundTripThroughHTML() throws {
        var map = MindMap.makeEmpty(title: "T")
        map.styleSheet.rules = [
            ConditionalStyleRule(id: "r1", condition: .hasIcon("check"), styleName: "note"),
            ConditionalStyleRule(id: "r2", condition: .attributeEquals(name: "status", value: "done"), styleName: "important"),
        ]

        let html = try HTMLCodec.encode(map, includeSkin: false)
        XCTAssertTrue(html.contains("class=\"style-rules\""))

        let decoded = try HTMLCodec.decode(html)
        XCTAssertEqual(decoded.styleSheet.rules, map.styleSheet.rules)
        // Named style templates remain the built-in defaults.
        XCTAssertEqual(decoded.styleSheet.styles, StyleSheet.defaultSheet.styles)
    }

    func testLegacyHTMLWithoutRulesDecodesEmpty() throws {
        let map = MindMap.makeEmpty(title: "T")
        let decoded = try HTMLCodec.decode(HTMLCodec.encode(map, includeSkin: false))
        XCTAssertTrue(decoded.styleSheet.rules.isEmpty)
    }

    // MARK: - Layout integration

    func testLayoutUsesRuleResolvedStyle() {
        var map = MindMap.makeEmpty(title: "T")
        map.styleSheet.rules = [
            ConditionalStyleRule(condition: .attributeEquals(name: "status", value: "done"), styleName: "important")
        ]
        let child = Node(
            id: NodeID(rawValue: "n_done"),
            text: "Task",
            attributes: [NodeAttribute(name: "status", value: "done")]
        )
        map.root.children = [child]

        let snapshot = LayoutEngine().layout(map: map, selection: SelectionState())
        let visual = snapshot.nodes.first { $0.id == child.id }
        let important = StyleSheet.defaultSheet.style(named: "important")!
        XCTAssertEqual(visual?.style.fillRed, important.fillRed)
    }
}
