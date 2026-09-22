import Foundation

public struct MarkdownMeasure: Equatable, Sendable {
    public var width: Double
    public var charWidth: Double
    public var lineHeight: Double
    public var imageHeight: Double

    public init(width: Double, charWidth: Double, lineHeight: Double, imageHeight: Double) {
        self.width = width
        self.charWidth = charWidth
        self.lineHeight = lineHeight
        self.imageHeight = imageHeight
    }

    public func height(of source: String) -> Double {
        MarkdownDocument.parse(source).blocks.reduce(0) { $0 + height(of: $1, in: source) }
    }

    private func height(of block: MarkdownBlock, in source: String) -> Double {
        let own: Double
        switch block.kind {
        case .image:
            own = imageHeight
        case .codeFence, .mathBlock:
            let text = block.inlines.compactMap { inline -> String? in
                guard case .text(let range) = inline else { return nil }
                return String(source[range])
            }.joined()
            let rows = max(1, text.split(separator: "\n", omittingEmptySubsequences: false).count)
            own = Double(rows) * lineHeight
        case .heading(let level):
            let scale = level == 1 ? 1.4 : (level == 2 ? 1.2 : 1.0)
            own = lineHeight * scale
        default:
            own = wrapped(plain(block.inlines, in: source))
        }
        return own + block.children.reduce(0) { $0 + height(of: $1, in: source) }
    }

    private func wrapped(_ text: String) -> Double {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        let perLine = max(1, Int(width / max(charWidth, 1)))
        let rows = trimmed.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) { sum, line in
            sum + max(1, (line.count + perLine - 1) / perLine)
        }
        return Double(rows) * lineHeight
    }

    private func plain(_ inlines: [MarkdownInline], in source: String) -> String {
        inlines.map { inline -> String in
            switch inline {
            case .text(let range), .code(_, let range, _), .math(_, let range, _):
                return String(source[range])
            case .strong(_, let content, _), .emphasis(_, let content, _):
                return plain(content, in: source)
            case .link(_, let label, _, _, _):
                return plain(label, in: source)
            }
        }.joined()
    }
}
