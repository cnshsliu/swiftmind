import SwiftUI
import SwiftMindCore

/// Shared markdown renderer for notes: SwiftUI `AttributedString(markdown:)`
/// for text, `LaTeXMathView` for `$…$`/`$$…$$` segments, `MarkdownImageView`
/// for standalone image lines. Segments are memoized — the canvas re-renders
/// note cards on every keystroke while the floating editor is open.
struct MarkdownTextView: View {
    let markdown: String
    var fontSize: CGFloat = 12
    var maxImageHeight: CGFloat = 200

    @State private var lastInput: String = ""
    @State private var blocks: [Block] = []

    enum Block {
        case paragraph([Piece])
        case blockMath(String)
        case image(alt: String, urlString: String)
    }

    enum Piece {
        case text(String)
        case inlineMath(String)
    }

    var body: some View {
        let resolved = resolvedBlocks
        VStack(alignment: .leading, spacing: fontSize * 0.45) {
            ForEach(Array(resolved.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(markdown)
    }

    private var resolvedBlocks: [Block] {
        if lastInput == markdown { return blocks }
        let computed = MarkdownTextView.blocks(from: markdown)
        // Mutation during view update is safe for @State used only as a cache.
        DispatchQueue.main.async {
            lastInput = markdown
            blocks = computed
        }
        return computed
    }

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .paragraph(let pieces):
            FlowLayout(spacing: 0) {
                ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in
                    switch piece {
                    case .text(let s):
                        if let attr = try? AttributedString(markdown: s) {
                            Text(attr).font(.system(size: fontSize))
                        } else {
                            Text(s).font(.system(size: fontSize))
                        }
                    case .inlineMath(let latex):
                        LaTeXMathView(latex: latex, fontSize: fontSize)
                    }
                }
            }
        case .blockMath(let latex):
            LaTeXMathView(latex: latex, fontSize: fontSize, block: true)
                .frame(maxWidth: .infinity, alignment: .center)
        case .image(let alt, let urlString):
            MarkdownImageView(alt: alt, urlString: urlString, maxHeight: maxImageHeight)
        }
    }

    // MARK: - Block assembly (pure)

    static func blocks(from markdown: String) -> [Block] {
        var result: [Block] = []
        var paragraph: [Piece] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            result.append(.paragraph(paragraph))
            paragraph = []
        }

        for segment in MarkdownSegmenter.segments(in: markdown) {
            switch segment {
            case .text(let s):
                for line in s.components(separatedBy: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty {
                        flushParagraph()
                    } else if !paragraph.isEmpty {
                        paragraph.append(.text(" " + trimmed))
                    } else {
                        paragraph.append(.text(trimmed))
                    }
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
        return result
    }
}
