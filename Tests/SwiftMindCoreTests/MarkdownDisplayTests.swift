import XCTest
@testable import SwiftMindCore

final class MarkdownDisplayTests: XCTestCase {
    func testKeyboardTagHidesMarkersUntilTheCaretIsInside() {
        let source = "Press <kbd>⌘E</kbd> to edit."
        let hidden = MarkdownDisplay.project(source, reveal: .none)
        XCTAssertEqual(hidden.text, "Press ⌘E to edit.")
        XCTAssertFalse(hidden.text.contains("kbd"))
        let reveal = MarkdownDisplay.reveal(atUTF16: ("Press <kbd>" as NSString).length, in: source)
        let shown = MarkdownDisplay.project(source, reveal: reveal)
        XCTAssertEqual(shown.text, source)
    }

    func testDeletingAWholeKeyRemovesTheTag() {
        let source = "Press <kbd>⌘E</kbd> now."
        let display = MarkdownDisplay.project(source, reveal: .none)
        let key = (display.text as NSString).range(of: "⌘E")
        let edit = display.applyingEdit(
            source: source,
            displayUTF16: key.location..<(key.location + key.length),
            replacement: ""
        )
        XCTAssertEqual(edit.markdown, "Press  now.")
        XCTAssertFalse(edit.markdown.contains("kbd"), edit.markdown)
    }

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

