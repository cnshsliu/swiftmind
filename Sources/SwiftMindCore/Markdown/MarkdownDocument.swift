import Foundation

public struct MarkdownDocument: Equatable, Sendable {
    public var blocks: [MarkdownBlock]

    public init(blocks: [MarkdownBlock]) {
        self.blocks = blocks
    }

    public static func parse(_ source: String) -> MarkdownDocument {
        MarkdownParser.parse(source)
    }

    /// Display label for one sibling in a list run. `nextOrdered` is 0 at the
    /// start of a run; the first ordered item sets it, and each following
    /// ordered item increments it. A bullet or a non-list resets the run.
    public static func listMarker(
        for block: MarkdownBlock,
        source: String,
        nextOrdered: inout Int
    ) -> String? {
        guard case .listItem(let ordered, let checked, _) = block.kind else {
            nextOrdered = 0
            return nil
        }
        if let checked {
            nextOrdered = 0
            return checked ? "☑" : "☐"
        }
        if ordered {
            if nextOrdered == 0 {
                let digits = source[block.marker].prefix(while: \.isNumber)
                nextOrdered = Int(digits) ?? 1
            } else {
                nextOrdered += 1
            }
            return "\(nextOrdered)."
        }
        nextOrdered = 0
        return "•"
    }

    /// Rewrite each contiguous numbered run so the markers count upward from
    /// the first item. `1.` / `2.` / `2.` / `3.` becomes `1.` / `2.` / `3.` / `4.`.
    /// `caret` is a UTF-16 offset and is shifted when a marker before it changes width.
    public static func renumberOrderedLists(_ source: String, caret: Int) -> (String, Int) {
        let ns = source as NSString
        guard ns.length > 0 else { return (source, 0) }
        var runs: [(indent: Int, next: Int)] = []
        var output = ""
        var written = 0
        var newCaret = min(max(caret, 0), ns.length)
        var placedCaret = false
        var index = 0
        while index < ns.length {
            let full = ns.lineRange(for: NSRange(location: index, length: 0))
            let raw = ns.substring(with: full)
            let newlineLength = raw.hasSuffix("\r\n") ? 2 : (raw.hasSuffix("\n") || raw.hasSuffix("\r") ? 1 : 0)
            let content = String(raw.dropLast(newlineLength))
            let ending = String(raw.suffix(newlineLength))
            let rebuilt = renumberedLine(content, runs: &runs)
            let lineStart = full.location
            let lineEnd = full.location + full.length
            if !placedCaret, caret < lineEnd || (newlineLength == 0 && caret <= lineEnd) {
                let relative = min(max(caret - lineStart, 0), (content as NSString).length)
                newCaret = written + min(relative, (rebuilt as NSString).length)
                if let old = orderedPrefix(content), let updated = orderedPrefix(rebuilt), relative >= old.markerEnd {
                    let growth = updated.markerEnd - old.markerEnd
                    newCaret = written + relative + growth
                }
                placedCaret = true
            }
            output += rebuilt + ending
            written += (rebuilt as NSString).length + newlineLength
            index = lineEnd
        }
        if !placedCaret {
            newCaret = min(max(caret, 0) + (written - ns.length), written)
        }
        return (output, min(max(newCaret, 0), written))
    }

    private static func renumberedLine(_ content: String, runs: inout [(indent: Int, next: Int)]) -> String {
        if content.trimmingCharacters(in: .whitespaces).isEmpty {
            runs.removeAll()
            return content
        }
        if let bullet = bulletIndent(content) {
            runs.removeAll { $0.indent >= bullet }
            return content
        }
        guard let item = orderedPrefix(content) else {
            runs.removeAll()
            return content
        }
        runs.removeAll { $0.indent > item.indent }
        let number: Int
        if let index = runs.lastIndex(where: { $0.indent == item.indent }) {
            number = runs[index].next
            runs[index].next += 1
        } else {
            number = item.number
            runs.append((indent: item.indent, next: number + 1))
        }
        let marker = "\(number). "
        if marker == item.marker { return content }
        return String(repeating: " ", count: item.indent) + marker + item.rest
    }

