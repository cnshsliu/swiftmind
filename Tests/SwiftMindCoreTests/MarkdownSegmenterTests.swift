import XCTest
@testable import SwiftMindCore

final class MarkdownSegmenterTests: XCTestCase {
    private func segments(_ s: String) -> [MarkdownSegment] {
        MarkdownSegmenter.segments(in: s)
    }

    // MARK: - Inline math

    func testInlineMathBasic() {
        XCTAssertEqual(
            segments("Euler: $e^{i\\pi} + 1 = 0$ end"),
            [
                .text("Euler: "),
                .math(inline: true, latex: "e^{i\\pi} + 1 = 0"),
                .text(" end"),
            ]
        )
    }

    func testTwoInlineMaths() {
        XCTAssertEqual(
            segments("$a_1$ and $b^2$"),
            [
                .math(inline: true, latex: "a_1"),
                .text(" and "),
                .math(inline: true, latex: "b^2"),
            ]
        )
    }

    func testCurrencyStaysLiteral() {
        XCTAssertEqual(
            segments("cost $5 and $10 total"),
            [.text("cost $5 and $10 total")]
        )
    }

    func testLoneDollarStaysLiteral() {
        XCTAssertEqual(segments("$100"), [.text("$100")])
    }

    func testCloserFollowedByLetterStaysLiteral() {
        XCTAssertEqual(segments("measure $x$s"), [.text("measure $x$s")])
    }

    func testDollarAfterWordIsNotOpener() {
        XCTAssertEqual(segments("price 5$ and $x$ ok"), [
            .text("price 5$ and "),
            .math(inline: true, latex: "x"),
            .text(" ok"),
        ])
    }

    func testEscapedDollarStaysLiteral() {
        let result = segments("paid \\$5")
        XCTAssertEqual(result.count, 1)
        if case .text(let t) = result[0] {
            XCTAssertTrue(t.contains("\\$5") || t.contains("$5"))
        } else {
            XCTFail("expected text segment")
        }
    }

    // MARK: - Block math

    func testBlockMathSpansLines() {
        XCTAssertEqual(
            segments("before\n$$\n\\frac{a}{b}\n= 1\n$$\nafter"),
            [
                .text("before\n"),
                .math(inline: false, latex: "\\frac{a}{b}\n= 1"),
                .text("\nafter"),
            ]
        )
    }

    func testUnmatchedBlockMathStaysLiteral() {
        XCTAssertEqual(
            segments("a $$ b"),
            [.text("a $$ b")]
        )
    }

    // MARK: - Code

    func testInlineCodeShieldsMath() {
        XCTAssertEqual(
            segments("`$x$` is code"),
            [.text("`$x$` is code")]
        )
    }

    func testFencedCodeShieldsMath() {
        let doc = "```\n$x$ and $$y$$\n```\n"
        let result = segments(doc)
        XCTAssertEqual(result.count, 1)
        if case .text(let t) = result[0] {
            XCTAssertEqual(t, doc)
        } else {
            XCTFail("expected verbatim text")
        }
    }

    func testIndentedFenceStillOpens() {
        let doc = "  ```\n$x$\n  ```\n"
        let result = segments(doc)
        XCTAssertEqual(result.count, 1)
        if case .text(let t) = result[0] {
            XCTAssertEqual(t, doc)
        } else {
            XCTFail("expected verbatim text")
        }
    }

    func testTildeFence() {
        let doc = "~~~\n$x$\n~~~\n"
        XCTAssertEqual(segments(doc), [.text(doc)])
    }

    func testUnclosedBacktickIsLiteral() {
        XCTAssertEqual(segments("a ` b $x$ c"), [
            .text("a ` b "),
            .math(inline: true, latex: "x"),
            .text(" c"),
        ])
    }

    // MARK: - Images

    func testStandaloneImageLine() {
        XCTAssertEqual(
            segments("para\n\n![logo](data:image/png;base64,AAAA)\n\nnext"),
            [
                .text("para\n\n"),
                .image(alt: "logo", urlString: "data:image/png;base64,AAAA"),
                .text("\n\nnext"),
            ]
        )
    }

    func testRemoteImageLine() {
        XCTAssertEqual(
            segments("![pic](https://example.com/y.png)"),
            [.image(alt: "pic", urlString: "https://example.com/y.png")]
        )
    }

    func testInlineImageInProseStaysText() {
        let line = "see ![x](https://e.com/a.png) here"
        XCTAssertEqual(segments(line), [.text(line)])
    }

    // MARK: - Edges

    func testEmptyInput() {
        XCTAssertEqual(segments(""), [])
    }

    func testDollarAtEdges() {
        XCTAssertEqual(segments("$"), [.text("$")])
        XCTAssertEqual(segments("a $"), [.text("a $")])
        XCTAssertEqual(segments("$ a"), [.text("$ a")])
    }

    // MARK: - estimatedLineCount

    func testEstimatedLineCountPlain() {
        XCTAssertEqual(MarkdownSegmenter.estimatedLineCount(of: "a\nb\nc"), 3)
    }

    func testEstimatedLineCountWithImage() {
        // "p" (1 line) + image line (replaced by 8) + "q" (1 line) = 10.
        XCTAssertEqual(
            MarkdownSegmenter.estimatedLineCount(
                of: "p\n![i](data:image/png;base64,AA)\nq"
            ),
            10
        )
    }

    func testEstimatedLineCountBlockMathRows() {
        XCTAssertEqual(
            MarkdownSegmenter.estimatedLineCount(of: "$$\na = b\n= c\n$$"),
            2
        )
    }
}
