import XCTest
@testable import SwiftMindCore

final class MarkdownEditingSessionTests: XCTestCase {
    private let documents = [
        "Hello",
        "# Title\n\nBody text",
        "- dotted item\n- \n- another dotted item\n",
        "1. one\n1. two\n",
        "> Quotes and\n> more\n",
        "Ship **Friday** today.",
        "Use *italic* here.",
        "Before\n\n$$\nfrac\n$$\nAfter",
        "# New Idea\n\n- dotted item\n- \n- another dotted item\n",
        "para one\n\npara two",
    ]

    func testBackspaceOnEmptyMiddleListItemStaysOnThatLine() {
        var session = MarkdownEditingSession(
            markdown: "- dotted item\n- \n- another dotted item\n"
        )
        let display = session.display.text as NSString
        let dash = display.range(of: "\n- \n").location + 1
        session.moveCaret(to: dash + 1) // just after '-'
        let endBefore = session.displayLength
        session.backspace()
        XCTAssertNotEqual(session.caret, session.displayLength, session.display.text)
        XCTAssertLessThan(session.caret, endBefore)
        XCTAssertTrue(session.display.text.contains("dotted item"))
        XCTAssertTrue(session.display.text.contains("another dotted item"))
        XCTAssertFalse(session.markdown.contains("- -"), session.markdown)
    }

    func testReturnInQuoteDoesNotJumpToEnd() {
        var session = MarkdownEditingSession(markdown: "> Quotes and\nmore\n")
        let display = session.display.text as NSString
        let lineEnd = display.range(of: "\n").location
        session.moveCaret(to: lineEnd)
        session.newline()
        XCTAssertNotEqual(session.caret, session.displayLength, session.display.text)
        XCTAssertTrue(session.display.text.contains("Quotes"), session.display.text)
        XCTAssertTrue(session.markdown.contains("Quotes"), session.markdown)
    }

    func testEnterAtEndOfListItemThenTypeStaysOnTheNewLine() {
        var session = MarkdownEditingSession(markdown: "- dotted item\n- another dotted item\n")
        let endOfFirst = (session.display.text as NSString).range(of: "\n").location
        session.moveCaret(to: endOfFirst)
        session.newline()
        let afterReturn = session.display.text as NSString
        let prefix = afterReturn.substring(to: min(session.caret, afterReturn.length))
        XCTAssertTrue(
            prefix.hasSuffix("- "),
            "caret should sit after the new list marker — prefix=\(prefix.debugDescription) full=\(session.display.text.debugDescription) caret=\(session.caret)"
        )
        session.insert("abcd")
        XCTAssertTrue(session.markdown.contains("- abcd"), session.markdown)
        XCTAssertFalse(session.markdown.contains("abcdanother"), session.markdown)
        XCTAssertFalse(session.display.text.contains("abcdanother"), session.display.text)
    }

    func testEnterAtEndOfQuoteThenTypeContinuesTheQuote() {
        var session = MarkdownEditingSession(markdown: "> Quotes and\nmore\n")
        let endOfFirst = (session.display.text as NSString).range(of: "\n").location
        session.moveCaret(to: endOfFirst)
        session.newline()
        let afterReturn = session.display.text as NSString
        let prefix = afterReturn.substring(to: min(session.caret, afterReturn.length))
        XCTAssertTrue(
            prefix.hasSuffix("> "),
            "caret should sit after > — prefix=\(prefix.debugDescription) full=\(session.display.text.debugDescription)"
        )
        session.insert("abcd")
        XCTAssertTrue(
            session.markdown.contains("> abcd"),
            "display=\(session.display.text.debugDescription) md=\(session.markdown.debugDescription) caret=\(session.caret)"
        )
        XCTAssertFalse(session.markdown.contains("abcdmore"), session.markdown)
    }

    func testOrderedItemsRenumberAfterEdit() {
        let source = "1. numbered item\n2. hello\n2. another numbered item\n3. hello"
        let (text, _) = MarkdownDocument.renumberOrderedLists(source, caret: 0)
        XCTAssertEqual(
            text,
            "1. numbered item\n2. hello\n3. another numbered item\n4. hello"
        )
        var session = MarkdownEditingSession(markdown: source, caretAtEnd: false)
        XCTAssertEqual(
            session.markdown,
            "1. numbered item\n2. hello\n3. another numbered item\n4. hello"
        )
        session.moveCaret(to: session.displayLength)
        session.insert("!")
        XCTAssertTrue(session.markdown.hasPrefix("1. numbered item\n2. hello\n3. another numbered item\n4. hello!"), session.markdown)
    }