    private static func bulletIndent(_ content: String) -> Int? {
        var indent = 0
        let chars = Array(content)
        while indent < chars.count, chars[indent] == " " { indent += 1 }
        guard indent < chars.count else { return nil }
        let rest = String(chars[indent...])
        if rest.hasPrefix("- ") || rest.hasPrefix("* ") || rest.hasPrefix("+ ") { return indent }
        return nil
    }

    private static func orderedPrefix(_ content: String) -> (indent: Int, number: Int, marker: String, markerEnd: Int, rest: String)? {
        var indent = 0
        let chars = Array(content)
        while indent < chars.count, chars[indent] == " " { indent += 1 }
        var index = indent
        var number = 0
        var digits = 0
        while index < chars.count, chars[index].isNumber {
            number = number * 10 + Int(String(chars[index]))!
            digits += 1
            index += 1
        }
        guard digits > 0, index + 1 < chars.count, chars[index] == ".", chars[index + 1] == " " else { return nil }
        let markerEnd = index + 2
        return (
            indent,
            number,
            String(chars[indent..<markerEnd]),
            markerEnd,
            String(chars[markerEnd...])
        )
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
    /// `---` / `***` on its own line; renders as a hairline rule.
    case divider
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
    /// `~~x~~`. Rendered struck through; markers hidden like strong/emphasis.
    case strikethrough(open: Range<String.Index>, content: [MarkdownInline], close: Range<String.Index>)
    /// `==x==`. Rendered with a highlight background; markers hidden.
    case highlight(open: Range<String.Index>, content: [MarkdownInline], close: Range<String.Index>)
    /// `<kbd>⌘E</kbd>`. The label is the key name drawn on the cap.
    case kbd(open: Range<String.Index>, label: Range<String.Index>, close: Range<String.Index>)
}

enum MarkdownParser {
    /// `---` / `***` / `___` (3+, own line, spaces allowed around).
    static func isDividerLine(
        _ source: String, start: String.Index, lineEnd: String.Index
    ) -> Bool {
        var i = start
        while i < lineEnd, source[i] == " " { i = source.index(after: i) }
        guard i < lineEnd else { return false }
        let ch = source[i]
        guard ch == "-" || ch == "*" || ch == "_" else { return false }
        var count = 0
        while i < lineEnd {
            guard source[i] == ch else { break }
            count += 1
            i = source.index(after: i)
        }
        while i < lineEnd, source[i] == " " { i = source.index(after: i) }
        return count >= 3 && i == lineEnd
    }

