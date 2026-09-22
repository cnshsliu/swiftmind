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

    func testHeadingMarkerAndLevel() {
        let source = "## title2\n"
        let doc = MarkdownDocument.parse(source)
        XCTAssertEqual(doc.blocks.count, 1)
        XCTAssertEqual(doc.blocks[0].kind, .heading(level: 2))
        XCTAssertEqual(String(source[doc.blocks[0].marker]), "## ")
        guard case .text(let range) = doc.blocks[0].inlines.first else {
            return XCTFail("expected heading text")
        }
        XCTAssertEqual(String(source[range]), "title2")
    }

    func testUnclosedHeadingStaysParagraph() {
        let source = "##title"
        let doc = MarkdownDocument.parse(source)
        XCTAssertEqual(doc.blocks[0].kind, .paragraph)
    }
}
