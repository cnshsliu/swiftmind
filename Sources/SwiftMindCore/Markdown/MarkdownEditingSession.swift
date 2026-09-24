import Foundation

/// The note editor's state machine: display string, markdown source, reveal,
/// caret, and selection. AppKit applies the result; tests drive every key from here.
public struct MarkdownEditingSession: Equatable {
    public private(set) var markdown: String
    public private(set) var reveal: MarkdownDisplay.Reveal
    public private(set) var display: MarkdownDisplay
    /// UTF-16 index into `display.text`. While a selection is active this is
    /// its lower bound; edits collapse the selection back to a caret.
    public private(set) var caret: Int
    /// UTF-16 range in `display.text`. Empty means a caret.
    public private(set) var selection: Range<Int>

    public init(markdown: String, caretAtEnd: Bool = true) {
        let end = (markdown as NSString).length
        let (text, _) = MarkdownDocument.renumberOrderedLists(markdown, caret: end)
        self.markdown = text
        self.reveal = .none
        self.display = MarkdownDisplay.project(text, reveal: .none)
        self.caret = caretAtEnd ? display.text.utf16.count : 0
        self.selection = caret..<caret
    }

    public var displayLength: Int { display.text.utf16.count }

    public mutating func moveCaret(to index: Int) {
        caret = min(max(index, 0), displayLength)
        let sourceCaret = sourceOffset(at: caret)
        let next = MarkdownDisplay.reveal(atUTF16: sourceCaret, in: markdown)
        if next != reveal {
            reveal = next
            display = MarkdownDisplay.project(markdown, reveal: reveal)
            caret = min(display.displayIndex(forSourceUTF16: sourceCaret), displayLength)
        }
        selection = caret..<caret
    }

    /// Remember a display selection. A caret updates reveal. A non-empty
    /// selection does not: rewriting the projection would move the highlight
    /// off the characters the user selected.
    public mutating func setSelection(_ range: Range<Int>) {
        let length = displayLength
        let lower = min(max(range.lowerBound, 0), length)
        let upper = min(max(range.upperBound, 0), length)
        let start = min(lower, upper)
        let end = max(lower, upper)
        if start == end {
            moveCaret(to: start)
            return
        }
        selection = start..<end
        caret = start
    }

    /// Install markdown produced outside the session (bold, link, heading)
    /// and put the caret at a source UTF-16 offset.
    public mutating func replaceMarkdown(_ updated: String, sourceCaret: Int) {
        adopt(markdown: updated, sourceCaret: sourceCaret)
    }

    public mutating func insert(_ text: String) {
        replaceDisplay(utf16: editingRange, with: text)
    }

    public mutating func backspace() {
        if deleteSelectionIfPresent() { return }
        guard let range = grapheme(endingAt: caret) else { return }
        replaceDisplay(utf16: range, with: "")
    }

    public mutating func forwardDelete() {
        if deleteSelectionIfPresent() { return }
        guard let range = grapheme(startingAt: caret) else { return }
        replaceDisplay(utf16: range, with: "")
    }

    /// Edit → Delete, and the delete half of Cut. A caret deletes nothing.
    public mutating func deleteSelection() {
        _ = deleteSelectionIfPresent()
    }

    /// ⌃⌫. A composed character loses one combining mark; anything else
    /// deletes like Backspace. A selection is removed whole.
    public mutating func decomposeBackward() {
        if deleteSelectionIfPresent() { return }
        guard let range = grapheme(endingAt: caret) else { return }
        let cluster = utf16Slice(range)
        if let stripped = strippingOneMark(from: cluster) {
            replaceDisplay(utf16: range, with: stripped)
        } else {
            replaceDisplay(utf16: range, with: "")
        }
    }

    public mutating func deleteWordBackward() {
        if deleteSelectionIfPresent() { return }
        let start = wordBoundary(before: caret)
        guard start < caret else { return }
        replaceDisplay(utf16: start..<caret, with: "")
    }

