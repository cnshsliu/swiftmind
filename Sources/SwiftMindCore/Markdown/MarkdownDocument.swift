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
            if let heading = headingBlock(source, start: start, lineEnd: lineEnd, blockEnd: end) {
                blocks.append(heading)
                index = end
                continue
            }
            if let item = listItemBlock(source, start: start, lineEnd: lineEnd, blockEnd: end) {
                blocks.append(item)
                index = end
                continue
            }
            let content = start..<lineEnd
            blocks.append(MarkdownBlock(
                kind: .paragraph,
                source: start..<end,
                marker: start..<start,
                inlines: [.text(content)]
            ))
            index = end
        }
        return MarkdownDocument(blocks: nestLists(blocks))
    }

    static func listItemBlock(
        _ source: String,
        start: String.Index,
        lineEnd: String.Index,
        blockEnd: String.Index
    ) -> MarkdownBlock? {
        var i = start
        var indent = 0
        while i < lineEnd, source[i] == " " {
            indent += 1
            i = source.index(after: i)
        }
        guard i < lineEnd else { return nil }
        let markerStart = i
        var ordered = false
        if source[i] == "-" || source[i] == "*" {
            i = source.index(after: i)
            guard i < lineEnd, source[i] == " " else { return nil }
            i = source.index(after: i)
        } else if source[i].isNumber {
            ordered = true
            while i < lineEnd, source[i].isNumber { i = source.index(after: i) }
            guard i < lineEnd, source[i] == "." else { return nil }
            i = source.index(after: i)
            guard i < lineEnd, source[i] == " " else { return nil }
            i = source.index(after: i)
        } else {
            return nil
        }
        var checked: Bool? = nil
        if !ordered, i < lineEnd, source[i] == "[" {
            let box = source[i..<lineEnd]
            if box.hasPrefix("[ ] ") || box.hasPrefix("[x] ") || box.hasPrefix("[X] ") {
                checked = source[source.index(i, offsetBy: 1)] != " "
                i = source.index(i, offsetBy: 4)
            }
        }
        return MarkdownBlock(
            kind: .listItem(ordered: ordered, checked: checked, indent: indent),
            source: start..<blockEnd,
            marker: markerStart..<i,
            inlines: [.text(i..<lineEnd)]
        )
    }

    static func nestLists(_ blocks: [MarkdownBlock]) -> [MarkdownBlock] {
        func indent(of block: MarkdownBlock) -> Int? {
            guard case .listItem(_, _, let indent) = block.kind else { return nil }
            return indent
        }
        var roots: [MarkdownBlock] = []
        var stack: [(indent: Int, block: MarkdownBlock)] = []
        func close(to indentLimit: Int) {
            while let top = stack.last, top.indent >= indentLimit {
                stack.removeLast()
                if var parent = stack.last {
                    parent.block.children.append(top.block)
                    parent.block.source = parent.block.source.lowerBound..<top.block.source.upperBound
                    stack[stack.count - 1] = parent
                } else {
                    roots.append(top.block)
                }
            }
        }
        for block in blocks {
            guard let itemIndent = indent(of: block) else {
                close(to: -1)
                roots.append(block)
                continue
            }
            close(to: itemIndent)
            stack.append((itemIndent, block))
        }
        close(to: -1)
        return roots
    }

    static func headingBlock(
        _ source: String,
        start: String.Index,
        lineEnd: String.Index,
        blockEnd: String.Index
    ) -> MarkdownBlock? {
        var i = start
        var level = 0
        while i < lineEnd, source[i] == "#", level < 6 {
            level += 1
            i = source.index(after: i)
        }
        guard level >= 1, i < lineEnd, source[i] == " " else { return nil }
        let markerEnd = source.index(after: i)
        return MarkdownBlock(
            kind: .heading(level: level),
            source: start..<blockEnd,
            marker: start..<markerEnd,
            inlines: [.text(markerEnd..<lineEnd)]
        )
    }
}
