import SwiftUI

/// Greedy line-breaking flow layout so inline math views and `Text` runs
/// wrap together inside a paragraph.
struct FlowLayout: Layout {
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

    private func layout(
        subviews: Subviews, maxWidth: CGFloat
    ) -> (CGSize, [CGPoint]) {
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth, maxWidth.isFinite {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return (CGSize(width: maxX, height: y + lineHeight), positions)
    }
}
