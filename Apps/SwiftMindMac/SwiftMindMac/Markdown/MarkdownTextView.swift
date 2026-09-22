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
        case image(alt: String, urlString: String)
    }

    enum Piece {
        case text(String)
        case inlineMath(String)
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
            piecesView(pieces, font: .system(size: fontSize).italic(), metricsSize: fontSize)
                .padding(.leading, 8)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.5))
                        .frame(width: 2)
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
        case .image(let alt, let urlString):
            MarkdownImageView(alt: alt, urlString: urlString, maxHeight: maxImageHeight)
        }
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
                case .text: return .text(fontSize: metricsSize)
                case .inlineMath(let latex): return .math(latex: latex, fontSize: fontSize)
                }
            },
            spacing: 0
        ) {
            ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in
                switch piece {
                case .text(let s):
                    if let attr = try? AttributedString(markdown: s) {
                        Text(attr).font(font)
                    } else {
                        Text(s).font(font)
                    }
                case .inlineMath(let latex):
                    LaTeXMathView(latex: latex, fontSize: fontSize)
                }
            }
        }
    }

    // MARK: - Block assembly (pure)

    static func blocks(from markdown: String) -> [Block] {
        var result: [Block] = []
        func append(_ block: MarkdownBlock) {
            switch block.kind {
            case .heading(let level):
                result.append(.header(level: level, pieces: pieces(from: block.inlines, source: markdown)))
            case .paragraph:
                let body = pieces(from: block.inlines, source: markdown)
                if !body.isEmpty { result.append(.paragraph(body)) }
            case .listItem(let ordered, let checked, let indent):
                let marker: String
                if let checked {
                    marker = checked ? "☑" : "☐"
                } else if ordered {
                    marker = "1."
                } else {
                    marker = "•"
                }
                result.append(.listItem(
                    indent: indent,
                    marker: marker,
                    pieces: pieces(from: block.inlines, source: markdown)
                ))
            case .quote:
                result.append(.quote(pieces(from: block.inlines, source: markdown)))
            case .codeFence:
                let body = block.inlines.compactMap { inline -> String? in
                    guard case .text(let range) = inline else { return nil }
                    return String(markdown[range])
                }.joined()
                result.append(.code(body))
            case .mathBlock:
                let latex = block.inlines.compactMap { inline -> String? in
                    guard case .text(let range) = inline else { return nil }
                    return String(markdown[range])
                }.joined()
                result.append(.blockMath(latex))
            case .image(let alt, let url):
                result.append(.image(alt: String(markdown[alt]), urlString: String(markdown[url])))
            }
            for child in block.children { append(child) }
        }
        for block in MarkdownDocument.parse(markdown).blocks { append(block) }
        return result
    }

    /// Strong, emphasis, code, and links stay as markdown text so
    /// `AttributedString(markdown:)` is the one inline renderer.
    private static func pieces(from inlines: [MarkdownInline], source: String) -> [Piece] {
        inlines.flatMap { inline -> [Piece] in
            switch inline {
            case .text(let range):
                let text = String(source[range])
                return text.isEmpty ? [] : [.text(text)]
            case .strong(_, let content, _):
                return [.text("**" + plain(content, source: source) + "**")]
            case .emphasis(_, let content, _):
                return [.text("*" + plain(content, source: source) + "*")]
            case .code(_, let content, _):
                return [.text("`" + String(source[content]) + "`")]
            case .link(_, let label, _, let url, _):
                return [.text("[" + plain(label, source: source) + "](" + String(source[url]) + ")")]
            case .math(_, let latex, _):
                return [.inlineMath(String(source[latex]))]
            }
        }
    }

    private static func plain(_ inlines: [MarkdownInline], source: String) -> String {
        inlines.map { inline -> String in
            switch inline {
            case .text(let range), .code(_, let range, _), .math(_, let range, _):
                return String(source[range])
            case .strong(_, let content, _), .emphasis(_, let content, _):
                return plain(content, source: source)
            case .link(_, let label, _, _, _):
                return plain(label, source: source)
            }
        }.joined()
    }
}
