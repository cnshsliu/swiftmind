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

    /// Map a display edit back onto markdown. A zero-length range inserts.
    /// A non-empty range replaces the source units covered by those display units.
    public func splicing(source: String, displayReplacement: String, displayUTF16: Range<Int>) -> String {
        let mapCount = sourceUTF16.count
        let sourceCount = source.utf16.count
        let lower = displayUTF16.lowerBound
        let upper = displayUTF16.upperBound
        let start: Int
        if lower <= 0 || mapCount == 0 {
            start = 0
        } else {
            let before = min(lower - 1, mapCount - 1)
            start = sourceUTF16[before] + 1
        }
        let end = upper >= 0 && upper < mapCount ? sourceUTF16[upper] : sourceCount
        let location = min(max(start, 0), sourceCount)
        let length = min(max(0, end - location), sourceCount - location)
        let ns = source as NSString
        return ns.replacingCharacters(
            in: NSRange(location: location, length: length),
            with: displayReplacement
        )
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
        // An image click reveals the whole line. Do not also append U+FFFC.
        if case .block(let range) = reveal, block.source == range {
            appendSource(block.source, source: source, into: &text, map: &map)
            return
        }
        // Marker reveal keeps the rendered body, so a heading is not the raw line twice.
        if case .block(let range) = reveal, block.marker == range {
            appendSource(block.marker, source: source, into: &text, map: &map)
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
