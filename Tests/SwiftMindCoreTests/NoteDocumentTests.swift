import XCTest
@testable import SwiftMindCore

final class NoteDocumentTests: XCTestCase {
    func testComposeWithBody() {
        let doc = NoteDocument.compose(title: "Ideas", body: "first\nsecond")
        XCTAssertEqual(doc, "# Ideas\n\nfirst\nsecond\n")
    }

    func testComposeEmptyBody() {
        XCTAssertEqual(NoteDocument.compose(title: "Solo", body: ""), "# Solo\n")
    }

    func testSplitRoundTrip() {
        let doc = NoteDocument.compose(title: "Ideas", body: "first\nsecond")
        let (title, body) = NoteDocument.split(doc)
        XCTAssertEqual(title, "Ideas")
        XCTAssertEqual(body, "first\nsecond")
    }

    func testSplitMissingH1KeepsTitleNilAndWholeBody() {
        let (title, body) = NoteDocument.split("no heading here\nbody")
        XCTAssertNil(title)
        XCTAssertEqual(body, "no heading here\nbody")
    }

    func testSplitEmptyH1KeepsTitleNil() {
        let (title, body) = NoteDocument.split("#\n\nbody")
        XCTAssertNil(title)
        XCTAssertEqual(body, "body")
    }

    func testSplitTrimsTitleWhitespace() {
        let (title, _) = NoteDocument.split("#   Spaced   \nbody")
        XCTAssertEqual(title, "Spaced")
    }

    func testSplitPreservesLaterHeadingsInBody() {
        let (title, body) = NoteDocument.split("# Top\n\n## Sub\n\ntext\n# Another\n")
        XCTAssertEqual(title, "Top")
        XCTAssertEqual(body, "## Sub\n\ntext\n# Another")
    }

    func testSplitEmptyDocument() {
        let (title, body) = NoteDocument.split("")
        XCTAssertNil(title)
        XCTAssertEqual(body, "")
    }
}
