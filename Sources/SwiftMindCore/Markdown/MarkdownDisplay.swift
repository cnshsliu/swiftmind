import Foundation

public struct MarkdownDisplay: Equatable, Sendable {
    public var text: String
    /// Source UTF-16 offset for each UTF-16 unit of `text`.
    public var sourceUTF16: [Int]

    public enum Reveal: Equatable, Sendable {
        case none
        case inline(Range<String.Index>)
        case block(Range<String.Index>)
    }

    public init(text: String, sourceUTF16: [Int]) {
        self.text = text
        self.sourceUTF16 = sourceUTF16
    }

    /// The smallest edit that turns `old` into `new`.
    public static func displayChange(from old: String, to new: String) -> (range: Range<Int>, replacement: String) {
        let oldUnits = Array(old.utf16)
        let newUnits = Array(new.utf16)
        var prefix = 0
        while prefix < oldUnits.count && prefix < newUnits.count && oldUnits[prefix] == newUnits[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < (oldUnits.count - prefix) && suffix < (newUnits.count - prefix)
                && oldUnits[oldUnits.count - 1 - suffix] == newUnits[newUnits.count - 1 - suffix] {
            suffix += 1
        }
        let replacement = String(
            decoding: newUnits[prefix..<(newUnits.count - suffix)],
            as: UTF16.self
        )
        return (prefix..<(oldUnits.count - suffix), replacement)
    }

    /// `shownImageURLs` lists image alt texts (the original http URL) that
    /// display as that address instead of the picture. The markdown is unchanged.
    public static func project(
        _ source: String,
        reveal: Reveal,
        shownImageURLs: Set<String> = []
    ) -> MarkdownDisplay {
        var text = ""
        var map: [Int] = []
        let end = appendBlocks(
            MarkdownDocument.parse(source).blocks,
            source: source,
            reveal: reveal,
            shownImageURLs: shownImageURLs,
            from: source.startIndex,
            into: &text,
            map: &map
        )
        // Blank lines are not blocks; keep the newlines the parser skipped.
        if end < source.endIndex {
            appendSource(end..<source.endIndex, source: source, into: &text, map: &map)
        }
        return MarkdownDisplay(text: text, sourceUTF16: map)
    }

    /// Map a display edit back onto markdown. An empty range inserts and does not
    /// delete hidden markers. A non-empty range replaces only the source units of
    /// the display units it covers, not markers in the gaps outside that range.
    public func splicing(source: String, displayReplacement: String, displayUTF16: Range<Int>) -> String {
        applyingEdit(
            source: source,
            displayUTF16: displayUTF16,
            replacement: displayReplacement
        ).markdown
    }

    /// Apply a display edit and return the caret in the new markdown, in
    /// UTF-16 offsets. The caret sits where the replacement ends, clamped to
    /// the new string so a deletion cannot jump to the old end.
    public func applyingEdit(
        source: String,
        displayUTF16: Range<Int>,
        replacement: String
    ) -> (markdown: String, caretUTF16: Int) {
        let bounds = sourceBounds(displayUTF16: displayUTF16, source: source)
        let ns = source as NSString
        let markdown = ns.replacingCharacters(in: bounds, with: replacement)
        let caret = min(
            bounds.location + (replacement as NSString).length,
            (markdown as NSString).length
        )
        return (markdown, caret)
    }

    /// Display index of a caret that sits before the source offset `caret`.
    /// A hole (hidden markers) stays between the surrounding visible
    /// characters. It does not fall through to the end of the note.
    public func displayIndex(forSourceUTF16 caret: Int) -> Int {
        guard !sourceUTF16.isEmpty else { return 0 }
        if caret <= sourceUTF16[0] { return 0 }
        if let exact = sourceUTF16.firstIndex(of: caret) { return exact }
        if let prior = sourceUTF16.lastIndex(where: { $0 < caret }) {
            return min(prior + 1, sourceUTF16.count)
        }
        return 0
    }

    private func sourceBounds(displayUTF16: Range<Int>, source: String) -> NSRange {
        let mapCount = sourceUTF16.count
        let sourceCount = source.utf16.count
        let lower = displayUTF16.lowerBound
        let upper = displayUTF16.upperBound
        let start: Int
        let end: Int
        if lower == upper {
            if lower >= 0 && lower < mapCount {
                start = sourceUTF16[lower]
            } else if lower <= 0 {
                start = 0
            } else {
                start = sourceCount
            }
            end = start
        } else if mapCount == 0 || lower >= mapCount || upper <= 0 {
            start = lower <= 0 ? 0 : sourceCount
            end = start
        } else {
            let first = min(max(lower, 0), mapCount - 1)
            let last = min(max(upper - 1, 0), mapCount - 1)
            let rawStart = sourceUTF16[first]
            let rawEnd = sourceUTF16[last] + 1
            let displaySlice = utf16Slice(of: text, range: displayUTF16)
            (start, end) = expandedEdit(
                start: rawStart,
                end: rawEnd,
                source: source,
                displaySlice: displaySlice
            )
        }
        let location = min(max(start, 0), sourceCount)
        let limit = min(max(end, location), sourceCount)
        return NSRange(location: location, length: limit - location)
    }

    /// Source UTF-16 offset where the caret should sit after `splicing`.
    public func sourceCaretUTF16(
        displayReplacement: String,
        displayUTF16: Range<Int>,
        source: String
    ) -> Int {
        applyingEdit(
            source: source,
            displayUTF16: displayUTF16,
            replacement: displayReplacement
        ).caretUTF16
    }

    /// Wrap `rangeUTF16` in `marker`, or remove a matching pair already around it.
    public static func wrap(_ source: String, rangeUTF16: Range<Int>, marker: String) -> String {
        let ns = source as NSString
        let location = min(max(rangeUTF16.lowerBound, 0), ns.length)
        let length = min(max(rangeUTF16.count, 0), ns.length - location)
        let range = NSRange(location: location, length: length)
        let markerLength = (marker as NSString).length
        if range.location >= markerLength,
           range.location + range.length + markerLength <= ns.length,
           ns.substring(with: NSRange(location: range.location - markerLength, length: markerLength)) == marker,
           ns.substring(with: NSRange(location: range.location + range.length, length: markerLength)) == marker {
            let outer = NSRange(
                location: range.location - markerLength,
                length: range.length + markerLength * 2
            )
            return ns.replacingCharacters(in: outer, with: ns.substring(with: range))
        }
        let inner = range.length > 0 ? ns.substring(with: range) : ""
        return ns.replacingCharacters(in: range, with: marker + inner + marker)
    }

    /// Marks to show for a caret at this source UTF-16 offset.
    /// A heading reveals its `#` prefix anywhere on that line.
    public static func reveal(atUTF16 offset: Int, in source: String) -> Reveal {
        guard !source.isEmpty else { return .none }
        let clamped = min(max(offset, 0), source.utf16.count)
        let index = String.Index(utf16Offset: clamped, in: source)
        let doc = MarkdownDocument.parse(source)
        if let block = blockContaining(index, in: doc.blocks) {
            switch block.kind {
            case .heading:
                return .block(block.marker)
            // An image stays the picture. Revealing a data URI would replace
            // it with a wall of base64 the moment the caret lands on it.
            case .image:
                break
            case .codeFence, .mathBlock, .table:
                return .block(block.source)
            case .quote:
                return .block(block.marker)
            case .divider:
                return .block(block.source)
            case .listItem:
                if index < block.marker.upperBound { return .block(block.marker) }
            case .paragraph:
                break
            }
        }
        if let inline = inlineContaining(index, in: doc.blocks) {
            if case .text = inline { return .none }
            return .inline(contentRange(of: inline))
        }
        return .none
    }

    private static func inlineContaining(_ index: String.Index, in blocks: [MarkdownBlock]) -> MarkdownInline? {
        for block in blocks {
            if let found = inlineContaining(index, in: block.inlines) { return found }
            if let found = inlineContaining(index, in: block.children) { return found }
        }
        return nil
    }

    private static func inlineContaining(_ index: String.Index, in inlines: [MarkdownInline]) -> MarkdownInline? {
        for item in inlines {
            switch item {
            case .text(let range):
                if range.contains(index) { return item }
            case .strong(let open, let content, let close),
                 .emphasis(let open, let content, let close),
                 .strikethrough(let open, let content, let close),
                 .highlight(let open, let content, let close):
                if (open.lowerBound..<close.upperBound).contains(index) {
                    // The words are a `.text` child. The caret is on this span,
                    // so reveal these markers unless a nested span is tighter.
                    if let inner = inlineContaining(index, in: content), case .text = inner {
                        return item
                    }
                    return inlineContaining(index, in: content) ?? item
                }
            case .code(let open, _, let close), .math(let open, _, let close),
                 .kbd(let open, _, let close):
                if (open.lowerBound..<close.upperBound).contains(index) { return item }
            case .link(let labelOpen, let label, _, _, let close):
                if (labelOpen.lowerBound..<close.upperBound).contains(index) {
                    if let inner = inlineContaining(index, in: label), case .text = inner {
                        return item
                    }
                    return inlineContaining(index, in: label) ?? item
                }
            case .image(let alt, let url):
                if alt.contains(index) || url.contains(index) { return item }
            }
        }
        return nil
    }

    /// Set the heading level of the block containing `atUTF16`, or the first
    /// block when the offset is omitted. A paragraph gains a prefix.
    public static func setHeading(_ source: String, level: Int, atUTF16: Int? = nil) -> String {
        let clamped = min(6, max(1, level))
        let prefix = String(repeating: "#", count: clamped) + " "
        let doc = MarkdownDocument.parse(source)
        let block: MarkdownBlock?
        if let atUTF16 {
            let index = String.Index(utf16Offset: min(max(atUTF16, 0), source.utf16.count), in: source)
            block = blockContaining(index, in: doc.blocks) ?? doc.blocks.first
        } else {
            block = doc.blocks.first
        }
        guard let block else { return prefix + source }
        let ns = source as NSString
        if case .heading = block.kind {
            let marker = NSRange(block.marker, in: source)
            if marker.length > 0 {
                return ns.replacingCharacters(in: marker, with: prefix)
            }
        }
        let start = NSRange(block.source, in: source).location
        return ns.replacingCharacters(in: NSRange(location: start, length: 0), with: prefix)
    }

    private static func blockContaining(_ index: String.Index, in blocks: [MarkdownBlock]) -> MarkdownBlock? {
        for block in blocks {
            if let child = blockContaining(index, in: block.children) { return child }
            if block.source.contains(index) || index == block.source.upperBound { return block }
        }
        return nil
    }

    private static func appendBlocks(
        _ blocks: [MarkdownBlock],
        source: String,
        reveal: Reveal,
        shownImageURLs: Set<String>,
        from start: String.Index,
        into text: inout String,
        map: inout [Int]
    ) -> String.Index {
        var cursor = start
        for (offset, block) in blocks.enumerated() {
            if block.source.lowerBound > cursor {
                appendSource(cursor..<block.source.lowerBound, source: source, into: &text, map: &map)
            }
            appendBlock(
                block,
                source: source,
                reveal: reveal,
                shownImageURLs: shownImageURLs,
                anotherFollows: offset + 1 < blocks.count,
                into: &text,
                map: &map
            )
            if block.source.upperBound > cursor {
                cursor = block.source.upperBound
            }
        }
        return cursor
    }

    private static func appendBlock(
        _ block: MarkdownBlock,
        source: String,
        reveal: Reveal,
        shownImageURLs: Set<String>,
        anotherFollows: Bool,
        into text: inout String,
        map: inout [Int]
    ) {
        // Image, fence, and math are the raw source when revealed. A heading,
        // list, or quote keeps its rendered body after the marker.
        if case .block(let range) = reveal {
            if block.source == range || (block.marker == range && showsRawWhenMarkerRevealed(block)) {
                appendSource(block.source, source: source, into: &text, map: &map)
                return
            }
            if block.marker == range, case .listItem = block.kind {
                // List markers stay visible; the body path appends them once.
            } else if block.marker == range {
                appendSource(block.marker, source: source, into: &text, map: &map)
            }
        }
        switch block.kind {
        case .image(let alt, _):
            let altText = String(source[alt])
            // Click toggles between the picture and the original http URL.
            // The data URI stays in the markdown either way.
            if shownImageURLs.contains(altText),
               altText.hasPrefix("http://") || altText.hasPrefix("https://") {
                appendSource(alt, source: source, into: &text, map: &map)
            } else {
                // U+FFFC replaces the image syntax, not the line break after it.
                let offset = utf16Offset(of: alt.lowerBound, in: source) ?? 0
                appendMapped("\u{FFFC}", sourceOffset: offset, into: &text, map: &map)
            }
            if sourceContainsNewline(block, source: source) || anotherFollows {
                appendLineBreak(block, source: source, into: &text, map: &map)
            }
        case .codeFence:
            // The parser's text range drops the newline before the closer, which
            // deletes a trailing blank line. The interior is everything after the
            // opening line and before the closing delimiter line.
            let interior = block.marker.upperBound..<closingLineStart(block, source: source)
            appendSource(interior, source: source, into: &text, map: &map)
        case .mathBlock:
            // A one-line `$$…$$` still owns its trailing newline, so "source
            // contains a newline" is not the multiline test. The opener is
            // its own line only when the marker itself contains a newline.
            if source[block.marker].contains("\n") {
                let interior = block.marker.upperBound..<closingLineStart(block, source: source)
                appendSource(interior, source: source, into: &text, map: &map)
            } else if case .text(let latex)? = block.inlines.first {
                appendSource(latex, source: source, into: &text, map: &map)
                if sourceContainsNewline(block, source: source) || anotherFollows {
                    appendLineBreak(block, source: source, into: &text, map: &map)
                }
            }
        case .table:
            // Raw pipes while editing (like a code fence); the styled view
            // renders the grid.
            appendSource(block.source, source: source, into: &text, map: &map)
        case .divider:
            // The rule renders as a hairline in the styled view; the editing
            // projection keeps the raw `---` line so the caret can edit it.
            let lineEnd = block.source.upperBound > block.source.lowerBound
                && source[block.source].hasSuffix("\n")
                ? source.index(before: block.source.upperBound)
                : block.source.upperBound
            appendSource(block.source.lowerBound..<lineEnd, source: source, into: &text, map: &map)
            if sourceContainsNewline(block, source: source) || anotherFollows {
                appendLineBreak(block, source: source, into: &text, map: &map)
            }
        case .heading, .paragraph, .listItem, .quote:
            if case .listItem = block.kind {
                appendSource(
                    block.source.lowerBound..<block.marker.upperBound,
                    source: source,
                    into: &text,
                    map: &map
                )
            }
            appendInlines(
                block.inlines, source: source, reveal: reveal,
                shownImageURLs: shownImageURLs, into: &text, map: &map
            )
            var childStart = coverageEnd(block)
            if sourceContainsNewline(block, source: source) || anotherFollows || !block.children.isEmpty {
                childStart = appendLineBreak(block, source: source, into: &text, map: &map)
            }
            _ = appendBlocks(
                block.children,
                source: source,
                reveal: reveal,
                shownImageURLs: shownImageURLs,
                from: childStart,
                into: &text,
                map: &map
            )
        }
    }

    private static func appendInlines(
        _ inlines: [MarkdownInline],
        source: String,
        reveal: Reveal,
        shownImageURLs: Set<String>,
        into text: inout String,
        map: inout [Int]
    ) {
        for inline in inlines {
            switch inline {
            case .text(let range):
                appendSource(range, source: source, into: &text, map: &map)
            case .strong(let open, let content, let close),
                 .emphasis(let open, let content, let close),
                 .strikethrough(let open, let content, let close),
                 .highlight(let open, let content, let close):
                if inlineRevealed(inline, reveal: reveal) {
                    appendSource(open, source: source, into: &text, map: &map)
                    appendInlines(content, source: source, reveal: reveal, shownImageURLs: shownImageURLs, into: &text, map: &map)
                    appendSource(close, source: source, into: &text, map: &map)
                } else {
                    appendInlines(content, source: source, reveal: reveal, shownImageURLs: shownImageURLs, into: &text, map: &map)
                }
            case .code(let open, let content, let close):
                if inlineRevealed(inline, reveal: reveal) {
                    appendSource(open, source: source, into: &text, map: &map)
                    appendSource(content, source: source, into: &text, map: &map)
                    appendSource(close, source: source, into: &text, map: &map)
                } else {
                    appendSource(content, source: source, into: &text, map: &map)
                }
            case .kbd(let open, let label, let close):
                if inlineRevealed(inline, reveal: reveal) {
                    appendSource(open, source: source, into: &text, map: &map)
                    appendSource(label, source: source, into: &text, map: &map)
                    appendSource(close, source: source, into: &text, map: &map)
                } else {
                    appendSource(label, source: source, into: &text, map: &map)
                }
            case .math(let open, let latex, let close):
                if inlineRevealed(inline, reveal: reveal) {
                    appendSource(open, source: source, into: &text, map: &map)
                    appendSource(latex, source: source, into: &text, map: &map)
                    appendSource(close, source: source, into: &text, map: &map)
                } else {
                    appendSource(latex, source: source, into: &text, map: &map)
                }
            case .link(let labelOpen, let label, let labelClose, let url, let close):
                if inlineRevealed(inline, reveal: reveal) {
                    appendSource(labelOpen, source: source, into: &text, map: &map)
                    appendInlines(label, source: source, reveal: reveal, shownImageURLs: shownImageURLs, into: &text, map: &map)
                    appendSource(labelClose, source: source, into: &text, map: &map)
                    appendSource(url, source: source, into: &text, map: &map)
                    appendSource(close, source: source, into: &text, map: &map)
                } else {
                    appendInlines(label, source: source, reveal: reveal, shownImageURLs: shownImageURLs, into: &text, map: &map)
                }
            case .image(let alt, _):
                let altText = String(source[alt])
                if shownImageURLs.contains(altText),
                   altText.hasPrefix("http://") || altText.hasPrefix("https://") {
                    appendSource(alt, source: source, into: &text, map: &map)
                } else {
                    let offset = utf16Offset(of: alt.lowerBound, in: source) ?? 0
                    appendMapped("\u{FFFC}", sourceOffset: offset, into: &text, map: &map)
                }
            }
        }
    }

    private static func showsRawWhenMarkerRevealed(_ block: MarkdownBlock) -> Bool {
        switch block.kind {
        case .image, .codeFence, .mathBlock, .divider, .table:
            return true
        case .heading, .paragraph, .listItem, .quote:
            return false
        }
    }

    /// A whole-span delete includes the hidden markers. An image object
    /// character stands for the whole image line. A partial edit does not.
    private func expandedEdit(start: Int, end: Int, source: String, displaySlice: String) -> (Int, Int) {
        var lo = start
        var hi = end
        func offset(_ index: String.Index) -> Int {
            Self.utf16Offset(of: index, in: source) ?? lo
        }
        func cover(open: Range<String.Index>, content: Range<String.Index>, close: Range<String.Index>) {
            let contentStart = offset(content.lowerBound)
            let contentEnd = offset(content.upperBound)
            guard contentStart < contentEnd, lo <= contentStart, hi >= contentEnd else { return }
            lo = min(lo, offset(open.lowerBound))
            hi = max(hi, offset(close.upperBound))
        }
        func walkInlines(_ inlines: [MarkdownInline]) {
            for inline in inlines {
                switch inline {
                case .text:
                    break
                case .strong(let open, let content, let close),
                     .emphasis(let open, let content, let close),
                     .strikethrough(let open, let content, let close),
                     .highlight(let open, let content, let close):
                    cover(open: open, content: open.upperBound..<close.lowerBound, close: close)
                    walkInlines(content)
                case .code(let open, let content, let close),
                     .math(let open, let content, let close),
                     .kbd(let open, let content, let close):
                    cover(open: open, content: content, close: close)
                case .link(let labelOpen, let label, let labelClose, _, let close):
                    cover(
                        open: labelOpen,
                        content: labelOpen.upperBound..<labelClose.lowerBound,
                        close: close
                    )
                    walkInlines(label)
                case .image(let alt, let url):
                    let altText = String(source[alt])
                    let wholeImage = displaySlice == "\u{FFFC}"
                        || (displaySlice == altText && (altText.hasPrefix("http://") || altText.hasPrefix("https://")))
                    guard wholeImage else { break }
                    let anchor = offset(alt.lowerBound)
                    guard lo <= anchor, hi > anchor else { break }
                    if let bang = source.index(alt.lowerBound, offsetBy: -2, limitedBy: source.startIndex),
                       let close = source.index(url.upperBound, offsetBy: 1, limitedBy: source.endIndex) {
                        lo = min(lo, offset(bang))
                        hi = max(hi, offset(close))
                    }
                }
            }
        }
        func walkBlocks(_ blocks: [MarkdownBlock]) {
            for block in blocks {
                if case .image(let alt, _) = block.kind {
                    let altText = String(source[alt])
                    let wholeImage = displaySlice == "\u{FFFC}"
                        || (displaySlice == altText && (altText.hasPrefix("http://") || altText.hasPrefix("https://")))
                    if wholeImage {
                        let anchor = offset(alt.lowerBound)
                        if lo <= anchor && hi > anchor {
                            lo = min(lo, offset(block.source.lowerBound))
                            hi = max(hi, offset(block.source.upperBound))
                        }
                    }
                }
                walkInlines(block.inlines)
                walkBlocks(block.children)
            }
        }
        walkBlocks(MarkdownDocument.parse(source).blocks)
        return (lo, hi)
    }

    private func utf16Slice(of string: String, range: Range<Int>) -> String {
        let utf16 = string.utf16
        let lower = min(max(range.lowerBound, 0), utf16.count)
        let upper = min(max(range.upperBound, lower), utf16.count)
        let start = utf16.index(utf16.startIndex, offsetBy: lower)
        let end = utf16.index(start, offsetBy: upper - lower)
        return String(decoding: utf16[start..<end], as: UTF16.self)
    }

    /// True when `reveal` names this inline's content, not a nested span.
    private static func inlineRevealed(_ inline: MarkdownInline, reveal: Reveal) -> Bool {
        guard case .inline(let range) = reveal else { return false }
        return contentRange(of: inline) == range
    }

    private static func contentRange(of inline: MarkdownInline) -> Range<String.Index> {
        switch inline {
        case .text(let range):
            return range
        case .strong(let open, _, let close), .emphasis(let open, _, let close),
             .strikethrough(let open, _, let close), .highlight(let open, _, let close):
            return open.upperBound..<close.lowerBound
        case .code(_, let content, _), .kbd(_, let content, _):
            return content
        case .link(let labelOpen, _, let labelClose, _, _):
            return labelOpen.upperBound..<labelClose.lowerBound
        case .math(_, let latex, _):
            return latex
        case .image(let alt, _):
            return alt
        }
    }

    /// Newline after a rendered line. Prefers the source newline that ends this
    /// block's own line (not a later nested line). Returns the index to continue from.
    @discardableResult
    private static func appendLineBreak(
        _ block: MarkdownBlock,
        source: String,
        into text: inout String,
        map: inout [Int]
    ) -> String.Index {
        let contentEnd = coverageEnd(block)
        if let newline = newlineRange(at: contentEnd, in: source) {
            appendSource(newline, source: source, into: &text, map: &map)
            return newline.upperBound
        }
        if contentEnd > source.startIndex {
            let previous = source.index(before: contentEnd)
            if previous >= block.source.lowerBound, let newline = newlineRange(at: previous, in: source) {
                appendSource(newline, source: source, into: &text, map: &map)
                return contentEnd
            }
        }
        if let index = source[block.source].firstIndex(of: "\n"),
           let newline = newlineRange(at: index, in: source) {
            appendSource(newline, source: source, into: &text, map: &map)
            return newline.upperBound
        }
        let offset = utf16Offset(of: block.source.upperBound, in: source) ?? 0
        appendMapped("\n", sourceOffset: offset, into: &text, map: &map)
        return block.source.upperBound
    }

    private static func coverageEnd(_ block: MarkdownBlock) -> String.Index {
        block.inlines.reduce(block.marker.upperBound) { end, inline in
            max(end, coverageEnd(inline))
        }
    }

    private static func coverageEnd(_ inline: MarkdownInline) -> String.Index {
        switch inline {
        case .text(let range):
            return range.upperBound
        case .strong(_, _, let close), .emphasis(_, _, let close), .math(_, _, let close),
             .strikethrough(_, _, let close), .highlight(_, _, let close):
            return close.upperBound
        case .code(_, _, let close), .kbd(_, _, let close):
            return close.upperBound
        case .link(_, _, _, _, let close):
            return close.upperBound
        case .image(_, let url):
            return url.upperBound
        }
    }

    /// Start of the closing delimiter line. A closed fence or math block's source
    /// ends on that line; unclosed markers never become these block kinds.
    private static func closingLineStart(_ block: MarkdownBlock, source: String) -> String.Index {
        let origin = block.marker.upperBound
        var index = block.source.upperBound
        if index > origin, source[source.index(before: index)] == "\n" {
            index = source.index(before: index)
        }
        while index > origin {
            let previous = source.index(before: index)
            if source[previous] == "\n" {
                return index
            }
            index = previous
        }
        return origin
    }

    private static func sourceContainsNewline(_ block: MarkdownBlock, source: String) -> Bool {
        source[block.source].contains("\n")
    }

    private static func newlineRange(at index: String.Index, in source: String) -> Range<String.Index>? {
        guard index < source.endIndex, source[index] == "\n" else { return nil }
        return index..<source.index(after: index)
    }

    private static func appendSource(
        _ range: Range<String.Index>,
        source: String,
        into text: inout String,
        map: inout [Int]
    ) {
        guard !range.isEmpty, let base = utf16Offset(of: range.lowerBound, in: source) else { return }
        let slice = source[range]
        text.append(contentsOf: slice)
        for unit in 0..<slice.utf16.count {
            map.append(base + unit)
        }
    }

    private static func appendMapped(
        _ string: String,
        sourceOffset: Int,
        into text: inout String,
        map: inout [Int]
    ) {
        text.append(contentsOf: string)
        for unit in 0..<string.utf16.count {
            map.append(sourceOffset + unit)
        }
    }

    private static func utf16Offset(of index: String.Index, in source: String) -> Int? {
        guard let utf16Index = index.samePosition(in: source.utf16) else { return nil }
        return source.utf16.distance(from: source.utf16.startIndex, to: utf16Index)
    }
}
