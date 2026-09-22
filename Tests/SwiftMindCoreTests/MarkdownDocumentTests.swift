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

    func testStrongMarkerRanges() {
        let source = "Ship **Friday**."
        let doc = MarkdownDocument.parse(source)
        guard case .strong(let open, let content, let close) = doc.blocks[0].inlines[1] else {
            return XCTFail("expected strong as the second inline, got \(doc.blocks[0].inlines)")
        }
        XCTAssertEqual(String(source[open]), "**")
        XCTAssertEqual(content.count, 1)
        guard case .text(let text) = content[0] else { return XCTFail("expected text") }
        XCTAssertEqual(String(source[text]), "Friday")
        XCTAssertEqual(String(source[close]), "**")
    }

    func testUnmatchedStarsStayText() {
        let source = "a * b"
        let doc = MarkdownDocument.parse(source)
        guard case .text(let range) = doc.blocks[0].inlines.first else {
            return XCTFail("expected one text run")
        }
        XCTAssertEqual(String(source[range]), "a * b")
    }

    func testInlineCodeHidesInnerStars() {
        let source = "`**x**`"
        let doc = MarkdownDocument.parse(source)
        guard case .code(_, let content, _) = doc.blocks[0].inlines[0] else {
            return XCTFail("expected code")
        }
        XCTAssertEqual(String(source[content]), "**x**")
    }

    func testLinkRanges() {
        let source = "See [the spec](https://example.com)."
        let doc = MarkdownDocument.parse(source)
        guard case .link(_, let label, _, let url, _) = doc.blocks[0].inlines[1] else {
            return XCTFail("expected a link, got \(doc.blocks[0].inlines)")
        }
        guard case .text(let labelRange) = label[0] else { return XCTFail("expected label text") }
        XCTAssertEqual(String(source[labelRange]), "the spec")
        XCTAssertEqual(String(source[url]), "https://example.com")
    }

    func testInlineMathNotADollarAmount() {
        let source = "Use $x$ here, not $5."
        let doc = MarkdownDocument.parse(source)
        guard case .math(_, let latex, _) = doc.blocks[0].inlines[1] else {
            return XCTFail("expected math, got \(doc.blocks[0].inlines)")
        }
        XCTAssertEqual(String(source[latex]), "x")
    }
}