    public mutating func deleteWordForward() {
        if deleteSelectionIfPresent() { return }
        let end = wordBoundary(after: caret)
        guard end > caret else { return }
        replaceDisplay(utf16: caret..<end, with: "")
    }

    /// ⌘⌫. Deletes back to the start of the line. Already there, it does nothing.
    public mutating func deleteToBeginningOfLine() {
        if deleteSelectionIfPresent() { return }
        let start = lineStart(containing: caret)
        guard start < caret else { return }
        replaceDisplay(utf16: start..<caret, with: "")
    }

    /// ⌃K. Mid-line, deletes through the end of the line and keeps the break.
    /// At the break, deletes the break.
    public mutating func deleteToEndOfParagraph() {
        if deleteSelectionIfPresent() { return }
        let end = paragraphKillEnd(from: caret)
        guard end > caret else { return }
        replaceDisplay(utf16: caret..<end, with: "")
    }

    /// Deletes through the end of the line and keeps the line break.
    public mutating func deleteToEndOfLine() {
        if deleteSelectionIfPresent() { return }
        let end = lineContentEnd(containing: caret)
        guard end > caret else { return }
        replaceDisplay(utf16: caret..<end, with: "")
    }

    /// Tab / ⇧Tab. A list line, or a selection that covers more than one
    /// line, shifts those lines by two spaces. A caret or selection on a
    /// single non-list line inserts two spaces, and ⇧Tab does nothing.
    public mutating func indent(outdent: Bool) {
        let source = markdown as NSString
        if source.length == 0 {
            if !outdent { insert("  ") }
            return
        }
        let sourceStart = min(max(sourceOffset(at: selection.lowerBound), 0), source.length)
        let sourceEnd = min(max(sourceOffset(at: selection.upperBound), sourceStart), source.length)
        let first = source.lineRange(for: NSRange(location: min(sourceStart, source.length - 1), length: 0))
        let lastIndex = sourceEnd > sourceStart ? sourceEnd - 1 : sourceStart
        let last = source.lineRange(for: NSRange(location: min(lastIndex, source.length - 1), length: 0))
        let multi = first.location != last.location
        if !multi {
            let content = Self.contentLine(containing: sourceStart, in: source)
            if Self.listMarker(in: source, content: content) == nil {
                if !outdent { insert("  ") }
                return
            }
        }

        var output = ""
        var deltas: [(lineStart: Int, delta: Int)] = []
        var cursor = 0
        while cursor < source.length {
            let full = source.lineRange(for: NSRange(location: cursor, length: 0))
            let raw = source.substring(with: full)
            let newlineLength = raw.hasSuffix("\r\n") ? 2 : (raw.hasSuffix("\n") || raw.hasSuffix("\r") ? 1 : 0)
            let content = String(raw.dropLast(newlineLength))
            let ending = String(raw.suffix(newlineLength))
            let contentLength = (content as NSString).length
            let contentEnd = full.location + contentLength
            let caretOnLine = sourceStart >= full.location && sourceStart <= contentEnd
            let overlaps = sourceStart < full.upperBound && sourceEnd > full.location
            let hit = sourceStart == sourceEnd ? caretOnLine : overlaps
            var delta = 0
            var rewritten = content
            if hit {
                if outdent {
                    let remove = Self.leadingSpaceCount(content, max: 2)
                    if remove > 0 {
                        rewritten = (content as NSString).substring(from: remove)
                        delta = -remove
                    }
                } else {
                    rewritten = "  " + content
                    delta = 2
                }
            }
            if delta != 0 {
                deltas.append((lineStart: full.location, delta: delta))
            }
            output += rewritten + ending
            let next = full.upperBound
            guard next > cursor else { break }
            cursor = next
        }
        guard !deltas.isEmpty else { return }
        func map(_ offset: Int) -> Int {
            var result = offset
            for item in deltas where offset >= item.lineStart {
                let removed = max(0, -item.delta)
                if removed > 0, offset < item.lineStart + removed {
                    result -= offset - item.lineStart
                } else {
                    result += item.delta
                }
            }
            return max(0, result)
        }
        let mappedStart = map(sourceStart)
        let mappedEnd = map(sourceEnd)
        let selection = mappedStart == mappedEnd ? nil : mappedStart..<mappedEnd
        adopt(
            markdown: output,
            sourceCaret: mappedStart,
            sourceSelection: selection
        )
    }

