import SwiftUI
import SwiftMindCore

/// Shared markdown renderer for notes: block-structured markdown (headers,
/// lists, code fences, quotes) via SwiftUI `AttributedString(markdown:)`
/// for inline spans, `LaTeXMathView` for `$…$`/`$$…$$` segments,
/// `MarkdownImageView` for standalone image lines. Block assembly is a pure
/// function of the input — no cached @State: mutating state from `body`
/// (even async) can land inside an AppKit layout pass and crash on an
/// exclusivity violation.
struct MarkdownTextView: View {
    let markdown: String
    var fontSize: CGFloat = 12
    var maxImageHeight: CGFloat = 200

    @Environment(\.colorScheme) private var colorScheme

    enum Block {
        case header(level: Int, pieces: [Piece])
        case paragraph([Piece])
        case listItem(indent: Int, marker: String, pieces: [Piece])
        case quote([Piece])
        case code(String)
        case blockMath(String)
        case table([[String]])
        case divider
        case image(alt: String, urlString: String)
    }

    enum Piece {
        /// One wrapping run. Key caps sit inside it so they share the line.
        case flow([Run])
        case inlineMath(String)
    }

    enum Run {
        case markdown(String)
        case key(String)
        /// `==x==` — AttributedString markdown has no highlight; draw the
        /// background ourselves.
        case highlight(String)
    }

