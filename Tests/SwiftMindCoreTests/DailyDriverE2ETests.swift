import XCTest
@testable import SwiftMindCore

/// End-to-end workflows a daily-driver user cares about (model + codec + layout + search).
final class DailyDriverE2ETests: XCTestCase {

    func testBuildMapNotePinSearchAndHTMLRoundTrip() throws {
        var map = MindMap.makeEmpty(title: "Launch Plan")
        let bus = CommandBus()
        let root = map.root.id

        let product = NodeID(rawValue: "n_product")
        let eng = NodeID(rawValue: "n_eng")
        let design = NodeID(rawValue: "n_design")

        try bus.execute(InsertChildCommand(parentID: root, newNodeID: product, text: "Product", side: .right), on: &map)
        try bus.execute(InsertChildCommand(parentID: root, newNodeID: eng, text: "Engineering", side: .left), on: &map)
        try bus.execute(InsertChildCommand(parentID: product, newNodeID: design, text: "Design review", side: .right), on: &map)

        try bus.execute(SetNoteCommand(nodeID: design, noteMarkdown: "Ship **v1** mockups by Friday"), on: &map)
        try bus.execute(SetIconsCommand(nodeID: design, icons: [.builtin("star"), .builtin("todo")]), on: &map)
        try bus.execute(
            SetLinksCommand(nodeID: product, links: [.url(URL(string: "https://example.com/spec")!)]),
            on: &map
        )
        try bus.execute(SetPinCommand(nodeID: eng, positionPin: Point2D(x: -220, y: 40)), on: &map)
        try bus.execute(SetFoldedCommand(nodeID: product, isFolded: true), on: &map)

        // Search finds title and note.
        let titleHits = MapSearch.search(map: map, query: "Engineering")
        XCTAssertEqual(titleHits.map(\.nodeID), [eng])

        let noteHits = MapSearch.search(map: map, query: "mockups")
        XCTAssertEqual(noteHits.count, 1)
        XCTAssertEqual(noteHits[0].nodeID, design)
        XCTAssertTrue(noteHits[0].matchInNote)

        // Layout: pin honored; folded hides design.
        let snap = LayoutEngine().layout(map: map)
        let engV = try XCTUnwrap(snap.nodes.first { $0.id == eng })
        XCTAssertEqual(engV.frame.midX, -220, accuracy: 0.5)
        XCTAssertTrue(engV.isPinned)
        XCTAssertNil(snap.nodes.first { $0.id == design })
        XCTAssertNotNil(snap.nodes.first { $0.id == product })

        // HTML round-trip preserves daily-driver fields.
        let html = try HTMLCodec.encode(map, includeSkin: true)
        XCTAssertTrue(html.contains("prefers-color-scheme"))
        XCTAssertTrue(html.contains("data-icons=\"star,todo\""))
        XCTAssertTrue(html.contains("node-note"))

        let decoded = try HTMLCodec.decode(html)
        XCTAssertEqual(decoded.title, "Launch Plan")
        XCTAssertEqual(decoded.root.children.count, 2)
        let d = try XCTUnwrap(decoded.node(id: design))
        XCTAssertEqual(d.noteMarkdown, "Ship **v1** mockups by Friday")
        XCTAssertEqual(d.icons.map(\.id), ["star", "todo"])
        let p = try XCTUnwrap(decoded.node(id: product))
        XCTAssertEqual(p.links.count, 1)
        let e = try XCTUnwrap(decoded.node(id: eng))
        let pinX = try XCTUnwrap(e.positionPin?.x)
        XCTAssertEqual(pinX, -220, accuracy: 0.001)
        XCTAssertTrue(try XCTUnwrap(decoded.node(id: product)).isFolded)
    }

    func testMapStoreSessionWorkflowUndo() throws {
        let store = MapStore(map: MindMap.makeEmpty(title: "Session"))
        let root = store.map.root.id
        try store.dispatch(InsertChildCommand(parentID: root, text: "Alpha", side: .right))
        let alpha = store.map.root.children[0].id
        XCTAssertEqual(store.selection.primary, alpha)

        try store.dispatch(SetTextCommand(nodeID: alpha, newText: "Alpha shipped"))
        try store.dispatch(SetNoteCommand(nodeID: alpha, noteMarkdown: "done"))
        XCTAssertEqual(store.map.node(id: alpha)?.text, "Alpha shipped")

        try store.undo() // note
        XCTAssertEqual(store.map.node(id: alpha)?.noteMarkdown, "")
        try store.undo() // text
        XCTAssertEqual(store.map.node(id: alpha)?.text, "Alpha")
        try store.redo()
        XCTAssertEqual(store.map.node(id: alpha)?.text, "Alpha shipped")
    }

    func testRootDefaultStyleIsAccentFilled() {
        let map = MindMap.makeEmpty(title: "T")
        XCTAssertEqual(map.root.style.fontSize, 22)
        XCTAssertTrue(map.root.style.isBold)
        // Sentinel fill so UI can paint live system Accent; light text for contrast.
        XCTAssertNotNil(map.root.style.fillBlue)
        XCTAssertGreaterThan(map.root.style.textRed, 0.9)
    }
}
