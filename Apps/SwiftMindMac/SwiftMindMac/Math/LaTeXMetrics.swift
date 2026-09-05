import AppKit
import SwiftMindCore

/// Mirrors `LaTeXMathView`'s geometry numerically so paragraph layout can
/// place math on the text baseline. Pure estimation — heights come from the
/// same font metrics the renderer uses (rounded up like SwiftUI Text).
enum LaTeXMetrics {
    struct Box {
        var height: CGFloat
        /// Distance from the top of the box to the math baseline.
        var baseline: CGFloat
    }

    static func box(latex: String, fontSize: CGFloat, block: Bool = false) -> Box {
        let scale: CGFloat = block ? 1.12 : 1.0
        let size = fontSize * scale
        let rows = LaTeXParser.rows(latex)
        let rowBoxes = rows.map { row($0, size: size) }
        let rowSpacing = size * 0.5
        let height = rowBoxes.map(\.height).reduce(0, +)
            + rowSpacing * CGFloat(max(0, rowBoxes.count - 1))
        // First row's baseline (multi-row block math sits below it).
        let baseline = rowBoxes.first?.baseline ?? textBox(size).baseline
        return Box(height: height, baseline: baseline)
    }

    static func row(_ atoms: [MathAST], size: CGFloat) -> Box {
        let boxes = atoms.map { atomBox($0, size: size) }
        guard !boxes.isEmpty else { return textBox(size) }
        let baseline = boxes.map(\.baseline).max()!
        let below = boxes.map { $0.height - $0.baseline }.max()!
        return Box(height: baseline + below, baseline: baseline)
    }

    /// Distance from the fraction view's TOP to the center of the bar,
    /// mirroring the VStack(spacing: 1) { num; rule(0.8); den } geometry.
    /// This is NOT height/2 when the numerator is taller (e.g. \sqrt{\pi}).
    static func fracBarOffset(
        numerator: [MathAST], denominator: [MathAST], size: CGFloat
    ) -> CGFloat {
        let inner = size * 0.85
        return row(numerator, size: inner).height + 1 + 0.4
    }

    private static func atomBox(_ atom: MathAST, size: CGFloat) -> Box {
        switch atom {
        case .run, .text:
            return textBox(size)
        case .group(let inner):
            return row(inner, size: size)
        case .space:
            return Box(height: 1, baseline: 0)
        case .scripts(let base, let sup, let sub):
            var parts: [Box] = [atomBox(base, size: size)]
            let scriptSize = size * MathTypography.scriptScale
            let script = textBox(scriptSize)
            if sup != nil {
                // Renderer: baselineOffset(+0.32*size) above the base line.
                parts.append(Box(
                    height: script.height + MathTypography.superscriptShift * size,
                    baseline: MathTypography.superscriptShift * size
                ))
            }
            if sub != nil {
                parts.append(Box(
                    height: script.height + MathTypography.subscriptShift * size,
                    baseline: 0
                ))
            }
            let baseline = parts.map(\.baseline).max()!
            let below = parts.map { $0.height - $0.baseline }.max()!
            return Box(height: baseline + below, baseline: baseline)
        case .command(let name, let args):
            switch name {
            case "frac":
                let inner = size * 0.85
                let num = row(args.first ?? [], size: inner)
                let den = row(args.count > 1 ? args[1] : [], size: inner)
                // VStack(spacing: 1) { num; rule(0.8); den }
                let height = num.height + 1 + 0.8 + 1 + den.height
                // Baseline = the TRUE bar position (not height/2 when the
                // numerator is taller) + math axis (~0.28em).
                let bar = num.height + 1 + 0.4
                return Box(height: height, baseline: bar + size * MathTypography.axis)
            case "sqrt":
                let content = row(args.first ?? [], size: size)
                let height = 1 + content.height // overline + content
                return Box(height: height, baseline: height / 2 + size * MathTypography.axis)
            default:
                var parts = [textBox(size)]
                for _ in args { parts.append(textBox(size)) }
                let baseline = parts.map(\.baseline).max()!
                let below = parts.map { $0.height - $0.baseline }.max()!
                return Box(height: baseline + below, baseline: baseline)
            }
        }
    }

    /// A `Text` run: SwiftUI view height is the font line height rounded
    /// up; the baseline sits at ascender from the line-box top.
    static func textBox(_ size: CGFloat) -> Box {
        let font = NSFont.systemFont(ofSize: size)
        let line_height = font.ascender - font.descender
        let viewHeight = (line_height).rounded(.up)
        let topPad = (viewHeight - line_height) / 2
        return Box(height: viewHeight, baseline: topPad + font.ascender)
    }
}
