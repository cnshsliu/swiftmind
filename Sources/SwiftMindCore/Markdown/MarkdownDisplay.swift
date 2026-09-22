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

    /// `.inline` and `.block` project like `.none` until reveal is implemented.
    public static func project(_ source: String, reveal: Reveal) -> MarkdownDisplay {
        switch reveal {
        case .none, .inline, .block:
            break
        }
        var text = ""
        var map: [Int] = []
        let end = appendBlocks(
            MarkdownDocument.parse(source).blocks,
            source: source,
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

    private static func appendBlocks(
        _ blocks: [MarkdownBlock],
        source: String,
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
        anotherFollows: Bool,
        into text: inout String,
        map: inout [Int]
    ) {
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
            appendInlines(block.inlines, source: source, into: &text, map: &map)
            var childStart = coverageEnd(block)
            if sourceContainsNewline(block, source: source) || anotherFollows || !block.children.isEmpty {
                childStart = appendLineBreak(block, source: source, into: &text, map: &map)
            }
            _ = appendBlocks(block.children, source: source, from: childStart, into: &text, map: &map)
        }
    }

    private static func appendInlines(
        _ inlines: [MarkdownInline],
        source: String,
        into text: inout String,
        map: inout [Int]
    ) {
        for inline in inlines {
            switch inline {
            case .text(let range), .code(_, let range, _), .math(_, let range, _):
                appendSource(range, source: source, into: &text, map: &map)
            case .strong(_, let content, _), .emphasis(_, let content, _):
                appendInlines(content, source: source, into: &text, map: &map)
            case .link(_, let label, _, _, _):
                appendInlines(label, source: source, into: &text, map: &map)
            }
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
