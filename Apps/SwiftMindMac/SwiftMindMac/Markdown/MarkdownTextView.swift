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
        var paragraph: [Piece] = []
        var codeLines: [String]?
        var codeFence: String?

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            result.append(.paragraph(paragraph))
            paragraph = []
        }
        func flushCode() {
            if let lines = codeLines {
                result.append(.code(lines.joined(separator: "\n")))
            }
            codeLines = nil
            codeFence = nil
        }

        /// A header/list/quote line becomes its own block; plain lines join
        /// the running paragraph.
        func consumeLine(_ raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            if let fence = fenceMarker(trimmed) {
                if codeLines != nil, fence == codeFence {
                    flushCode()
                } else if codeLines == nil {
                    flushParagraph()
                    codeLines = []
                    codeFence = fence
                }
                return
            }
            if codeLines != nil {
                codeLines?.append(raw)
                return
            }

            guard !trimmed.isEmpty else {
                flushParagraph()
                return
            }

            if let (level, title) = headerLevel(trimmed) {
                flushParagraph()
                result.append(.header(level: level, pieces: [.text(title)]))
                return
            }
            if let (indent, marker, content) = listLine(raw) {
                flushParagraph()
                result.append(.listItem(indent: indent, marker: marker, pieces: [.text(content)]))
                return
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                let quoted = trimmed.dropFirst().drop(while: { $0 == " " })
                result.append(.quote([.text(String(quoted))]))
                return
            }

            if !paragraph.isEmpty {
                paragraph.append(.text(" " + trimmed))
            } else {
                paragraph.append(.text(trimmed))
            }
        }

        for segment in MarkdownSegmenter.segments(in: markdown) {
            switch segment {
            case .text(let s):
                for line in s.components(separatedBy: "\n") {
                    consumeLine(line)
                }
            case .math(inline: true, let latex):
                paragraph.append(.inlineMath(latex))
            case .math(inline: false, let latex):
                flushParagraph()
                result.append(.blockMath(latex))
            case .image(let alt, let urlString):
                flushParagraph()
                result.append(.image(alt: alt, urlString: urlString))
            }
        }
        flushParagraph()
        flushCode()
        return result
    }

    private static func fenceMarker(_ line: String) -> String? {
        guard line.hasPrefix("```") || line.hasPrefix("~~~") else { return nil }
        return String(line.prefix(3))
    }

    private static func headerLevel(_ line: String) -> (Int, String)? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix(while: { $0 == "#" })
        let level = hashes.count
        guard (1...6).contains(level) else { return nil }
        let rest = line.dropFirst(level)
        guard rest.first == " " || rest.first == "\t" else { return nil }
        let title = rest.drop(while: { $0 == " " || $0 == "\t" })
        guard !title.isEmpty else { return nil }
        return (level, String(title))
    }

    /// `- item`, `* item`, `+ item`, `1. item` — indent (2 spaces or 1 tab
    /// per level) becomes nesting.
    private static func listLine(_ raw: String) -> (indent: Int, marker: String, content: String)? {
        var spaces = 0
        var tabs = 0
        for c in raw {
            if c == " " { spaces += 1 } else if c == "\t" { tabs += 1 } else { break }
        }
        let indent = tabs + spaces / 2
        let body = raw.dropFirst(spaces + tabs)
        guard !body.isEmpty else { return nil }

        if let first = body.first, first == "-" || first == "*" || first == "+" {
            let after = body.dropFirst()
            if after.first == " " {
                let content = after.drop(while: { $0 == " " })
                guard !content.isEmpty else { return nil }
                return (indent, String(first), String(content))
            }
            return nil
        }
        // Ordered: digits + '.' + space.
        let digits = body.prefix(while: \.isNumber)
        if !digits.isEmpty {
            let after = body.dropFirst(digits.count)
            if after.first == "." {
                let next = after.dropFirst()
                if next.first == " " {
                    let content = next.drop(while: { $0 == " " })
                    guard !content.isEmpty else { return nil }
                    return (indent, "\(digits).", String(content))
                }
            }
        }
        return nil
    }
}
