import XCTest
@testable import SwiftMindCore

final class MarkdownDisplayTests: XCTestCase {
    func testBoldMarkersHidden() {
        let display = MarkdownDisplay.project("Ship **Friday**.", reveal: .none)
        XCTAssertEqual(display.text, "Ship Friday.")
        XCTAssertFalse(display.text.contains("*"))
        XCTAssertEqual(display.sourceUTF16.count, display.text.utf16.count)
    }

    func testHeadingMarkersHidden() {
        let display = MarkdownDisplay.project("## title2\n", reveal: .none)
        XCTAssertEqual(display.text, "title2\n")
    }

    func testImageBecomesObjectCharacter() {
        let display = MarkdownDisplay.project("![sketch](data:image/png;base64,QQ==)", reveal: .none)
        XCTAssertEqual(display.text, "\u{FFFC}")
    }

    func testFenceKeepsInteriorBlankLine() {
        let source = "```\nfoo\n\n```\n"
        let display = MarkdownDisplay.project(source, reveal: .none)
        XCTAssertEqual(display.text, "foo\n\n")
        XCTAssertEqual(display.sourceUTF16.count, display.text.utf16.count)
    }

    func testEmptyFenceDoesNotAddALine() {
        let source = "before\n```\n```\nafter\n"
        let display = MarkdownDisplay.project(source, reveal: .none)
        XCTAssertEqual(display.text, "before\nafter\n")
        XCTAssertEqual(display.sourceUTF16.count, display.text.utf16.count)
    }

    func testMathKeepsInteriorBlankLine() {
        let source = "$$\nx\n\n$$\n"
        let display = MarkdownDisplay.project(source, reveal: .none)
        XCTAssertEqual(display.text, "x\n\n")
        XCTAssertEqual(display.sourceUTF16.count, display.text.utf16.count)
    }

    func testRevealStrongShowsMarkers() {
        let source = "Ship **Friday**."
        let doc = MarkdownDocument.parse(source)
        guard case .strong(_, let content, _) = doc.blocks[0].inlines[1],
              case .text(let range) = content[0] else {
            return XCTFail("missing strong")
        }
        let display = MarkdownDisplay.project(source, reveal: .inline(range))
        XCTAssertEqual(display.text, "Ship **Friday**.")
        XCTAssertEqual(display.sourceUTF16.count, display.text.utf16.count)
    }

    func testRevealHeadingPrefix() {
        let source = "## title2\n"
        let doc = MarkdownDocument.parse(source)
        let display = MarkdownDisplay.project(source, reveal: .block(doc.blocks[0].marker))
        XCTAssertEqual(display.text, "## title2\n")
        XCTAssertEqual(display.sourceUTF16.count, display.text.utf16.count)
    }

    func testSpliceInsertsIntoMarkdown() {
        let source = "Ship Friday."
        let previous = MarkdownDisplay.project(source, reveal: .none)
        let inserted = previous.splicing(source: source, displayReplacement: "X", displayUTF16: 5..<5)
        XCTAssertEqual(inserted, "Ship XFriday.")
    }

    func testSpliceDeletesMarkdown() {
        let source = "Ship Friday."
        let previous = MarkdownDisplay.project(source, reveal: .none)
        let deleted = previous.splicing(source: source, displayReplacement: "", displayUTF16: 5..<11)
        XCTAssertEqual(deleted, "Ship .")
    }
}
