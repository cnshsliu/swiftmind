import XCTest
@testable import SwiftMindCore

final class HTMLCodecTests: XCTestCase {
    func testRoundTripPreservesTreeAndStyle() throws {
        var map = MindMap.makeEmpty(title: "Roadmap")
        let bus = CommandBus()
        try bus.execute(
            InsertChildCommand(parentID: map.root.id, newNodeID: NodeID(rawValue: "n_a"), text: "Alpha", side: .right),
            on: &map
        )
        try bus.execute(
            InsertChildCommand(parentID: NodeID(rawValue: "n_a"), newNodeID: NodeID(rawValue: "n_b"), text: "Beta", side: .right),
            on: &map
        )
        map.updateNode(id: NodeID(rawValue: "n_a")) {
            $0.isFolded = true
            $0.style = NodeStyle(fontSize: 16, isBold: true, textRed: 0.1, textGreen: 0.2, textBlue: 0.3, fillRed: 0.9, fillGreen: 0.9, fillBlue: 1.0)
        }

        let html = try HTMLCodec.encode(map, includeSkin: false)
        XCTAssertTrue(html.contains("data-schema=\"1\""))
        XCTAssertTrue(html.contains("n_a"))
        XCTAssertTrue(html.contains("Alpha"))

        let decoded = try HTMLCodec.decode(html)
        XCTAssertEqual(decoded.title, "Roadmap")
        XCTAssertEqual(decoded.root.children.count, 1)
        XCTAssertEqual(decoded.root.children[0].id.rawValue, "n_a")
        XCTAssertEqual(decoded.root.children[0].text, "Alpha")
        XCTAssertTrue(decoded.root.children[0].isFolded)
        XCTAssertEqual(decoded.root.children[0].children[0].text, "Beta")
        XCTAssertEqual(decoded.root.children[0].style.fontSize, 16, accuracy: 0.001)
        XCTAssertTrue(decoded.root.children[0].style.isBold)
        // color accuracy within 1/255
        XCTAssertEqual(decoded.root.children[0].style.textRed, 0.1, accuracy: 0.01)
    }

    func testDecodeRejectsUnknownDocument() {
        XCTAssertThrowsError(try HTMLCodec.decode("<html><body>hi</body></html>"))
    }

    func testEncodeWithSkinEmbedsReadOnlyCSS() throws {
        let map = MindMap.makeEmpty(title: "Skin Check")
        let html = try HTMLCodec.encode(map, includeSkin: true)
        XCTAssertTrue(html.contains("<style>"))
        XCTAssertTrue(html.contains(".node-title"))
        XCTAssertTrue(html.contains(".swiftmind-map"))
        XCTAssertTrue(html.contains("list-style: none"))
    }