    func testReturnOnListContinuesWithoutDoubling() {
        var session = MarkdownEditingSession(markdown: "- dotted item")
        session.moveCaret(to: session.displayLength)
        session.newline()
        XCTAssertFalse(session.markdown.contains("- -"), session.markdown)
        XCTAssertTrue(session.display.text.contains("- dotted item"), session.display.text)
        XCTAssertNotEqual(session.caret, 0)
    }

    func testReturnOnEmptyListItemClearsMarker() {
        var session = MarkdownEditingSession(markdown: "- dotted item\n- ")
        session.moveCaret(to: session.displayLength)
        session.newline()
        XCTAssertFalse(session.display.text.contains("\n- "), session.display.text)
        XCTAssertTrue(session.display.text.contains("dotted item"), session.display.text)
    }

    func testBackspaceAndForwardDeleteRemoveTheSelection() {
        let source = """
        1. numbered itemhello
        2. hello2
        3. jajfdj
        4. another numbered item
        5. hello
        """
        var forward = MarkdownEditingSession(markdown: source, caretAtEnd: false)
        let display = forward.display.text as NSString
        let start = display.range(of: "hello").location
        let end = display.range(of: "jajfdj").location + ("jajfdj" as NSString).length
        forward.setSelection(start..<end)
        XCTAssertEqual(forward.display.text, display as String)
        forward.forwardDelete()
        XCTAssertEqual(
            forward.markdown,
            "1. numbered item\n2. another numbered item\n3. hello"
        )
        XCTAssertTrue(forward.selection.isEmpty)
        XCTAssertEqual(forward.caret, start)

        var backward = MarkdownEditingSession(markdown: source, caretAtEnd: false)
        backward.setSelection(start..<end)
        backward.backspace()
        XCTAssertEqual(backward.markdown, forward.markdown)
        XCTAssertEqual(backward.caret, forward.caret)
    }

    func testCharacterDeleteRemovesOneGrapheme() {
        var session = MarkdownEditingSession(markdown: "abcdef", caretAtEnd: false)
        session.moveCaret(to: 2)
        session.forwardDelete()
        XCTAssertEqual(session.markdown, "abdef")
        XCTAssertEqual(session.caret, 2)

        session = MarkdownEditingSession(markdown: "abcdef", caretAtEnd: false)
        session.moveCaret(to: 2)
        session.backspace()
        XCTAssertEqual(session.markdown, "acdef")
        XCTAssertEqual(session.caret, 1)

        session = MarkdownEditingSession(markdown: "a😀b", caretAtEnd: false)
        let afterEmoji = ("a😀" as NSString).length
        session.moveCaret(to: afterEmoji)
        session.backspace()
        XCTAssertEqual(session.markdown, "ab")
        XCTAssertEqual(session.caret, 1)

        session = MarkdownEditingSession(markdown: "a😀b", caretAtEnd: false)
        session.moveCaret(to: 1)
        session.forwardDelete()
        XCTAssertEqual(session.markdown, "ab")

        let family = "👨‍👩‍👧‍👦"
        session = MarkdownEditingSession(markdown: "a\(family)b", caretAtEnd: false)
        session.moveCaret(to: ("a\(family)" as NSString).length)
        session.backspace()
        XCTAssertEqual(session.markdown, "ab")
    }

    func testDeleteKeysAtTheEndsAndEmptySelectionDoNothing() {
        var session = MarkdownEditingSession(markdown: "abc", caretAtEnd: false)
        session.backspace()
        session.deleteWordBackward()
        session.deleteToBeginningOfLine()
        XCTAssertEqual(session.markdown, "abc")
        session.moveCaret(to: session.displayLength)
        session.forwardDelete()
        session.deleteWordForward()
        session.deleteToEndOfLine()
        session.deleteToEndOfParagraph()
        session.deleteSelection()
        XCTAssertEqual(session.markdown, "abc")
    }