    var body: some View {
        let resolved = MarkdownTextView.blocks(from: markdown)
        VStack(alignment: .leading, spacing: fontSize * 0.45) {
            ForEach(Array(resolved.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(markdown)
    }

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .header(let level, let pieces):
            piecesView(pieces, font: headerFont(level), metricsSize: headerMetricsSize(level))
        case .paragraph(let pieces):
            piecesView(pieces, font: .system(size: fontSize), metricsSize: fontSize)
        case .listItem(let indent, let marker, let pieces):
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(marker).font(.system(size: fontSize)).foregroundStyle(.secondary)
                piecesView(pieces, font: .system(size: fontSize), metricsSize: fontSize)
            }
            .padding(.leading, CGFloat(indent) * fontSize * 1.2)
        case .quote(let pieces):
            // GitHub blockquote: regular text, inset, one bar on the left.
            piecesView(pieces, font: .system(size: fontSize), metricsSize: fontSize)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.45))
                        .frame(width: 3)
                }
        case .code(let source):
            Text(source)
                .font(.system(size: fontSize * 0.92, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        case .blockMath(let latex):
            LaTeXMathView(latex: latex, fontSize: fontSize, block: true)
                .frame(maxWidth: .infinity, alignment: .center)
        case .table(let rows):
            tableView(rows)
        case .divider:
            Rectangle()
                .fill(Color.secondary.opacity(0.35))
                .frame(height: 1)
                .padding(.vertical, fontSize * 0.35)
        case .image(let alt, let urlString):
            MarkdownImageView(alt: alt, urlString: urlString, maxHeight: maxImageHeight)
        }
    }

    /// Simple grid: header row emphasized, hairline rules between rows.
    /// Column widths share available width equally (v1).
    private func tableView(_ rows: [[String]]) -> some View {
        let columnCount = rows.map(\.count).max() ?? 1
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                HStack(alignment: .top, spacing: 0) {
                    ForEach(0..<columnCount, id: \.self) { column in
                        Text(column < row.count ? row[column] : "")
                            .font(.system(size: fontSize * 0.95,
                                          weight: rowIndex == 0 ? .semibold : .regular))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                    }
                }
                Rectangle()
                    .fill(Color.secondary.opacity(rowIndex == 0 ? 0.45 : 0.2))
                    .frame(height: 1)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.25)))
    }

    private func headerMetricsSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return fontSize * 1.45
        case 2: return fontSize * 1.28
        case 3: return fontSize * 1.14
        default: return fontSize
        }
    }

    private func headerFont(_ level: Int) -> Font {
        let scale: CGFloat
        let weight: Font.Weight
        switch level {
        case 1: scale = 1.45; weight = .bold
        case 2: scale = 1.28; weight = .semibold
        case 3: scale = 1.14; weight = .semibold
        default: scale = 1.0; weight = .semibold
        }
        return .system(size: fontSize * scale, weight: weight)
    }


    /// A paragraph-level run of text and inline-math pieces, flowed on a
    /// shared baseline (math baselines from LaTeXMetrics, which mirrors the
    /// renderer geometry including the math-axis offset). `metricsSize` is
    /// the font size used for text baseline computation (headers pass their
    /// scaled size).
    @ViewBuilder
    private func piecesView(_ pieces: [Piece], font: Font, metricsSize: CGFloat) -> some View {
        ParagraphFlowLayout(
            items: pieces.map { piece in
                switch piece {
                case .flow: return .text(fontSize: metricsSize)
                case .inlineMath(let latex): return .math(latex: latex, fontSize: fontSize)
                }
            },
            spacing: 0
        ) {
            ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in
                switch piece {
                case .flow(let runs):
                    flowingText(runs, font: font, fontSize: metricsSize)
                case .inlineMath(let latex):
                    LaTeXMathView(latex: latex, fontSize: fontSize)
                }
            }
        }
    }

    /// Markdown runs and key-cap images in one `Text`, so a cap wraps with
    /// the words instead of starting its own line.
    private func flowingText(_ runs: [Run], font: Font, fontSize: CGFloat) -> Text {
        var text: Text?
        func append(_ next: Text) {
            text = text.map { $0 + next } ?? next
        }
        for run in runs {
            switch run {
            case .markdown(let source):
                // Inline-only keeps spaces and quote line breaks. The full
                // parser trims both.
                if let attr = try? AttributedString(
                    markdown: source,
                    options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                ) {
                    append(Text(attr).font(font))
                } else {
                    append(Text(source).font(font))
                }
            case .highlight(let text):
                var attr = AttributedString(text)
                attr.backgroundColor = Color.yellow.opacity(colorScheme == .dark ? 0.30 : 0.45)
                append(Text(attr).font(font))
            case .key(let name):
                let image = KeyCapChrome.image(label: name, fontSize: fontSize)
                // The image's bottom sits on the baseline. Shift it down by
                // the font's descender so the cap fills the text line box.
                let drop = KeyCapChrome.lineBox(fontSize: fontSize).baseline
                append(Text(Image(nsImage: image)).baselineOffset(drop))
            }
        }
        return text ?? Text("")
    }

    // MARK: - Block assembly (pure)

    static func blocks(from markdown: String) -> [Block] {
        var result: [Block] = []
        func append(_ blocks: [MarkdownBlock]) {
            var nextOrdered = 0
            for block in blocks {
                switch block.kind {
                case .heading(let level):
                    nextOrdered = 0
                    result.append(.header(level: level, pieces: pieces(from: block.inlines, source: markdown)))
                case .paragraph:
                    nextOrdered = 0
                    let body = pieces(from: block.inlines, source: markdown)
                    if !body.isEmpty { result.append(.paragraph(body)) }
                case .listItem(_, _, let indent):
                    let marker = MarkdownDocument.listMarker(
                        for: block, source: markdown, nextOrdered: &nextOrdered
                    ) ?? "•"
                    result.append(.listItem(
                        indent: indent,
                        marker: marker,
                        pieces: pieces(from: block.inlines, source: markdown)
                    ))
                case .quote:
                    nextOrdered = 0
                    let body = pieces(from: block.inlines, source: markdown)
                    if case .quote(let existing)? = result.last {
                        result[result.count - 1] = .quote(
                            Self.coalesced(existing + [.flow([.markdown("\n")])] + body)
                        )
                    } else {
                        result.append(.quote(body))
                    }
                case .codeFence:
                    nextOrdered = 0
                    let body = block.inlines.compactMap { inline -> String? in
                        guard case .text(let range) = inline else { return nil }
                        return String(markdown[range])
                    }.joined()
                    result.append(.code(body))
                case .divider:
                    nextOrdered = 0
                    result.append(.divider)
                case .table:
                    nextOrdered = 0
                    result.append(.table(MarkdownDocument.tableCells(in: block, source: markdown)))
                case .mathBlock:
                    nextOrdered = 0
                    let latex = block.inlines.compactMap { inline -> String? in
                        guard case .text(let range) = inline else { return nil }
                        return String(markdown[range])
                    }.joined()
                    result.append(.blockMath(latex))
                case .image(let alt, let url):
                    nextOrdered = 0
                    result.append(.image(alt: String(markdown[alt]), urlString: String(markdown[url])))
                }
                if !block.children.isEmpty { append(block.children) }
            }
        }
        append(MarkdownDocument.parse(markdown).blocks)
        return result
    }

    /// Bold, code, and links stay markdown so one `Text` wraps the whole run.
    /// `<kbd>` is a key-cap image in that same run. Math stays its own piece.
    private static func pieces(from inlines: [MarkdownInline], source: String) -> [Piece] {
        var result: [Piece] = []
        for inline in inlines {
            switch inline {
            case .text(let range):
                appendMarkdown(String(source[range]), to: &result)
            case .strong(_, let content, _):
                appendMarkdown("**" + plain(content, source: source) + "**", to: &result)
            case .emphasis(_, let content, _):
                appendMarkdown("*" + plain(content, source: source) + "*", to: &result)
            case .strikethrough(_, let content, _):
                appendMarkdown("~~" + plain(content, source: source) + "~~", to: &result)
            case .highlight(_, let content, _):
                appendHighlight(plain(content, source: source), to: &result)
            case .code(_, let content, _):
                appendMarkdown("`" + String(source[content]) + "`", to: &result)
            case .link(_, let label, _, let url, _):
                appendMarkdown(
                    "[" + plain(label, source: source) + "](" + String(source[url]) + ")",
                    to: &result
                )
            case .kbd(_, let label, _):
                appendKey(String(source[label]), to: &result)
            case .math(_, let latex, _):
                let formula = String(source[latex])
                if !formula.isEmpty { result.append(.inlineMath(formula)) }
            }
        }
        return result
    }

    private static func appendMarkdown(_ string: String, to pieces: inout [Piece]) {
        guard !string.isEmpty else { return }
        if case .flow(var runs) = pieces.last {
            if case .markdown(let existing) = runs.last {
                runs[runs.count - 1] = .markdown(existing + string)
            } else {
                runs.append(.markdown(string))
            }
            pieces[pieces.count - 1] = .flow(runs)
        } else {
            pieces.append(.flow([.markdown(string)]))
        }
    }

    private static func appendHighlight(_ text: String, to pieces: inout [Piece]) {
        guard !text.isEmpty else { return }
        if case .flow(var runs) = pieces.last {
            runs.append(.highlight(text))
            pieces[pieces.count - 1] = .flow(runs)
        } else {
            pieces.append(.flow([.highlight(text)]))
        }
    }

    private static func appendKey(_ name: String, to pieces: inout [Piece]) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if case .flow(var runs) = pieces.last {
            runs.append(.key(trimmed))
            pieces[pieces.count - 1] = .flow(runs)
        } else {
            pieces.append(.flow([.key(trimmed)]))
        }
    }

    private static func coalesced(_ pieces: [Piece]) -> [Piece] {
        var result: [Piece] = []
        for piece in pieces {
            switch piece {
            case .flow(let runs):
                for run in runs {
                    switch run {
                    case .markdown(let string): appendMarkdown(string, to: &result)
                    case .key(let name): appendKey(name, to: &result)
                    case .highlight(let text): appendHighlight(text, to: &result)
                    }
                }
            case .inlineMath:
                result.append(piece)
            }
        }
        return result
    }

    private static func plain(_ inlines: [MarkdownInline], source: String) -> String {
        inlines.map { inline -> String in
            switch inline {
            case .text(let range), .code(_, let range, _), .math(_, let range, _),
                 .kbd(_, let range, _):
                return String(source[range])
            case .strong(_, let content, _), .emphasis(_, let content, _),
                 .strikethrough(_, let content, _), .highlight(_, let content, _):
                return plain(content, source: source)
            case .link(_, let label, _, _, _):
                return plain(label, source: source)
            }
        }.joined()
    }
}
