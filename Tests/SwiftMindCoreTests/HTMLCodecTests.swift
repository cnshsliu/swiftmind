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
}