    /// Return. A selection is removed first, then the key behaves as it
    /// would at the caret that remains. A list item continues with the same
    /// marker (`- `, `1. `, …). A quote continues with `> `. The caret sits
    /// just after that marker. An empty item or quote clears its marker instead.
    public mutating func newline() {
        if !selection.isEmpty {
            replaceDisplay(utf16: selection, with: "")
        }
        let ns = markdown as NSString
        let sourceCaret = min(sourceOffset(at: caret), ns.length)
        let line = Self.contentLine(containing: sourceCaret, in: ns)
        if let marker = Self.listMarker(in: ns, content: line) {
            let rest = ns.substring(with: NSRange(
                location: marker.range.upperBound,
                length: max(0, line.upperBound - marker.range.upperBound)
            ))
            if rest.trimmingCharacters(in: .whitespaces).isEmpty {
                replaceSource(
                    utf16: marker.range.location..<(marker.range.location + marker.range.length),
                    with: ""
                )
            } else {
                let insertion = "\n" + String(repeating: " ", count: marker.indent) + marker.continuation
                replaceSource(utf16: sourceCaret..<sourceCaret, with: insertion)
            }
            return
        }
        if let quote = Self.quoteMarker(in: ns, content: line) {
            let rest = ns.substring(with: NSRange(
                location: quote.upperBound,
                length: max(0, line.upperBound - quote.upperBound)
            ))
            if rest.trimmingCharacters(in: .whitespaces).isEmpty {
                replaceSource(utf16: quote.location..<(quote.location + quote.length), with: "")
            } else {
                replaceSource(utf16: sourceCaret..<sourceCaret, with: "\n> ")
            }
            return
        }
        replaceDisplay(utf16: caret..<caret, with: "\n")
    }

    private mutating func replaceSource(utf16 range: Range<Int>, with replacement: String) {
        let ns = markdown as NSString
        let location = min(max(range.lowerBound, 0), ns.length)
        let length = min(max(range.count, 0), ns.length - location)
        let updated = ns.replacingCharacters(
            in: NSRange(location: location, length: length),
            with: replacement
        )
        let sourceCaret = min(location + (replacement as NSString).length, (updated as NSString).length)
        adopt(markdown: updated, sourceCaret: sourceCaret)
    }

    public mutating func replaceDisplay(utf16 range: Range<Int>, with replacement: String) {
        let edit = display.applyingEdit(
            source: markdown,
            displayUTF16: range,
            replacement: replacement
        )
        adopt(markdown: edit.markdown, sourceCaret: edit.caretUTF16)
    }

    private mutating func adopt(
        markdown updated: String,
        sourceCaret: Int,
        sourceSelection: Range<Int>? = nil
    ) {
        let (text, caret) = MarkdownDocument.renumberOrderedLists(updated, caret: sourceCaret)
        markdown = text
        reveal = MarkdownDisplay.reveal(atUTF16: caret, in: text)
        display = MarkdownDisplay.project(text, reveal: reveal)
        self.caret = min(display.displayIndex(forSourceUTF16: caret), displayLength)
        if let sourceSelection, !sourceSelection.isEmpty {
            let (_, start) = MarkdownDocument.renumberOrderedLists(updated, caret: sourceSelection.lowerBound)
            let (_, end) = MarkdownDocument.renumberOrderedLists(updated, caret: sourceSelection.upperBound)
            let lower = min(display.displayIndex(forSourceUTF16: start), displayLength)
            let upper = min(max(display.displayIndex(forSourceUTF16: end), lower), displayLength)
            selection = lower..<upper
            self.caret = lower
        } else {
            selection = self.caret..<self.caret
        }
    }

