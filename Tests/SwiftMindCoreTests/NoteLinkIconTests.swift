import XCTest
@testable import SwiftMindCore

final class NoteLinkIconTests: XCTestCase {
    func testNodeDefaultsHaveEmptyNoteLinksIcons() {
        let n = Node(text: "Hi")
        XCTAssertEqual(n.noteMarkdown, "")
        XCTAssertTrue(n.links.isEmpty)
        XCTAssertTrue(n.icons.isEmpty)
    }

    func testNodeLinkEqualityAndKinds() {
        let url = NodeLink.url(URL(string: "https://example.com")!)
        let node = NodeLink.node(NodeID(rawValue: "n_x"))
        XCTAssertNotEqual(url, node)
        XCTAssertEqual(url, NodeLink.url(URL(string: "https://example.com")!))
    }

    func testIconRefBuiltin() {
        let icon = IconRef.builtin("flag")
        XCTAssertEqual(icon.id, "flag")
        XCTAssertTrue(IconRef.catalog.contains(where: { $0.id == "check" }))
        XCTAssertTrue(IconRef.catalog.contains(where: { $0.id == "flag" }))
    }
}
