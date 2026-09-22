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

    func testBulletMarkerAndText() {
        let source = "- alpha"
        let doc = MarkdownDocument.parse(source)
        XCTAssertEqual(doc.blocks[0].kind, .listItem(ordered: false, checked: nil, indent: 0))
        XCTAssertEqual(String(source[doc.blocks[0].marker]), "- ")
        guard case .text(let range) = doc.blocks[0].inlines.first else {
            return XCTFail("expected item text")
        }
        XCTAssertEqual(String(source[range]), "alpha")
    }

    func testCheckboxAndNestedItem() {
        let source = "- [x] parent\n  - child\n"
        let doc = MarkdownDocument.parse(source)
        XCTAssertEqual(doc.blocks.count, 1)
        XCTAssertEqual(doc.blocks[0].kind, .listItem(ordered: false, checked: true, indent: 0))
        XCTAssertEqual(doc.blocks[0].children.count, 1)
        XCTAssertEqual(
            doc.blocks[0].children[0].kind,
            .listItem(ordered: false, checked: nil, indent: 2)
        )
    }

    func testOrderedItem() {
        let source = "1. beta"
        let doc = MarkdownDocument.parse(source)
        XCTAssertEqual(doc.blocks[0].kind, .listItem(ordered: true, checked: nil, indent: 0))
        XCTAssertEqual(String(source[doc.blocks[0].marker]), "1. ")
    }

    func testSiblingItemsStaySiblings() {
        let source = "- a\n- b\n"
        let doc = MarkdownDocument.parse(source)
        XCTAssertEqual(doc.blocks.count, 2)
        XCTAssertEqual(doc.blocks[0].children.count, 0)
        XCTAssertEqual(doc.blocks[1].children.count, 0)
    }

    func testQuoteMarker() {
        let source = "> noted"
        let doc = MarkdownDocument.parse(source)
        XCTAssertEqual(doc.blocks[0].kind, .quote)
        XCTAssertEqual(String(source[doc.blocks[0].marker]), "> ")
    }

    func testFenceHidesInnerMarks() {
        let source = "```\n**nope**\n```\n"
        let doc = MarkdownDocument.parse(source)
        XCTAssertEqual(doc.blocks.count, 1)
        XCTAssertEqual(doc.blocks[0].kind, .codeFence)
        XCTAssertEqual(doc.blocks[0].inlines.count, 1)
        guard case .text(let range) = doc.blocks[0].inlines[0] else {
            return XCTFail("fence body is raw text")
        }
        XCTAssertEqual(String(source[range]), "**nope**")
    }

    func testMathBlockContentRange() {
        let source = "$$\na = b\n$$\n"
        let doc = MarkdownDocument.parse(source)
        XCTAssertEqual(doc.blocks[0].kind, .mathBlock)
        guard case .text(let range) = doc.blocks[0].inlines.first else {
            return XCTFail("expected latex text")
        }
        XCTAssertEqual(String(source[range]), "a = b")
    }

    func testImageLine() {
        let source = "![sketch](data:image/png;base64,QQ==)"
        let doc = MarkdownDocument.parse(source)
        guard case .image(let alt, let url) = doc.blocks[0].kind else {
            return XCTFail("expected an image block")
        }
        XCTAssertEqual(String(source[alt]), "sketch")
        XCTAssertTrue(String(source[url]).hasPrefix("data:image/png"))
    }

    func testDollarAmountIsText() {
        let source = "Costs $5 and $10."
        let doc = MarkdownDocument.parse(source)
        XCTAssertEqual(doc.blocks[0].kind, .paragraph)
        guard case .text = doc.blocks[0].inlines.first else {
            return XCTFail("dollar amounts stay text")
        }
    }
}