    func testSingleLineMathHidesDollars() {
        let display = MarkdownDisplay.project(#"$$\frac{a}{b}$$"#, reveal: .none)
        XCTAssertEqual(display.text, #"\frac{a}{b}"#)
        XCTAssertFalse(display.text.contains("$"))
    }

    func testBackspaceOfTheSpaceAfterListDashStaysOnThatLine() {
        let source = "- dotted item\n- another dotted item\n"
        let display = MarkdownDisplay.project(source, reveal: .none)
        // Caret is after "-". Backspace removes the space that follows the dash.
        let edit = display.applyingEdit(source: source, displayUTF16: 1..<2, replacement: "")
        let reveal = MarkdownDisplay.reveal(atUTF16: edit.caretUTF16, in: edit.markdown)
        let next = MarkdownDisplay.project(edit.markdown, reveal: reveal)
        let index = next.displayIndex(forSourceUTF16: edit.caretUTF16)
        XCTAssertNotEqual(index, (next.text as NSString).length)
        XCTAssertFalse(next.text.contains("- -"), next.text)
        XCTAssertTrue(next.text.contains("dotted item"), next.text)
    }

    func testLiveBackspaceOnEmptyListLineDoesNotDoubleMarkers() {
        let before = "New Idea\n\n- dotted item\n- \n- another dotted item"
        let display = MarkdownDisplay.project(before, reveal: .none)
        XCTAssertEqual(display.text, before)
        let ns = before as NSString
        let dash = ns.range(of: "\n- \n").location + 1
        var units = Array(before.utf16)
        units.remove(at: dash)
        let after = String(decoding: units, as: UTF16.self)
        let change = MarkdownDisplay.displayChange(from: before, to: after)
        XCTAssertEqual(change.range, dash..<(dash + 1), "\(change)")
        let edit = display.applyingEdit(source: before, displayUTF16: change.range, replacement: change.replacement)
        XCTAssertFalse(edit.markdown.contains("- -"), edit.markdown)
        let next = MarkdownDisplay.project(
            edit.markdown,
            reveal: MarkdownDisplay.reveal(atUTF16: edit.caretUTF16, in: edit.markdown)
        )
        let index = next.displayIndex(forSourceUTF16: edit.caretUTF16)
        XCTAssertNotEqual(index, (next.text as NSString).length, next.text)
    }

    func testCaretAtEndOfSourceIsEndOfDisplayWhenHeadingIsHidden() {
        let source = "# New Idea\n- dotted item\n- "
        let display = MarkdownDisplay.project(source, reveal: .none)
        let index = display.displayIndex(forSourceUTF16: (source as NSString).length)
        XCTAssertEqual(
            index,
            (display.text as NSString).length,
            "text=\(display.text.debugDescription) map=\(display.sourceUTF16)"
        )
    }

    func testBackspaceOnEmptyListLineStaysThere() {
        let source = "- dotted item\n- \n- another dotted item\n"
        let display = MarkdownDisplay.project(source, reveal: .none)
        let ns = display.text as NSString
        let secondDash = ns.range(of: "\n- ").location + 1
        XCTAssertGreaterThan(secondDash, 0)
        // Caret is just after that dash, so Backspace deletes the dash.
        let edit = display.applyingEdit(
            source: source,
            displayUTF16: secondDash..<(secondDash + 1),
            replacement: ""
        )
        let reveal = MarkdownDisplay.reveal(atUTF16: edit.caretUTF16, in: edit.markdown)
        let next = MarkdownDisplay.project(edit.markdown, reveal: reveal)
        let index = next.displayIndex(forSourceUTF16: edit.caretUTF16)
        let length = (next.text as NSString).length
        XCTAssertNotEqual(
            index, length,
            "caret jumped to end. caret=\(edit.caretUTF16) index=\(index) len=\(length)\nmarkdown=\(edit.markdown)\nnext=\(next.text)\nmap=\(next.sourceUTF16)"
        )
        XCTAssertTrue(next.text.contains("dotted item"), next.text)
        XCTAssertTrue(next.text.contains("another dotted item"), next.text)
    }

    func testBackspaceAfterListDashStaysOnThatLine() {
        let source = "- dotted item\n- another dotted item\n"
        let display = MarkdownDisplay.project(source, reveal: .none)
        XCTAssertTrue(display.text.hasPrefix("- "))
        // The caret is just after "-". Backspace removes the dash.
        let edit = display.applyingEdit(source: source, displayUTF16: 0..<1, replacement: "")
        let reveal = MarkdownDisplay.reveal(atUTF16: edit.caretUTF16, in: edit.markdown)
        let next = MarkdownDisplay.project(edit.markdown, reveal: reveal)
        let index = next.displayIndex(forSourceUTF16: edit.caretUTF16)
        XCTAssertLessThan(index, next.text.prefix(while: { $0 != "\n" }).utf16.count + 1)
        XCTAssertFalse(next.text.contains("- -"), next.text)
        XCTAssertNotEqual(index, next.text.utf16.count)
    }

    func testReturnInQuoteStaysOnTheNewLine() {
        let source = "> Quotes and\nmore\n"
        let revealed = MarkdownDisplay.Reveal.block(
            MarkdownDocument.parse(source).blocks[0].marker
        )
        let display = MarkdownDisplay.project(source, reveal: revealed)
        XCTAssertTrue(display.text.hasPrefix("> Quotes and"))
        let lineEnd = (display.text as NSString).range(of: "\n").location
        XCTAssertNotEqual(lineEnd, NSNotFound)
        let edit = display.applyingEdit(
            source: source,
            displayUTF16: lineEnd..<lineEnd,
            replacement: "\n"
        )
        let reveal = MarkdownDisplay.reveal(atUTF16: edit.caretUTF16, in: edit.markdown)
        let next = MarkdownDisplay.project(edit.markdown, reveal: reveal)
        let index = next.displayIndex(forSourceUTF16: edit.caretUTF16)
        XCTAssertNotEqual(index, (next.text as NSString).length)
        let caretLine = (next.text as NSString).substring(to: index)
        XCTAssertLessThanOrEqual(caretLine.filter { $0 == "\n" }.count, 2)
    }

    func testQuoteMarkerShowsAnywhereOnTheLine() {
        let source = "> noted\n"
        let reveal = MarkdownDisplay.reveal(atUTF16: 4, in: source)
        guard case .block(let marker) = reveal else {
            return XCTFail("caret inside a quote should reveal >, got \(reveal)")
        }
        XCTAssertEqual(String(source[marker]), "> ")
        XCTAssertTrue(MarkdownDisplay.project(source, reveal: reveal).text.hasPrefix("> "))
    }

    func testHeadingMarkersShowAnywhereOnTheLine() {
        let source = "## title2\n"
        let reveal = MarkdownDisplay.reveal(atUTF16: 3, in: source)
        guard case .block(let marker) = reveal else {
            return XCTFail("caret inside the heading should reveal its marks, got \(reveal)")
        }
        XCTAssertEqual(String(source[marker]), "## ")
        XCTAssertEqual(MarkdownDisplay.project(source, reveal: reveal).text, "## title2\n")
    }

    func testMathKeepsInteriorBlankLine() {
        let source = "$$\nx\n\n$$\n"
        let display = MarkdownDisplay.project(source, reveal: .none)
        XCTAssertEqual(display.text, "x\n\n")
        XCTAssertEqual(display.sourceUTF16.count, display.text.utf16.count)
    }

    func testCaretInsideStrongRevealsMarkers() {
        let source = "Ship **Friday**."
        let caret = (source as NSString).range(of: "Friday").location
        let reveal = MarkdownDisplay.reveal(atUTF16: caret, in: source)
        XCTAssertEqual(MarkdownDisplay.project(source, reveal: reveal).text, source)
    }

    func testCaretInsideEmphasisRevealsMarkers() {
        let source = "Ship *Friday*."
        let caret = (source as NSString).range(of: "Friday").location
        let reveal = MarkdownDisplay.reveal(atUTF16: caret, in: source)
        XCTAssertEqual(MarkdownDisplay.project(source, reveal: reveal).text, source)
    }

    func testCaretInsideNestedEmphasisRevealsThatSpan() {
        let source = "**bold *em* text**"
        let caret = (source as NSString).range(of: "em").location
        let reveal = MarkdownDisplay.reveal(atUTF16: caret, in: source)
        XCTAssertEqual(MarkdownDisplay.project(source, reveal: reveal).text, "bold *em* text")
    }

    func testSingleLineMathWithNewlineKeepsFormula() {
        let source = "before\n\n$$\\frac{a}{b}$$\n\nafter\n"
        let display = MarkdownDisplay.project(source, reveal: .none)
        XCTAssertEqual(display.text, "before\n\n\\frac{a}{b}\n\nafter\n")
        XCTAssertEqual(display.sourceUTF16.count, display.text.utf16.count)
    }

    func testListMarkersStayVisible() {
        let source = "- dotted\n- another\n\n1. numbered\n2. second\n"
        let display = MarkdownDisplay.project(source, reveal: .none)
        XCTAssertEqual(display.text, source)
        XCTAssertEqual(display.sourceUTF16.count, display.text.utf16.count)
    }

    func testNestedListKeepsIndent() {
        let source = "- a\n  - b\n"
        let display = MarkdownDisplay.project(source, reveal: .none)
        XCTAssertEqual(display.text, source)
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

    func testRevealImageMarkerIsTheRawLine() {
        let source = "![ab](u)\n"
        let doc = MarkdownDocument.parse(source)
        let display = MarkdownDisplay.project(source, reveal: .block(doc.blocks[0].marker))
        XCTAssertFalse(display.text.contains("\u{FFFC}"))
        XCTAssertTrue(display.text.hasPrefix("![ab](u)"))
        XCTAssertEqual(display.sourceUTF16.count, display.text.utf16.count)
    }

    func testDeleteWholeStrongRemovesMarkers() {
        let source = "Ship **Friday**."
        let previous = MarkdownDisplay.project(source, reveal: .none)
        let deleted = previous.splicing(source: source, displayReplacement: "", displayUTF16: 5..<11)
        XCTAssertEqual(deleted, "Ship .")
    }

    func testDeleteOneLetterInsideStrongKeepsMarkers() {
        let source = "Ship **Friday**."
        let previous = MarkdownDisplay.project(source, reveal: .none)
        let deleted = previous.splicing(source: source, displayReplacement: "", displayUTF16: 5..<6)
        XCTAssertEqual(deleted, "Ship **riday**.")
    }

    func testDeleteImageObjectRemovesTheLine() {
        let source = "![ab](u)"
        let previous = MarkdownDisplay.project(source, reveal: .none)
        XCTAssertEqual(previous.text, "\u{FFFC}")
        let deleted = previous.splicing(source: source, displayReplacement: "", displayUTF16: 0..<1)
        XCTAssertEqual(deleted, "")
    }

    func testInsertInsideHiddenStrongDoesNotEatMarkers() {
        let source = "Ship **Friday**."
        let previous = MarkdownDisplay.project(source, reveal: .none)
        XCTAssertEqual(previous.text, "Ship Friday.")
        let inserted = previous.splicing(source: source, displayReplacement: "X", displayUTF16: 5..<5)
        XCTAssertEqual(inserted, "Ship **XFriday**.")
    }

    func testRevealFenceMarkerIsTheRawBlock() {
        let source = "```\nfoo\n\n```\n"
        let doc = MarkdownDocument.parse(source)
        let display = MarkdownDisplay.project(source, reveal: .block(doc.blocks[0].marker))
        XCTAssertEqual(display.text, source)
    }

    func testRevealMathMarkerIsTheRawBlock() {
        let source = "$$\nx\n\n$$\n"
        let doc = MarkdownDocument.parse(source)
        let display = MarkdownDisplay.project(source, reveal: .block(doc.blocks[0].marker))
        XCTAssertEqual(display.text, source)
    }

    func testRevealHeadingKeepsInnerMarkersHidden() {
        let source = "## **x**\n"
        let doc = MarkdownDocument.parse(source)
        let display = MarkdownDisplay.project(source, reveal: .block(doc.blocks[0].marker))
        XCTAssertEqual(display.text, "## x\n")
    }

    func testWrapStrong() {
        XCTAssertEqual(MarkdownDisplay.wrap("Friday", rangeUTF16: 0..<6, marker: "**"), "**Friday**")
    }

    func testUnwrapStrong() {
        XCTAssertEqual(MarkdownDisplay.wrap("**Friday**", rangeUTF16: 2..<8, marker: "**"), "Friday")
    }

    func testSetHeadingLevel() {
        XCTAssertEqual(MarkdownDisplay.setHeading("## title2", level: 3), "### title2")
        XCTAssertEqual(MarkdownDisplay.setHeading("title2", level: 3), "### title2")
    }
}

    // MARK: - 1.2 additions

    func testStrikethroughMarkersHiddenAndRevealable() {
        let hidden = MarkdownDisplay.project("done ~~and dusted~~ ok", reveal: .none)
        XCTAssertEqual(hidden.text, "done and dusted ok", hidden.text)
        let doc = MarkdownDocument.parse("done ~~and dusted~~ ok")
        guard case .strikethrough(_, let content, _) = doc.blocks[0].inlines[1],
              case .text(let range) = content[0] else {
            return XCTFail("missing strikethrough")
        }
        let offset = hidden.sourceUTF16 == nil ? 0 : 0
        _ = offset
        let caretUTF16 = range.lowerBound.utf16Offset(in: "done ~~and dusted~~ ok")
        let revealed = MarkdownDisplay.reveal(atUTF16: caretUTF16, in: "done ~~and dusted~~ ok")
        let shown = MarkdownDisplay.project("done ~~and dusted~~ ok", reveal: revealed)
        XCTAssertTrue(shown.text.contains("~~"), "reveal must show the markers: \(shown.text)")
    }

    func testHighlightMarkersHidden() {
        let hidden = MarkdownDisplay.project("see ==this part== now", reveal: .none)
        XCTAssertEqual(hidden.text, "see this part now", hidden.text)
    }

    func testDividerProjectsWithRawLine() {
        let hidden = MarkdownDisplay.project("above\n---\nbelow", reveal: .none)
        XCTAssertTrue(hidden.text.contains("---"), hidden.text)
        XCTAssertEqual(hidden.text.components(separatedBy: "\n").count, 3, hidden.text)
    }

    func testStrikeWholeSpanDeleteIncludesMarkers() {
        let display = MarkdownDisplay.project("a ~~bb~~ c", reveal: .none)
        // display "a bb c": deleting "bb" must cover the source markers too
        let splice = display.splicing(source: "a ~~bb~~ c", displayReplacement: "X", displayUTF16: 2..<4)
        XCTAssertEqual(splice, "a X c", splice)
    }