    static func parse(_ source: String) -> MarkdownDocument {
        var blocks: [MarkdownBlock] = []
        var index = source.startIndex
        while index < source.endIndex {
            if source[index] == "\n" {
                index = source.index(after: index)
                continue
            }
            if let (fence, next) = fenceBlock(source, from: index) {
                blocks.append(fence)
                index = next
                continue
            }
            if let (math, next) = mathBlock(source, from: index) {
                blocks.append(math)
                index = next
                continue
            }
            let start = index
            var end = index
            while end < source.endIndex, source[end] != "\n" {
                end = source.index(after: end)
            }
            let lineEnd = end
            if end < source.endIndex { end = source.index(after: end) }
            if let math = singleLineMathBlock(source, start: start, lineEnd: lineEnd, blockEnd: end) {
                blocks.append(math)
                index = end
                continue
            }
            if let image = imageBlock(source, start: start, lineEnd: lineEnd, blockEnd: end) {
                blocks.append(image)
                index = end
                continue
            }
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
            if let quote = quoteBlock(source, start: start, lineEnd: lineEnd, blockEnd: end) {
                blocks.append(quote)
                index = end
                continue
            }
            if isDividerLine(source, start: start, lineEnd: lineEnd) {
                blocks.append(MarkdownBlock(
                    kind: .divider,
                    source: start..<end,
                    marker: start..<start,
                    inlines: []
                ))
                index = end
                continue
            }
            let content = start..<lineEnd
            blocks.append(MarkdownBlock(
                kind: .paragraph,
                source: start..<end,
                marker: start..<start,
                inlines: parseInlines(source, in: content)
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
            inlines: parseInlines(source, in: i..<lineEnd)
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
            inlines: parseInlines(source, in: markerEnd..<lineEnd)
        )
    }

    static func fenceBlock(_ source: String, from index: String.Index) -> (MarkdownBlock, String.Index)? {
        let lineEnd = endOfLine(source, index)
        let line = source[index..<lineEnd]
        let trimmed = line.drop(while: { $0 == " " })
        guard trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") else { return nil }
        let marker = trimmed.hasPrefix("```") ? "```" : "~~~"
        var cursor = lineEnd < source.endIndex ? source.index(after: lineEnd) : lineEnd
        let bodyStart = cursor
        while cursor < source.endIndex {
            let rowEnd = endOfLine(source, cursor)
            let row = source[cursor..<rowEnd].drop(while: { $0 == " " })
            if row.hasPrefix(marker), row.dropFirst(marker.count).allSatisfy({ $0 == " " || $0 == "\t" }) {
                let blockEnd = rowEnd < source.endIndex ? source.index(after: rowEnd) : rowEnd
                var bodyEnd = cursor
                if bodyEnd > bodyStart, source[source.index(before: bodyEnd)] == "\n" {
                    bodyEnd = source.index(before: bodyEnd)
                }
                return (MarkdownBlock(
                    kind: .codeFence,
                    source: index..<blockEnd,
                    marker: index..<bodyStart,
                    inlines: [.text(bodyStart..<bodyEnd)]
                ), blockEnd)
            }
            cursor = rowEnd < source.endIndex ? source.index(after: rowEnd) : rowEnd
        }
        return nil
    }

    static func mathBlock(_ source: String, from index: String.Index) -> (MarkdownBlock, String.Index)? {
        let lineEnd = endOfLine(source, index)
        guard source[index..<lineEnd].trimmingCharacters(in: .whitespaces) == "$$" else { return nil }
        var cursor = lineEnd < source.endIndex ? source.index(after: lineEnd) : lineEnd
        let bodyStart = cursor
        while cursor < source.endIndex {
            let rowEnd = endOfLine(source, cursor)
            if source[cursor..<rowEnd].trimmingCharacters(in: .whitespaces) == "$$" {
                let blockEnd = rowEnd < source.endIndex ? source.index(after: rowEnd) : rowEnd
                var bodyEnd = cursor
                if bodyEnd > bodyStart, source[source.index(before: bodyEnd)] == "\n" {
                    bodyEnd = source.index(before: bodyEnd)
                }
                return (MarkdownBlock(
                    kind: .mathBlock,
                    source: index..<blockEnd,
                    marker: index..<bodyStart,
                    inlines: [.text(bodyStart..<bodyEnd)]
                ), blockEnd)
            }
            cursor = rowEnd < source.endIndex ? source.index(after: rowEnd) : rowEnd
        }
        return nil
    }

    /// `$$\frac{a}{b}$$` on one line. A line that is only `$$` stays the
    /// multi-line opener handled by `mathBlock`.
    static func singleLineMathBlock(
        _ source: String,
        start: String.Index,
        lineEnd: String.Index,
        blockEnd: String.Index
    ) -> MarkdownBlock? {
        let line = source[start..<lineEnd]
        guard line.hasPrefix("$$"), line.hasSuffix("$$"), line.count > 4 else { return nil }
        let openEnd = source.index(start, offsetBy: 2)
        let closeStart = source.index(lineEnd, offsetBy: -2)
        guard openEnd < closeStart else { return nil }
        return MarkdownBlock(
            kind: .mathBlock,
            source: start..<blockEnd,
            marker: start..<openEnd,
            inlines: [.text(openEnd..<closeStart)]
        )
    }

    static func imageBlock(
        _ source: String,
        start: String.Index,
        lineEnd: String.Index,
        blockEnd: String.Index
    ) -> MarkdownBlock? {
        let line = source[start..<lineEnd]
        guard line.hasPrefix("![") else { return nil }
        guard let altEnd = line.range(of: "]("), let close = line.lastIndex(of: ")"), close > altEnd.upperBound else {
            return nil
        }
        let alt = source.index(start, offsetBy: 2)..<source.index(start, offsetBy: line.distance(from: line.startIndex, to: altEnd.lowerBound))
        let urlStart = source.index(start, offsetBy: line.distance(from: line.startIndex, to: altEnd.upperBound))
        let urlEnd = source.index(start, offsetBy: line.distance(from: line.startIndex, to: close))
        return MarkdownBlock(
            kind: .image(alt: alt, url: urlStart..<urlEnd),
            source: start..<blockEnd,
            marker: start..<lineEnd,
            inlines: []
        )
    }

    static func quoteBlock(
        _ source: String,
        start: String.Index,
        lineEnd: String.Index,
        blockEnd: String.Index
    ) -> MarkdownBlock? {
        guard source[start..<lineEnd].hasPrefix("> ") else { return nil }
        let markerEnd = source.index(start, offsetBy: 2)
        return MarkdownBlock(
            kind: .quote,
            source: start..<blockEnd,
            marker: start..<markerEnd,
            inlines: parseInlines(source, in: markerEnd..<lineEnd)
        )
    }

    static func parseInlines(_ source: String, in range: Range<String.Index>) -> [MarkdownInline] {
        var output: [MarkdownInline] = []
        var index = range.lowerBound
        var textStart = index
        func flushText(to end: String.Index) {
            guard textStart < end else { return }
            output.append(.text(textStart..<end))
            textStart = end
        }
        while index < range.upperBound {
            if source[index] == "`",
               let found = closedSpan(source, from: index, limit: range.upperBound, marker: "`") {
                flushText(to: index)
                output.append(.code(open: found.open, content: found.content, close: found.close))
                index = found.close.upperBound
                textStart = index
                continue
            }
            if source[index] == "<", let kbd = keyboardTag(source, from: index, limit: range.upperBound) {
                flushText(to: index)
                output.append(kbd.inline)
                index = kbd.end
                textStart = index
                continue
            }
            if source[index] == "*",
               let found = wrapped(source, from: index, limit: range.upperBound, marker: "**") {
                flushText(to: index)
                output.append(.strong(
                    open: found.open,
                    content: parseInlines(source, in: found.content),
                    close: found.close
                ))
                index = found.close.upperBound
                textStart = index
                continue
            }
            if source[index] == "*",
               let found = wrapped(source, from: index, limit: range.upperBound, marker: "*") {
                flushText(to: index)
                output.append(.emphasis(
                    open: found.open,
                    content: parseInlines(source, in: found.content),
                    close: found.close
                ))
                index = found.close.upperBound
                textStart = index
                continue
            }
            if source[index] == "~",
               let found = wrapped(source, from: index, limit: range.upperBound, marker: "~~") {
                flushText(to: index)
                output.append(.strikethrough(
                    open: found.open,
                    content: parseInlines(source, in: found.content),
                    close: found.close
                ))
                index = found.close.upperBound
                textStart = index
                continue
            }
            if source[index] == "=",
               let found = wrapped(source, from: index, limit: range.upperBound, marker: "==") {
                flushText(to: index)
                output.append(.highlight(
                    open: found.open,
                    content: parseInlines(source, in: found.content),
                    close: found.close
                ))
                index = found.close.upperBound
                textStart = index
                continue
            }
            if source[index] == "[", let link = parseLink(source, from: index, limit: range.upperBound) {
                flushText(to: index)
                output.append(link.inline)
                index = link.end
                textStart = index
                continue
            }
            if source[index] == "$",
               isMathOpen(source, at: index, limit: range.upperBound, rangeStart: range.lowerBound),
               let found = wrapped(source, from: index, limit: range.upperBound, marker: "$") {
                flushText(to: index)
                output.append(.math(open: found.open, latex: found.content, close: found.close))
                index = found.close.upperBound
                textStart = index
                continue
            }
            index = source.index(after: index)
        }
        flushText(to: range.upperBound)
        return output
    }

    /// `marker` must sit at `from`. The next copy closes a non-empty, single-line span.
    static func wrapped(
        _ source: String,
        from index: String.Index,
        limit: String.Index,
        marker: String
    ) -> (open: Range<String.Index>, content: Range<String.Index>, close: Range<String.Index>)? {
        guard let openEnd = markerEnd(source, from: index, limit: limit, marker: marker) else { return nil }
        var cursor = openEnd
        while cursor < limit {
            if source[cursor] == "\n" { return nil }
            if let closeEnd = markerEnd(source, from: cursor, limit: limit, marker: marker) {
                guard cursor > openEnd else { return nil }
                return (index..<openEnd, openEnd..<cursor, cursor..<closeEnd)
            }
            cursor = source.index(after: cursor)
        }
        return nil
    }

    /// `<kbd>name</kbd>` on one line. The label is plain text, so a `<` inside
    /// it stays literal instead of swallowing the rest of the paragraph.
    static func keyboardTag(
        _ source: String,
        from index: String.Index,
        limit: String.Index
    ) -> (inline: MarkdownInline, end: String.Index)? {
        let openTag = "<kbd>"
        let closeTag = "</kbd>"
        guard source[index..<limit].hasPrefix(openTag) else { return nil }
        let contentStart = source.index(index, offsetBy: openTag.count)
        guard contentStart < limit,
              let close = source[contentStart..<limit].range(of: closeTag) else { return nil }
        let label = contentStart..<close.lowerBound
        guard !label.isEmpty,
              !source[label].contains("\n"),
              !source[label].contains("<"),
              !source[label].trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return (
            inline: .kbd(open: index..<contentStart, label: label, close: close),
            end: close.upperBound
        )
    }

    static func closedSpan(
        _ source: String,
        from index: String.Index,
        limit: String.Index,
        marker: String
    ) -> (open: Range<String.Index>, content: Range<String.Index>, close: Range<String.Index>)? {
        wrapped(source, from: index, limit: limit, marker: marker)
    }

    /// Opening `$` at the start of `rangeStart`, after whitespace, or after `([{>-~`.
    /// The closer from `wrapped` must follow a non-space and precede end, whitespace, or `)],.;:!?`.
    static func isMathOpen(
        _ source: String,
        at index: String.Index,
        limit: String.Index,
        rangeStart: String.Index
    ) -> Bool {
        guard index < limit else { return false }
        if index > rangeStart {
            let previous = source[source.index(before: index)]
            guard previous.isWhitespace || "([{>-~".contains(previous) else { return false }
        }
        let nextIndex = source.index(after: index)
        guard nextIndex < limit else { return false }
        let next = source[nextIndex]
        guard !next.isWhitespace, next != "$" else { return false }
        guard let found = wrapped(source, from: index, limit: limit, marker: "$") else { return false }
        guard !source[source.index(before: found.close.lowerBound)].isWhitespace else { return false }
        let after = found.close.upperBound
        if after < limit {
            let following = source[after]
            guard following.isWhitespace || ")],.;:!?".contains(following) else { return false }
        }
        return true
    }

    static func parseLink(
        _ source: String,
        from index: String.Index,
        limit: String.Index
    ) -> (inline: MarkdownInline, end: String.Index)? {
        guard index < limit, source[index] == "[" else { return nil }
        let labelStart = source.index(after: index)
        var cursor = labelStart
        while cursor < limit {
            if source[cursor] == "\n" { return nil }
            if source[cursor] == "]" {
                let afterBracket = source.index(after: cursor)
                if afterBracket < limit, source[afterBracket] == "(" {
                    let urlStart = source.index(after: afterBracket)
                    var urlEnd = urlStart
                    while urlEnd < limit, source[urlEnd] != "\n", source[urlEnd] != ")" {
                        urlEnd = source.index(after: urlEnd)
                    }
                    guard urlEnd < limit, source[urlEnd] == ")" else { return nil }
                    let closeEnd = source.index(after: urlEnd)
                    return (
                        inline: .link(
                            labelOpen: index..<labelStart,
                            label: parseInlines(source, in: labelStart..<cursor),
                            labelClose: cursor..<urlStart,
                            url: urlStart..<urlEnd,
                            close: urlEnd..<closeEnd
                        ),
                        end: closeEnd
                    )
                }
            }
            cursor = source.index(after: cursor)
        }
        return nil
    }

    static func markerEnd(
        _ source: String,
        from index: String.Index,
        limit: String.Index,
        marker: String
    ) -> String.Index? {
        var cursor = index
        for character in marker {
            guard cursor < limit, source[cursor] == character else { return nil }
            cursor = source.index(after: cursor)
        }
        return cursor
    }

    static func endOfLine(_ source: String, _ index: String.Index) -> String.Index {
        var end = index
        while end < source.endIndex, source[end] != "\n" { end = source.index(after: end) }
        return end
    }
}