    func testDecomposeStripsOneMarkAndSelectionDeletesWhole() {
        var session = MarkdownEditingSession(markdown: "caf\u{00e9}", caretAtEnd: true)
        session.decomposeBackward()
        XCTAssertEqual(session.markdown, "cafe")
        XCTAssertEqual(session.caret, 4)

        session = MarkdownEditingSession(markdown: "cafe\u{0301}", caretAtEnd: true)
        session.decomposeBackward()
        XCTAssertEqual(session.markdown, "cafe")

        session = MarkdownEditingSession(markdown: "cafe", caretAtEnd: true)
        session.decomposeBackward()
        XCTAssertEqual(session.markdown, "caf")

        session = MarkdownEditingSession(markdown: "abcdef", caretAtEnd: false)
        session.setSelection(2..<4)
        session.decomposeBackward()
        XCTAssertEqual(session.markdown, "abef")
        XCTAssertEqual(session.caret, 2)
    }

    func testWordAndLineDeletion() {
        func edit(_ text: String, _ caret: Int, _ body: (inout MarkdownEditingSession) -> Void) -> String {
            var session = MarkdownEditingSession(markdown: text, caretAtEnd: false)
            session.moveCaret(to: caret)
            body(&session)
            return session.markdown
        }
        XCTAssertEqual(edit("hello world", 11) { $0.deleteWordBackward() }, "hello ")
        XCTAssertEqual(edit("hello world ", 12) { $0.deleteWordBackward() }, "hello ")
        XCTAssertEqual(edit("hello world", 8) { $0.deleteWordBackward() }, "hello rld")
        XCTAssertEqual(edit("hello, world", 6) { $0.deleteWordBackward() }, " world")
        XCTAssertEqual(edit("hello, world", 5) { $0.deleteWordBackward() }, ", world")
        XCTAssertEqual(edit("hello\nworld", 6) { $0.deleteWordBackward() }, "world")
        XCTAssertEqual(edit("hello world", 3) { $0.deleteWordForward() }, "hel world")
        XCTAssertEqual(edit("hello world", 5) { $0.deleteWordForward() }, "hello")
        XCTAssertEqual(edit("hello, world", 5) { $0.deleteWordForward() }, "hello")
        XCTAssertEqual(edit("hello, world", 6) { $0.deleteWordForward() }, "hello,")
        XCTAssertEqual(edit("(hello)", 0) { $0.deleteWordForward() }, ")")
        XCTAssertEqual(edit("ab\ncd ef", 5) { $0.deleteToBeginningOfLine() }, "ab\n ef")
        XCTAssertEqual(edit("ab\ncd ef", 3) { $0.deleteToBeginningOfLine() }, "ab\ncd ef")
        XCTAssertEqual(edit("ab\ncd ef\ngh", 4) { $0.deleteToEndOfParagraph() }, "ab\nc\ngh")
        XCTAssertEqual(edit("ab\ncd", 2) { $0.deleteToEndOfParagraph() }, "abcd")
        XCTAssertEqual(edit("ab\ncd", 5) { $0.deleteToEndOfParagraph() }, "ab\ncd")
        XCTAssertEqual(edit("ab\ncd ef\ngh", 4) { $0.deleteToEndOfLine() }, "ab\nc\ngh")
        XCTAssertEqual(edit("ab\ncd", 2) { $0.deleteToEndOfLine() }, "ab\ncd")
        // A selection wins over the word or line the key would otherwise delete.
        XCTAssertEqual(edit("hello world", 0) {
            $0.setSelection(2..<7)
            $0.deleteWordBackward()
        }, "heorld")
        XCTAssertEqual(edit("hello world", 0) {
            $0.setSelection(2..<7)
            $0.deleteToEndOfParagraph()
        }, "heorld")
    }

