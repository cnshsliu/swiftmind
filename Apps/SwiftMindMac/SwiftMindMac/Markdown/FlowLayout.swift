import SwiftUI
import SwiftMindCore

/// Greedy line-breaking flow layout that aligns each line's items on a
/// shared BASELINE instead of their top edges — inline math (fractions
/// especially) must sit on the text baseline, not below it.
///
/// Baselines are supplied per item (index-aligned with the subviews):
/// plain text uses font metrics, math views use `LaTeXMetrics`.
///
/// A single item wider than the proposed width (e.g. a long paragraph of
/// text in the narrow inspector) is placed with a bounded width proposal so
/// `Text` wraps internally. Never report a size wider than the proposal —
/// doing so puts the inspector's AppKit constraint pass into a re-layout
/// loop that ends in a crash.
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
        let (_, placements) = layout(subviews: subviews, maxWidth: bounds.width)
        for (index, subview) in subviews.enumerated() {
            guard index < placements.count else { break }
            let placement = placements[index]
            subview.place(
                at: CGPoint(
                    x: bounds.minX + placement.position.x,
                    y: bounds.minY + placement.position.y
                ),
                proposal: placement.proposal
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

    private struct Placement {
        var position: CGPoint
        var proposal: ProposedViewSize
    }

    /// A piece that alone exceeds `maxWidth` is re-measured with that width
    /// so text wraps (math views keep their size and are clipped by the
    /// parent, as before). The reported width never exceeds `maxWidth`.
    private func measuredSize(of subview: Subviews.Element, maxWidth: CGFloat) -> (CGSize, Bool) {
        let ideal = subview.sizeThatFits(.unspecified)
        guard maxWidth.isFinite, ideal.width > maxWidth else { return (ideal, false) }
        let wrapped = subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
        return (CGSize(width: min(wrapped.width, maxWidth), height: wrapped.height), true)
    }

    private func layout(
        subviews: Subviews, maxWidth: CGFloat
    ) -> (CGSize, [Placement]) {
        // Pass 1: assign pieces to lines, measuring wrap-aware sizes.
        struct LineItem {
            var index: Int
            var size: CGSize
            var wrapped: Bool
            var baseline: CGFloat
        }
        struct Line {
            var width: CGFloat = 0
            var baseline: CGFloat = 0
            var below: CGFloat = 0
            var items: [LineItem] = []
            var height: CGFloat { baseline + below }
        }

        var lines: [Line] = [Line()]
        for (index, subview) in subviews.enumerated() {
            let ideal = subview.sizeThatFits(.unspecified)
            if lines[lines.count - 1].width > 0,
               lines[lines.count - 1].width + ideal.width > maxWidth,
               maxWidth.isFinite {
                lines.append(Line())
            }
            let (size, wrapped) = measuredSize(of: subview, maxWidth: maxWidth)
            let itemBaseline = baseline(at: index, height: size.height)
            var line = lines[lines.count - 1]
            line.baseline = max(line.baseline, itemBaseline)
            line.below = max(line.below, size.height - itemBaseline)
            line.width += size.width + spacing
            line.items.append(LineItem(index: index, size: size, wrapped: wrapped, baseline: itemBaseline))
            lines[lines.count - 1] = line
        }

        // Pass 2: positions.
        var placements: [Placement] = []
        var y: CGFloat = 0
        for line in lines {
            var x: CGFloat = 0
            for item in line.items {
                placements.append(Placement(
                    position: CGPoint(x: x, y: y + line.baseline - item.baseline),
                    proposal: item.wrapped ? ProposedViewSize(width: maxWidth, height: nil) : .unspecified
                ))
                x += item.size.width + spacing
            }
            y += line.height
        }

        let maxLineWidth = lines.map { max(0, $0.width - spacing) }.max() ?? 0
        let total = CGSize(
            width: maxWidth.isFinite ? min(maxLineWidth, maxWidth) : maxLineWidth,
            height: y
        )
        return (total, placements)
    }
}
