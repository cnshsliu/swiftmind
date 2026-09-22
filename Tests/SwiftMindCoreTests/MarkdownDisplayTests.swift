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
}
