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
}