    private var editingRange: Range<Int> {
        selection.isEmpty ? caret..<caret : selection
    }

    @discardableResult
    private mutating func deleteSelectionIfPresent() -> Bool {
        guard !selection.isEmpty else { return false }
        replaceDisplay(utf16: selection, with: "")
        return true
    }

    private func grapheme(endingAt caret: Int) -> Range<Int>? {
        var utf16 = 0
        for character in display.text {
            let next = utf16 + character.utf16.count
            if utf16 < caret && next >= caret { return utf16..<next }
            if next > caret { break }
            utf16 = next
        }
        return nil
    }

    private func grapheme(startingAt caret: Int) -> Range<Int>? {
        var utf16 = 0
        for character in display.text {
            let next = utf16 + character.utf16.count
            if next > caret { return utf16..<next }
            utf16 = next
        }
        return nil
    }

    private func utf16Slice(_ range: Range<Int>) -> String {
        let ns = display.text as NSString
        let location = min(max(range.lowerBound, 0), ns.length)
        let length = min(max(range.count, 0), ns.length - location)
        return ns.substring(with: NSRange(location: location, length: length))
    }

    /// Drop one trailing combining mark from a decomposed cluster.
    /// A family emoji or other ZWJ sequence is left whole.
    private func strippingOneMark(from cluster: String) -> String? {
        var scalars = Array(cluster.decomposedStringWithCanonicalMapping.unicodeScalars)
        guard let last = scalars.last, last.properties.canonicalCombiningClass.rawValue != 0 else { return nil }
        scalars.removeLast()
        guard !scalars.isEmpty else { return nil }
        return String(String.UnicodeScalarView(scalars))
    }

    private struct WordSpan {
        var start: Int
        var end: Int
    }

    private func wordSpans() -> [WordSpan] {
        let ns = display.text as NSString
        var spans: [WordSpan] = []
        ns.enumerateSubstrings(
            in: NSRange(location: 0, length: ns.length),
            options: [.byWords]
        ) { _, range, _, _ in
            spans.append(WordSpan(start: range.location, end: range.location + range.length))
        }
        return spans
    }

    /// Where ⌥← would land, which is the start of the range ⌥⌫ deletes.
    private func wordBoundary(before index: Int) -> Int {
        if index <= 0 { return 0 }
        let spans = wordSpans()
        if let word = spans.first(where: { $0.start < index && index <= $0.end }) {
            return word.start
        }
        if let word = spans.first(where: { $0.start == index }),
           let previous = spans.last(where: { $0.start < word.start }) {
            return previous.start
        }
        if spans.contains(where: { $0.start == index }) { return 0 }
        if let previous = spans.last(where: { $0.end <= index }) {
            return previous.start
        }
        return 0
    }

    /// Where ⌥→ would land, which is the end of the range ⌥⌦ deletes.
    /// With no following word, only trailing whitespace is consumed.
    private func wordBoundary(after index: Int) -> Int {
        let length = displayLength
        if index >= length { return length }
        let spans = wordSpans()
        if let word = spans.first(where: { $0.start <= index && index < $0.end }) {
            return word.end
        }
        if let next = spans.first(where: { $0.start >= index }) {
            return next.end
        }
        let ns = display.text as NSString
        var cursor = index
        while cursor < ns.length {
            let character = ns.character(at: cursor)
            guard character == 32 || character == 9 || character == 10 || character == 13 else { break }
            cursor += 1
        }
        return cursor
    }

