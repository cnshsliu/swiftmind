import Foundation

public struct MarkdownDocument: Equatable, Sendable {
    public var blocks: [MarkdownBlock]

    public init(blocks: [MarkdownBlock]) {
        self.blocks = blocks
    }

    public static func parse(_ source: String) -> MarkdownDocument {
        MarkdownParser.parse(source)
    }
}

public struct MarkdownBlock: Equatable, Sendable {
    public var kind: MarkdownBlockKind
    /// Whole block, including its marker and the trailing newline when present.
    public var source: Range<String.Index>
    /// Delimiter the editor reveals. Empty (`lowerBound == upperBound`) for a paragraph.
    public var marker: Range<String.Index>
    public var inlines: [MarkdownInline]
    public var children: [MarkdownBlock]

    public init(
        kind: MarkdownBlockKind,
        source: Range<String.Index>,
        marker: Range<String.Index>,
        inlines: [MarkdownInline] = [],
        children: [MarkdownBlock] = []
    ) {
        self.kind = kind
        self.source = source
        self.marker = marker
        self.inlines = inlines
        self.children = children
    }
}

public enum MarkdownBlockKind: Equatable, Sendable {
    case heading(level: Int)
    case paragraph
    case listItem(ordered: Bool, checked: Bool?, indent: Int)
    case quote
    case codeFence
    case mathBlock
    case image(alt: Range<String.Index>, url: Range<String.Index>)
}

public enum MarkdownInline: Equatable, Sendable {
    case text(Range<String.Index>)
    case strong(open: Range<String.Index>, content: [MarkdownInline], close: Range<String.Index>)
    case emphasis(open: Range<String.Index>, content: [MarkdownInline], close: Range<String.Index>)
    case code(open: Range<String.Index>, content: Range<String.Index>, close: Range<String.Index>)
    case link(
        labelOpen: Range<String.Index>,
        label: [MarkdownInline],
        labelClose: Range<String.Index>,
        url: Range<String.Index>,
        close: Range<String.Index>
    )
    case math(open: Range<String.Index>, latex: Range<String.Index>, close: Range<String.Index>)
}

enum MarkdownParser {
    static func parse(_ source: String) -> MarkdownDocument {
        var blocks: [MarkdownBlock] = []
        var index = source.startIndex
        while index < source.endIndex {
            if source[index] == "\n" {
                index = source.index(after: index)
                continue
            }
            let start = index
            var end = index
            while end < source.endIndex, source[end] != "\n" {
                end = source.index(after: end)
            }
            let lineEnd = end
            if end < source.endIndex { end = source.index(after: end) }
            let content = start..<lineEnd
            blocks.append(MarkdownBlock(
                kind: .paragraph,
                source: start..<end,
                marker: start..<start,
                inlines: [.text(content)]
            ))
            index = end
        }
        return MarkdownDocument(blocks: blocks)
    }
}