    func testGoldenFixtureDecodesAndMatchesStructure() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "minimal",
                withExtension: "swiftmind.html",
                subdirectory: "Fixtures"
            )
        )
        let html = try String(contentsOf: url, encoding: .utf8)

        // Browser skin present for manual open verification.
        XCTAssertTrue(html.contains("<style>"))
        XCTAssertTrue(html.contains(".node-title"))
        XCTAssertTrue(html.contains("Central Idea"))
        XCTAssertTrue(html.contains("Alpha"))
        XCTAssertTrue(html.contains("Beta"))
        XCTAssertTrue(html.contains("Gamma"))

        let decoded = try HTMLCodec.decode(html)
        XCTAssertEqual(decoded.title, "Minimal Map")
        XCTAssertEqual(decoded.id, "m_minimal_fixture")
        XCTAssertEqual(decoded.root.id.rawValue, "n_root")
        XCTAssertEqual(decoded.root.text, "Central Idea")
        XCTAssertEqual(decoded.root.children.count, 2)
        XCTAssertEqual(decoded.root.children[0].text, "Alpha")
        XCTAssertEqual(decoded.root.children[0].side, .right)
        XCTAssertEqual(decoded.root.children[0].children[0].text, "Beta")
        XCTAssertEqual(decoded.root.children[1].text, "Gamma")
        XCTAssertEqual(decoded.root.children[1].side, .left)

        // Re-encode with skin should keep round-trippable structure.
        let reencoded = try HTMLCodec.encode(decoded, includeSkin: true)
        let again = try HTMLCodec.decode(reencoded)
        XCTAssertEqual(again, decoded)
    }

    func testRoundTripNoteLinksIconsPin() throws {
        var map = MindMap.makeEmpty(title: "N")
        let bus = CommandBus()
        let child = NodeID(rawValue: "n_c")
        try bus.execute(
            InsertChildCommand(parentID: map.root.id, newNodeID: child, text: "C", side: .right),
            on: &map
        )
        try bus.execute(SetNoteCommand(nodeID: child, noteMarkdown: "line1\n**bold**"), on: &map)
        try bus.execute(
            SetLinksCommand(nodeID: child, links: [
                .url(URL(string: "https://example.com")!),
                .node(map.root.id),
            ]),
            on: &map
        )
        try bus.execute(SetIconsCommand(nodeID: child, icons: [.builtin("star")]), on: &map)
        try bus.execute(SetPinCommand(nodeID: child, positionPin: Point2D(x: 10, y: 20)), on: &map)

        let html = try HTMLCodec.encode(map, includeSkin: true)
        XCTAssertTrue(html.contains("node-note"))
        XCTAssertTrue(html.contains("data-icons=\"star\""))
        XCTAssertTrue(html.contains("data-pin-x"))
        XCTAssertTrue(html.contains("data-schema=\"1\""))
        XCTAssertTrue(html.contains(".node-note[hidden]"))

        let decoded = try HTMLCodec.decode(html)
        let n = try XCTUnwrap(decoded.node(id: child))
        XCTAssertEqual(n.noteMarkdown, "line1\n**bold**")
        XCTAssertEqual(n.links.count, 2)
        XCTAssertEqual(n.links[0], .url(URL(string: "https://example.com")!))
        XCTAssertEqual(n.links[1], .node(map.root.id))
        XCTAssertEqual(n.icons.map(\.id), ["star"])
        XCTAssertEqual(n.positionPin?.x ?? -1, 10, accuracy: 0.001)
        XCTAssertEqual(n.positionPin?.y ?? -1, 20, accuracy: 0.001)
        // Root (no M2 fields written) still defaults.
        XCTAssertEqual(decoded.root.noteMarkdown, "")
        XCTAssertTrue(decoded.root.links.isEmpty)
        XCTAssertTrue(decoded.root.icons.isEmpty)
        XCTAssertNil(decoded.root.positionPin)
    }

    func testNoteExpandedRoundTrip() throws {
        var map = MindMap.makeEmpty(title: "T")
        let bus = CommandBus()
        try bus.execute(
            InsertChildCommand(parentID: map.root.id, newNodeID: NodeID(rawValue: "n_x"), text: "X", side: .right),
            on: &map
        )

        // Default false: attribute is not emitted at all (old files byte-compatible).
        var html = try HTMLCodec.encode(map, includeSkin: false)
        XCTAssertFalse(html.contains("data-note-expanded"))

        map.updateNode(id: NodeID(rawValue: "n_x")) { $0.isNoteExpanded = true }
        html = try HTMLCodec.encode(map, includeSkin: false)
        XCTAssertTrue(html.contains("data-note-expanded=\"true\""))

        let decoded = try HTMLCodec.decode(html)
        XCTAssertTrue(decoded.root.children[0].isNoteExpanded)
    }

    func testLegacyM1HTMLStillDecodes() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "minimal",
                withExtension: "swiftmind.html",
                subdirectory: "Fixtures"
            )
        )
        let map = try HTMLCodec.decode(String(contentsOf: url, encoding: .utf8))
        XCTAssertFalse(map.root.text.isEmpty)
        XCTAssertEqual(map.root.noteMarkdown, "")
        XCTAssertTrue(map.root.links.isEmpty)
        XCTAssertTrue(map.root.icons.isEmpty)
        XCTAssertNil(map.root.positionPin)
        XCTAssertEqual(map.root.children.count, 2)
    }

    func testDataUriImageNoteRoundTrip() throws {
        var map = MindMap.makeEmpty(title: "IMG")
        let child = NodeID(rawValue: "n_img")
        var working = map
        try InsertChildCommand(parentID: map.root.id, newNodeID: child, text: "Pic", side: .right)
            .execute(on: &working)
        // Data-URI image + LaTeX in one note: base64 and $ survive the
        // escaped-text codec path unchanged.
        let note = "![pasted](data:image/png;base64,iVBORw0KGgoAAAANSUhEUg==)\n\n$e^{i\\pi}$"
        try SetNoteCommand(nodeID: child, noteMarkdown: note).execute(on: &working)
        map = working

        let html = try HTMLCodec.encode(map, includeSkin: false)
        let decoded = try HTMLCodec.decode(html)
        XCTAssertEqual(decoded.node(id: child)?.noteMarkdown, note)
    }
}