    private func lineStart(containing index: Int) -> Int {
        let ns = display.text as NSString
        guard ns.length > 0 else { return 0 }
        let probe = min(max(index, 0), ns.length)
        // A caret parked after the final newline belongs to the empty last line.
        let location = probe == ns.length && probe > 0 ? probe - 1 : probe
        if probe == ns.length, ns.character(at: ns.length - 1) == 10 || ns.character(at: ns.length - 1) == 13 {
            return ns.length
        }
        return ns.lineRange(for: NSRange(location: min(location, max(ns.length - 1, 0)), length: 0)).location
    }

    private func lineContentEnd(containing index: Int) -> Int {
        let ns = display.text as NSString
        guard ns.length > 0, index < ns.length else { return ns.length }
        let full = ns.lineRange(for: NSRange(location: min(index, ns.length - 1), length: 0))
        var end = full.upperBound
        while end > full.location {
            let character = ns.character(at: end - 1)
            if character == 10 || character == 13 { end -= 1 } else { break }
        }
        return end
    }

    private func paragraphKillEnd(from index: Int) -> Int {
        let ns = display.text as NSString
        guard index < ns.length else { return ns.length }
        let character = ns.character(at: index)
        if character == 10 { return index + 1 }
        if character == 13 {
            if index + 1 < ns.length, ns.character(at: index + 1) == 10 { return index + 2 }
            return index + 1
        }
        return lineContentEnd(containing: index)
    }

    private static func leadingSpaceCount(_ content: String, max: Int) -> Int {
        let ns = content as NSString
        var count = 0
        while count < min(max, ns.length), ns.character(at: count) == 32 { count += 1 }
        return count
    }

    private func sourceOffset(at displayIndex: Int) -> Int {
        let map = display.sourceUTF16
        if displayIndex <= 0 { return 0 }
        if displayIndex >= map.count { return (markdown as NSString).length }
        return map[displayIndex]
    }

    private static func contentLine(containing location: Int, in ns: NSString) -> NSRange {
        guard ns.length > 0 else { return NSRange(location: 0, length: 0) }
        let full = ns.lineRange(for: NSRange(location: min(location, ns.length), length: 0))
        var content = full
        while content.length > 0 {
            let c = ns.character(at: content.location + content.length - 1)
            if c == 10 || c == 13 { content.length -= 1 } else { break }
        }
        return content
    }

    private static func listMarker(
        in ns: NSString, content: NSRange
    ) -> (indent: Int, range: NSRange, continuation: String)? {
        var i = content.location
        let end = content.upperBound
        var indent = 0
        while i < end, ns.character(at: i) == 32 { i += 1; indent += 1 }
        guard i < end else { return nil }
        let rest = ns.substring(with: NSRange(location: i, length: end - i))
        if rest.hasPrefix("- [ ] ") || rest.hasPrefix("- [x] ") || rest.hasPrefix("- [X] ") {
            return (indent, NSRange(location: i, length: 6), "- [ ] ")
        }
        if rest.hasPrefix("- ") || rest.hasPrefix("* ") {
            return (indent, NSRange(location: i, length: 2), String(rest.prefix(2)))
        }
        var digits = 0
        var number = 0
        while digits < rest.count, rest[rest.index(rest.startIndex, offsetBy: digits)].isNumber {
            number = number * 10 + Int(String(rest[rest.index(rest.startIndex, offsetBy: digits)]))!
            digits += 1
        }
        let after = rest.dropFirst(digits)
        guard digits > 0, after.hasPrefix(". ") else { return nil }
        return (indent, NSRange(location: i, length: digits + 2), "\(number + 1). ")
    }

    /// `> ` at the start of a source line, after indentation.
    private static func quoteMarker(in ns: NSString, content: NSRange) -> NSRange? {
        var i = content.location
        let end = content.upperBound
        while i < end, ns.character(at: i) == 32 { i += 1 }
        guard i < end, ns.character(at: i) == 62 /* > */ else { return nil }
        var markerEnd = i + 1
        if markerEnd < end, ns.character(at: markerEnd) == 32 { markerEnd += 1 }
        return NSRange(location: i, length: markerEnd - i)
    }
}
