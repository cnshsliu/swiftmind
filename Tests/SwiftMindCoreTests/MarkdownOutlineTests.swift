import XCTest
@testable import SwiftMindCore

final class MarkdownOutlineTests: XCTestCase {
    private func makeTree() -> [Node] {
        [
            Node(
                text: "Parent",
                noteMarkdown: "a note",
                children: [
                    Node(text: "Child A"),
                    Node(
                        text: "Child B",
                        children: [Node(text: "Grandchild")]
                    ),
                ]
            ),
            Node(text: "Second root"),
        ]
    }

    func testExportFormat() {
        XCTAssertEqual(
            MarkdownOutline.export(makeTree()),
            """
            - Parent
              a note
              - Child A
              - Child B
                - Grandchild
            - Second root

            """
        )
    }

    func testParseRoundTripPreservesTitlesNestingNotes() {
        let original = makeTree()
        let parsed = MarkdownOutline.parse(MarkdownOutline.export(original))
        XCTAssertNotNil(parsed)
        let titles = parsed!
        XCTAssertEqual(titles.count, 2)
        XCTAssertEqual(titles[0].text, "Parent")
        XCTAssertEqual(titles[0].noteMarkdown, "a note")
        XCTAssertEqual(titles[0].children.count, 2)
        XCTAssertEqual(titles[0].children[0].text, "Child A")
        XCTAssertEqual(titles[0].children[1].children[0].text, "Grandchild")
        XCTAssertEqual(titles[1].text, "Second root")
    }

    func testParsePlainProseReturnsNil() {
        XCTAssertNil(MarkdownOutline.parse("just some words\nand more words"))
    }

    func testParseEmptyReturnsNil() {
        XCTAssertNil(MarkdownOutline.parse(""))
    }

    func testParseTabIndent() {
        let parsed = MarkdownOutline.parse("- a\n\t- b\n\t\t- c")
        XCTAssertEqual(parsed?.count, 1)
        XCTAssertEqual(parsed?[0].children.count, 1)
        XCTAssertEqual(parsed?[0].children[0].children[0].text, "c")
    }

    func testParseFourSpaceIndent() {
        let parsed = MarkdownOutline.parse("- a\n    - b")
        XCTAssertEqual(parsed?.count, 1)
        XCTAssertEqual(parsed?[0].children.count, 1)
    }

    func testParseStarAndPlusBullets() {
        let parsed = MarkdownOutline.parse("* a\n  + b")
        XCTAssertEqual(parsed?.count, 1)
        XCTAssertEqual(parsed?[0].children[0].text, "b")
    }

    func testParseMultilineNote() {
        let parsed = MarkdownOutline.parse("- a\n  line one\n  line two\n- b")
        XCTAssertEqual(parsed?.count, 2)
        XCTAssertEqual(parsed?[0].noteMarkdown, "line one\nline two")
        XCTAssertEqual(parsed?[1].noteMarkdown, "")
    }

    func testParseIgnoresLeadingProse() {
        let parsed = MarkdownOutline.parse("intro prose\n- a")
        XCTAssertEqual(parsed?.count, 1)
        XCTAssertEqual(parsed?[0].text, "a")
    }

    func testParseFirstBulletIndentDefinesRoot() {
        let parsed = MarkdownOutline.parse("    - a\n      - b")
        XCTAssertEqual(parsed?.count, 1)
        XCTAssertEqual(parsed?[0].children[0].text, "b")
    }
}
