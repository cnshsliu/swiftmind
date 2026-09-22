import XCTest
@testable import SwiftMindCore

final class MarkdownDocumentTests: XCTestCase {
    func testParagraphIsLiteralText() {
        let source = "Ship Friday."
        let doc = MarkdownDocument.parse(source)
        XCTAssertEqual(doc.blocks.count, 1)
        XCTAssertEqual(doc.blocks[0].kind, .paragraph)
        XCTAssertEqual(String(source[doc.blocks[0].source]), "Ship Friday.")
        guard case .text(let range) = doc.blocks[0].inlines.first else {
            return XCTFail("expected a text inline")
        }
        XCTAssertEqual(String(source[range]), "Ship Friday.")
    }

    func testEmptyIsNoBlocks() {
        XCTAssertEqual(MarkdownDocument.parse("").blocks, [])
        XCTAssertEqual(MarkdownDocument.parse("\n\n").blocks, [])
    }
}
