import SwiftUI
import SwiftMindCore

/// Greedy line-breaking flow layout that aligns each line's items on a
/// shared BASELINE instead of their top edges — inline math (fractions
/// especially) must sit on the text baseline, not below it.
///
/// Baselines are supplied per item (index-aligned with the subviews):
/// plain text uses font metrics, math views use `LaTeXMetrics`.
struct ParagraphFlowLayout: Layout {
    enum ItemKind {
        case text(fontSize: CGFloat)
        case math(latex: String, fontSize: CGFloat)
    }

    let items: [ItemKind]
    var spacing: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let (size, _) = layout(subviews: subviews, maxWidth: width)
        return size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (_, positions) = layout(subviews: subviews, maxWidth: bounds.width)
        for (index, subview) in subviews.enumerated() {
            guard index < positions.count else { break }
            subview.place(
                at: CGPoint(
                    x: bounds.minX + positions[index].x,
                    y: bounds.minY + positions[index].y
                ),
                proposal: .unspecified
            )
        }
    }

    private func baseline(at index: Int, height: CGFloat) -> CGFloat {
        guard index < items.count else { return height }
        switch items[index] {
        case .text(let fontSize):
            return LaTeXMetrics.textBox(fontSize).baseline
        case .math(let latex, let fontSize):
            let box = LaTeXMetrics.box(latex: latex, fontSize: fontSize)
            guard box.height > 0 else { return 0 }
            // Scale the estimated baseline to the actually-measured height.
            return box.baseline / box.height * height
        }
    }

    private func layout(
        subviews: Subviews, maxWidth: CGFloat
    ) -> (CGSize, [CGPoint]) {
        var lineBaselines: [CGFloat] = []
        var lineHeights: [CGFloat] = []
        var lineWidths: [CGFloat] = []

        var lineWidth: CGFloat = 0
        var lineBaseline: CGFloat = 0
        var lineBelow: CGFloat = 0

        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let itemBaseline = baseline(at: index, height: size.height)
            if lineWidth > 0, lineWidth + size.width > maxWidth, maxWidth.isFinite {
                lineBaselines.append(lineBaseline)
                lineHeights.append(lineBaseline + lineBelow)
                lineWidths.append(lineWidth)
                lineWidth = 0
                lineBaseline = 0
                lineBelow = 0
            }
            lineBaseline = max(lineBaseline, itemBaseline)
            lineBelow = max(lineBelow, size.height - itemBaseline)
            lineWidth += size.width + spacing
        }
        lineBaselines.append(lineBaseline)
        lineHeights.append(lineBaseline + lineBelow)
        lineWidths.append(lineWidth)

        // Second pass: positions (same wrap condition as pass one).
        var positions: [CGPoint] = []
        var y: CGFloat = 0
        var lineIndex = 0
        var x: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let itemBaseline = baseline(at: index, height: size.height)
            if x > 0, x + size.width > maxWidth, maxWidth.isFinite {
                y += lineHeights[lineIndex]
                lineIndex += 1
                x = 0
            }
            positions.append(CGPoint(x: x, y: y + lineBaselines[lineIndex] - itemBaseline))
            x += size.width + spacing
        }
        let total = CGSize(
            width: max(0, (lineWidths.max() ?? 0) - spacing),
            height: y + (lineHeights.last ?? 0)
        )
        return (total, positions)
    }
}
