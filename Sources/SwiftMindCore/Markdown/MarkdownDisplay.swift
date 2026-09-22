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

    public static func project(_ source: String, reveal: Reveal) -> MarkdownDisplay {
        var text = ""
        var map: [Int] = []
        let end = appendBlocks(
            MarkdownDocument.parse(source).blocks,
            source: source,
            reveal: reveal,
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
        let ns = source as NSString
        return ns.replacingCharacters(
            in: NSRange(location: location, length: limit - location),
            with: displayReplacement
        )
    }

    /// Source UTF-16 offset where the caret should sit after `splicing`.
    public func sourceCaretUTF16(
        displayReplacement: String,
        displayUTF16: Range<Int>,
        source: String
    ) -> Int {
        let mapCount = sourceUTF16.count
        let sourceCount = source.utf16.count
        let lower = displayUTF16.lowerBound
        let start: Int
        if lower == displayUTF16.upperBound {
            if lower >= 0 && lower < mapCount {
                start = sourceUTF16[lower]
            } else if lower <= 0 {
                start = 0
            } else {
                start = sourceCount
            }
        } else if mapCount == 0 || lower >= mapCount || displayUTF16.upperBound <= 0 {
            start = lower <= 0 ? 0 : sourceCount
        } else {
            let first = min(max(lower, 0), mapCount - 1)
            start = sourceUTF16[first]
        }
        return min(max(start, 0) + displayReplacement.utf16.count, sourceCount + displayReplacement.utf16.count)
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
            if block.marker == range {
                appendSource(block.marker, source: source, into: &text, map: &map)
            }
        }
        switch block.kind {
        case .image(let alt, _):
            // U+FFFC replaces the image syntax, not the line break after it.
            let offset = utf16Offset(of: alt.lowerBound, in: source) ?? 0
            appendMapped("\u{FFFC}", sourceOffset: offset, into: &text, map: &map)
            if sourceContainsNewline(block, source: source) || anotherFollows {
                appendLineBreak(block, source: source, into: &text, map: &map)
            }
        case .codeFence, .mathBlock:
            // The parser's text range drops the newline before the closer, which
            // deletes a trailing blank line. The interior is everything after the
            // opening line and before the closing delimiter line.
            let interior = block.marker.upperBound..<closingLineStart(block, source: source)
            appendSource(interior, source: source, into: &text, map: &map)
        case .heading, .paragraph, .listItem, .quote:
            appendInlines(block.inlines, source: source, reveal: reveal, into: &text, map: &map)
            var childStart = coverageEnd(block)
            if sourceContainsNewline(block, source: source) || anotherFollows || !block.children.isEmpty {
                childStart = appendLineBreak(block, source: source, into: &text, map: &map)
            }
            _ = appendBlocks(
                block.children,
                source: source,
                reveal: reveal,
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
        into text: inout String,
        map: inout [Int]
    ) {
        for inline in inlines {
            switch inline {
            case .text(let range):
                appendSource(range, source: source, into: &text, map: &map)
            case .strong(let open, let content, let close),
                 .emphasis(let open, let content, let close):
                if inlineRevealed(inline, reveal: reveal) {
                    appendSource(open, source: source, into: &text, map: &map)
                    appendInlines(content, source: source, reveal: reveal, into: &text, map: &map)
                    appendSource(close, source: source, into: &text, map: &map)
                } else {
                    appendInlines(content, source: source, reveal: reveal, into: &text, map: &map)
                }
            case .code(let open, let content, let close):
                if inlineRevealed(inline, reveal: reveal) {
                    appendSource(open, source: source, into: &text, map: &map)
                    appendSource(content, source: source, into: &text, map: &map)
                    appendSource(close, source: source, into: &text, map: &map)
                } else {
                    appendSource(content, source: source, into: &text, map: &map)
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
                    appendInlines(label, source: source, reveal: reveal, into: &text, map: &map)
                    appendSource(labelClose, source: source, into: &text, map: &map)
                    appendSource(url, source: source, into: &text, map: &map)
                    appendSource(close, source: source, into: &text, map: &map)
                } else {
                    appendInlines(label, source: source, reveal: reveal, into: &text, map: &map)
                }
            }
        }
    }

    private static func showsRawWhenMarkerRevealed(_ block: MarkdownBlock) -> Bool {
        switch block.kind {
        case .image, .codeFence, .mathBlock:
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
                     .emphasis(let open, let content, let close):
                    cover(open: open, content: open.upperBound..<close.lowerBound, close: close)
                    walkInlines(content)
                case .code(let open, let content, let close),
                     .math(let open, let content, let close):
                    cover(open: open, content: content, close: close)
                case .link(let labelOpen, let label, let labelClose, _, let close):
                    cover(
                        open: labelOpen,
                        content: labelOpen.upperBound..<labelClose.lowerBound,
                        close: close
                    )
                    walkInlines(label)
                }
            }
        }
        func walkBlocks(_ blocks: [MarkdownBlock]) {
            for block in blocks {
                if case .image(let alt, _) = block.kind, displaySlice == "\u{FFFC}" {
                    let anchor = offset(alt.lowerBound)
                    if lo <= anchor && hi > anchor {
                        lo = min(lo, offset(block.source.lowerBound))
                        hi = max(hi, offset(block.source.upperBound))
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
        case .strong(let open, _, let close), .emphasis(let open, _, let close):
            return open.upperBound..<close.lowerBound
        case .code(_, let content, _):
            return content
        case .link(let labelOpen, _, let labelClose, _, _):
            return labelOpen.upperBound..<labelClose.lowerBound
        case .math(_, let latex, _):
            return latex
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
        case .strong(_, _, let close), .emphasis(_, _, let close), .math(_, _, let close):
            return close.upperBound
        case .code(_, _, let close):
            return close.upperBound
        case .link(_, _, _, _, let close):
            return close.upperBound
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