    func testReturnAndInsertReplaceTheSelection() {
        var session = MarkdownEditingSession(markdown: "abcdef", caretAtEnd: false)
        session.setSelection(2..<5)
        session.newline()
        XCTAssertEqual(session.markdown, "ab\nf")
        XCTAssertEqual(session.caret, 3)

        session = MarkdownEditingSession(markdown: "- hello world", caretAtEnd: false)
        let world = (session.display.text as NSString).range(of: "world")
        session.setSelection(world.location..<world.location + world.length)
        session.newline()
        XCTAssertFalse(session.markdown.contains("world"), session.markdown)
        XCTAssertTrue(session.markdown.contains("- hello"), session.markdown)
        XCTAssertTrue(session.markdown.contains("\n- ") || session.markdown.contains("\n"), session.markdown)

        session = MarkdownEditingSession(markdown: "abcdef", caretAtEnd: false)
        session.setSelection(2..<5)
        session.insert("XY")
        XCTAssertEqual(session.markdown, "abXYf")
        XCTAssertEqual(session.caret, 4)

        session = MarkdownEditingSession(
            markdown: "1. numbered itemhello\n2. hello2\n3. jajfdj\n4. another numbered item\n5. hello",
            caretAtEnd: false
        )
        let display = session.display.text as NSString
        let start = display.range(of: "hello").location
        let end = display.range(of: "jajfdj").location + ("jajfdj" as NSString).length
        session.setSelection(start..<end)
        session.insert("a")
        XCTAssertEqual(
            session.markdown,
            "1. numbered itema\n2. another numbered item\n3. hello"
        )
        XCTAssertTrue(session.selection.isEmpty)
        XCTAssertEqual(session.caret, start + 1)
        XCTAssertFalse(session.markdown.contains("hello2"), session.markdown)
        XCTAssertFalse(session.markdown.contains("jajfdj"), session.markdown)
    }

    func testSelectingInsideBoldDoesNotRewriteUntilTheCaretReturns() {
        var session = MarkdownEditingSession(markdown: "Ship **Friday** today.", caretAtEnd: false)
        let before = session.display.text
        XCTAssertFalse(before.contains("*"), before)
        let friday = (before as NSString).range(of: "Friday")
        session.setSelection(friday.location..<friday.location + friday.length)
        XCTAssertEqual(session.display.text, before)
        session.forwardDelete()
        XCTAssertFalse(session.markdown.contains("Friday"), session.markdown)
        XCTAssertFalse(session.markdown.contains("*"), session.markdown)

        session = MarkdownEditingSession(markdown: "Ship **Friday** today.", caretAtEnd: false)
        let partial = (session.display.text as NSString).range(of: "Friday")
        session.setSelection(partial.location..<partial.location + 3)
        session.backspace()
        XCTAssertTrue(session.markdown.contains("day"), session.markdown)
        XCTAssertTrue(session.markdown.contains("**"), session.markdown)
    }

    func testIndentShiftsEverySelectedLine() {
        var plain = MarkdownEditingSession(markdown: "abc", caretAtEnd: false)
        plain.moveCaret(to: 1)
        plain.indent(outdent: false)
        XCTAssertEqual(plain.markdown, "a  bc")
        plain.indent(outdent: true)
        XCTAssertEqual(plain.markdown, "a  bc")

        var lists = MarkdownEditingSession(markdown: "- one\n- two\n", caretAtEnd: false)
        lists.setSelection(0..<lists.displayLength)
        lists.indent(outdent: false)
        XCTAssertTrue(lists.markdown.contains("  - one"), lists.markdown)
        XCTAssertTrue(lists.markdown.contains("  - two"), lists.markdown)
        lists.indent(outdent: true)
        XCTAssertFalse(lists.markdown.contains("  -"), lists.markdown)
        XCTAssertTrue(lists.markdown.contains("- one"), lists.markdown)
        XCTAssertTrue(lists.markdown.contains("- two"), lists.markdown)

        var item = MarkdownEditingSession(markdown: "- item", caretAtEnd: true)
        item.indent(outdent: false)
        XCTAssertEqual(item.markdown, "  - item")
        item.indent(outdent: true)
        XCTAssertEqual(item.markdown, "- item")
    }

