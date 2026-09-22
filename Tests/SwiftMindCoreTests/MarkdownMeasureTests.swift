import XCTest
@testable import SwiftMindCore

final class MarkdownMeasureTests: XCTestCase {
    private let measure = MarkdownMeasure(width: 360, charWidth: 7, lineHeight: 20, imageHeight: 160)

    func testWrappedParagraphIsTallerThanOneLine() {
        let text = String(repeating: "word ", count: 80)
        XCTAssertGreaterThan(measure.height(of: text), 20)
    }

    func testImageUsesImageHeight() {
        XCTAssertEqual(
            measure.height(of: "![a](data:image/png;base64,QQ==)"),
            160
        )
    }

    func testFenceCountsContentLines() {
        XCTAssertEqual(measure.height(of: "```\na\nb\n```"), 40)
    }
}