    func testEveryCaretBackspaceInsertAndNewlineStayConsistent() {
        var failures: [String] = []
        for document in documents {
            let seed = MarkdownEditingSession(markdown: document)
            let length = seed.displayLength
            for index in 0...length {
                check(document, at: index, failures: &failures)
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.prefix(12).joined(separator: "\n"))
    }

    private func check(_ document: String, at index: Int, failures: inout [String]) {
        if index > 0 {
            var session = MarkdownEditingSession(markdown: document, caretAtEnd: false)
            session.moveCaret(to: index)
            let before = session.caret
            let oldEnd = session.displayLength
            session.backspace()
            if session.display.sourceUTF16.count != session.display.text.utf16.count {
                failures.append("map drift after backspace in \(document.debugDescription) at \(index)")
            }
            if before < oldEnd && session.caret == session.displayLength && session.displayLength > 0
                && before < oldEnd - 1 {
                failures.append(
                    "backspace at \(before) jumped to end in \(document.debugDescription) → \(session.display.text.debugDescription)"
                )
            }
        }
        var inserted = MarkdownEditingSession(markdown: document, caretAtEnd: false)
        inserted.moveCaret(to: index)
        inserted.insert("x")
        if !inserted.markdown.contains("x") {
            failures.append("insert lost the character at \(index) in \(document.debugDescription)")
        }
        if inserted.caret == inserted.displayLength && index < inserted.displayLength - 1 && index > 0 {
            failures.append("insert at \(index) jumped to end in \(document.debugDescription)")
        }
        do {
            var session = MarkdownEditingSession(markdown: document, caretAtEnd: false)
            session.moveCaret(to: index)
            let before = session.caret
            session.forwardDelete()
            if session.display.sourceUTF16.count != session.display.text.utf16.count {
                failures.append("map drift after forward delete in \(document.debugDescription) at \(index)")
            }
            if before < session.displayLength - 1 && session.caret == session.displayLength && session.displayLength > 0 {
                failures.append(
                    "forward delete at \(before) jumped to end in \(document.debugDescription) → \(session.display.text.debugDescription)"
                )
            }
            var selected = MarkdownEditingSession(markdown: document, caretAtEnd: false)
            selected.moveCaret(to: index)
            let origin = selected.caret
            let upper = min(origin + 2, selected.displayLength)
            if upper > origin {
                selected.setSelection(origin..<upper)
                selected.backspace()
                if !selected.selection.isEmpty {
                    failures.append("selection delete left a range in \(document.debugDescription) at \(index)")
                }
                if selected.display.sourceUTF16.count != selected.display.text.utf16.count {
                    failures.append("map drift after selection delete in \(document.debugDescription) at \(index)")
                }
                if origin < selected.displayLength - 1 && selected.caret == selected.displayLength && selected.displayLength > 2 {
                    failures.append(
                        "selection delete at \(origin) jumped to end in \(document.debugDescription) → \(selected.display.text.debugDescription)"
                    )
                }
            }
        }
        var broken = MarkdownEditingSession(markdown: document, caretAtEnd: false)
        broken.moveCaret(to: index)
        let caretBeforeNewline = broken.caret
        broken.newline()
        if broken.display.sourceUTF16.count != broken.display.text.utf16.count {
            failures.append("map drift after newline in \(document.debugDescription)")
        }
        if caretBeforeNewline < broken.displayLength && broken.markdown.count > document.count
            && broken.caret == broken.displayLength && caretBeforeNewline < inserted.displayLength / 2 {
            // A newline in the first half must not land on the final caret
            // unless the insertion itself was at the end.
            if index < MarkdownEditingSession(markdown: document).displayLength - 1 {
                failures.append(
                    "newline at \(index) jumped to end in \(document.debugDescription) → \(broken.display.text.debugDescription)"
                )
            }
        }
    }

    func testClickTogglesImageAndURL() {
        let url = "https://example.com/a.png"
        let source = "![\(url)](data:image/png;base64,QQ==)\n"
        var session = MarkdownEditingSession(markdown: source, caretAtEnd: false)
        XCTAssertEqual(session.display.text, "\u{FFFC}\n")
        XCTAssertTrue(session.toggleShownImageURL(atDisplay: 0))
        XCTAssertEqual(session.display.text, url + "\n")
        XCTAssertTrue(session.toggleShownImageURL(atDisplay: 0))
        XCTAssertEqual(session.display.text, "\u{FFFC}\n")
    }

    func testReplacePlainImageURLBecomesThePicture() {
        let url = "https://example.com/a.png"
        var session = MarkdownEditingSession(markdown: "# Title\n\(url)\n")
        XCTAssertTrue(session.display.text.contains(url))
        XCTAssertTrue(session.replacePlainImageURL(
            url, withImage: "![\(url)](data:image/png;base64,QQ==)"
        ))
        XCTAssertTrue(session.markdown.contains("![\(url)](data:image/png;base64,QQ==)"))
        XCTAssertTrue(session.display.text.contains("\u{FFFC}"))
        XCTAssertFalse(session.display.text.contains(url))
        XCTAssertFalse(session.display.text.contains("data:image"))
    }

    func testReplacePlainImageURLSkipsAnExistingImage() {
        let url = "https://example.com/a.png"
        let source = "![\(url)](data:image/png;base64,QQ==)\n"
        var session = MarkdownEditingSession(markdown: source)
        let before = session.markdown
        XCTAssertFalse(session.replacePlainImageURL(url, withImage: "![x](u)"))
        XCTAssertEqual(session.markdown, before)
    }

    func testDeletingShownImageURLRemovesTheImage() {
        let url = "https://example.com/a.png"
        var session = MarkdownEditingSession(
            markdown: "before\n![\(url)](data:image/png;base64,QQ==)\nafter\n",
            caretAtEnd: false
        )
        let picture = (session.display.text as NSString).range(of: "\u{FFFC}")
        XCTAssertTrue(session.toggleShownImageURL(atDisplay: picture.location))
        let shown = session.display.text as NSString
        let range = shown.range(of: url)
        XCTAssertNotEqual(range.location, NSNotFound)
        session.setSelection(range.location..<range.location + range.length)
        session.deleteSelection()
        XCTAssertFalse(session.markdown.contains(url))
        XCTAssertFalse(session.markdown.contains("data:image"))
        XCTAssertTrue(session.markdown.contains("before"))
        XCTAssertTrue(session.markdown.contains("after"))
    }

    func testInsertImageLineShowsThePictureNotTheDataURI() {
        var session = MarkdownEditingSession(markdown: "# Title\nhello")
        session.insertImageLine("![pasted](data:image/png;base64,QQ==)")
        XCTAssertTrue(session.markdown.contains("![pasted](data:image/png;base64,QQ==)"))
        XCTAssertFalse(session.display.text.contains("data:image"), session.display.text)
        XCTAssertTrue(session.display.text.contains("\u{FFFC}"))
        XCTAssertEqual(session.display.sourceUTF16.count, session.display.text.utf16.count)
    }

    func testInsertImageLineBelowTheCaretLine() {
        var session = MarkdownEditingSession(markdown: "hello", caretAtEnd: false)
        session.moveCaret(to: 2)
        session.insertImageLine("![a](u)")
        XCTAssertEqual(session.markdown, "he![a](u)llo")
        XCTAssertEqual(session.display.text, "he\u{FFFC}llo")
    }

    func testKeystrokeCostWithEmbeddedImage() {
        let payload = String(repeating: "A", count: 400_000)
        let image = "![shot](data:image/png;base64,\(payload))"
        var session = MarkdownEditingSession(markdown: "# Title\nhello")
        let insertStart = Date()
        session.insertImageLine(image)
        let insert = Date().timeIntervalSince(insertStart)
        let backspaceStart = Date()
        session.backspace()
        let backspace = Date().timeIntervalSince(backspaceStart)
        var enter = 0.0
        for _ in 0..<5 {
            let start = Date()
            session.newline()
            enter += Date().timeIntervalSince(start)
        }
        XCTAssertLessThan(insert, 0.08, "insert took \(insert)")
        XCTAssertLessThan(backspace, 0.08, "backspace took \(backspace)")
        XCTAssertLessThan(enter, 0.05, "five enters took \(enter)")
        XCTAssertFalse(session.markdown.contains("base64"))
        XCTAssertTrue(session.markdown.hasPrefix("# Title\nhello"))
    }

    func testTwoImagesStayOnOneLineUntilANewline() {
        var session = MarkdownEditingSession(markdown: "hello", caretAtEnd: true)
        session.insertImageLine("![a](u)")
        session.insertImageLine("![b](v)")
        XCTAssertEqual(session.markdown, "hello![a](u)![b](v)")
        XCTAssertEqual(session.display.text, "hello\u{FFFC}\u{FFFC}")
        session.insert("\n")
        session.insertImageLine("![c](w)")
        XCTAssertTrue(session.display.text.contains("\u{FFFC}\u{FFFC}\n\u{FFFC}"), session.display.text)
    }
}
