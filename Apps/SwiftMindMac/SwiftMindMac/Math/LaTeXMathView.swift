import SwiftUI

/// Renders a LaTeX subset (parsed by `LaTeXParser`) with plain SwiftUI.
/// Serif italic glyph runs, stacked fractions, baseline-shifted scripts,
/// and graceful degradation to visible monospace source for unknown
/// commands — content is never lost.
struct LaTeXMathView: View {
    let latex: String
    var fontSize: CGFloat = 12
    var block: Bool = false

    var body: some View {
        let rows = LaTeXParser.rows(latex)
        let scale: CGFloat = block ? 1.12 : 1.0
        let size = fontSize * scale
        VStack(alignment: block ? .center : .leading, spacing: size * 0.5) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, atom in
                        AtomView(atom: atom, size: size, block: block)
                    }
                }
            }
        }
        .fixedSize(horizontal: true, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(latex)
    }
}

/// Single-atom renderer as its own view type (recursive helpers with opaque
/// return types do not compile).
private struct AtomView: View {
    let atom: MathAST
    let size: CGFloat
    let block: Bool

    var body: some View {
        switch atom {
        case .run(let glyphs):
            Text(glyphs)
                .font(.system(size: size, design: block ? .serif : .default).italic())
        case .group(let inner):
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                ForEach(Array(inner.enumerated()), id: \.offset) { _, child in
                    AtomView(atom: child, size: size, block: block)
                }
            }
        case .text(let content):
            Text(content)
                .font(.system(size: size))
        case .space(let points):
            Color.clear.frame(width: points * (size / 12.0), height: 1)
        case .scripts(let base, let sup, let sub):
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                AtomView(atom: base, size: size, block: block)
                if let sup {
                        AtomView(atom: sup, size: size * MathTypography.scriptScale, block: block)
                        .baselineOffset(size * MathTypography.superscriptShift)
                }
                if let sub {
                        AtomView(atom: sub, size: size * MathTypography.scriptScale, block: block)
                        .baselineOffset(-size * MathTypography.subscriptShift)
                }
            }
        case .command(let name, let args):
            CommandView(name: name, args: args, size: size, block: block)
        }
    }
}

private struct CommandView: View {
    let name: String
    let args: [[MathAST]]
    let size: CGFloat
    let block: Bool

    var body: some View {
        switch name {
        case "frac":
            FracView(args: args, size: size, block: block)
        case "sqrt":
            SqrtView(args: args, size: size, block: block)
        default:
            // Unknown command: show the source so nothing silently
            // disappears, followed by any arguments.
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text("\\\(name)")
                    .font(.system(size: size, design: .monospaced))
                    .foregroundStyle(.secondary)
                ForEach(Array(args.enumerated()), id: \.offset) { _, arg in
                    RowView(atoms: arg, size: size, block: block)
                }
            }
        }
    }
}

/// Fraction aligned with `LaTeXMetrics.fracBarOffset` — never PreferenceKey /
/// GeometryReader / `@State`. Writing state during an AppKit layout pass is
/// what produced the exclusivity SIGSEGV / `_postWindowNeedsUpdateConstraints`
/// abort (24 of 33 local crash reports).
private struct FracView: View {
    let args: [[MathAST]]
    let size: CGFloat
    let block: Bool

    var body: some View {
        let inner = size * 0.85
        let num = args.first ?? []
        let den = args.count > 1 ? args[1] : []
        let barFromTop = LaTeXMetrics.fracBarOffset(
            numerator: num, denominator: den, size: size
        )
        VStack(spacing: 1) {
            RowView(atoms: num, size: inner, block: block)
            Rectangle()
                .fill(.primary)
                .frame(height: 0.8)
            RowView(atoms: den, size: inner, block: block)
        }
        .fixedSize(horizontal: true, vertical: true)
        .alignmentGuide(.firstTextBaseline) { d in
            min(d.height - 0.5, barFromTop + size * MathTypography.axis)
        }
    }
}

/// One path for the surd + vinculum so the check meets the overbar.
private struct SqrtView: View {
    let args: [[MathAST]]
    let size: CGFloat
    let block: Bool

    var body: some View {
        let bar = max(1.0, size * 0.07)
        RowView(atoms: args.first ?? [], size: size, block: block)
            .padding(.top, size * 0.14)
            .padding(.leading, size * 0.62)
            .padding(.trailing, size * 0.08)
            .overlay {
                RadicalVinculum(bar: bar)
                    .stroke(
                        Color.primary,
                        style: StrokeStyle(
                            lineWidth: bar,
                            lineCap: .butt,
                            lineJoin: .miter
                        )
                    )
            }
            .fixedSize()
    }
}

private struct RadicalVinculum: Shape {
    var bar: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let h = rect.height
        let yBar = rect.minY + bar / 2
        let surdW = min(max(rect.width * 0.22, bar * 8), h * 0.46)
        p.move(to: CGPoint(x: rect.minX + bar * 0.2, y: h * 0.56))
        p.addLine(to: CGPoint(x: rect.minX + surdW * 0.36, y: h - bar * 0.55))
        p.addLine(to: CGPoint(x: rect.minX + surdW, y: yBar))
        p.addLine(to: CGPoint(x: rect.maxX - bar * 0.15, y: yBar))
        return p
    }
}

private struct RowView: View {
    let atoms: [MathAST]
    let size: CGFloat
    let block: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            ForEach(Array(atoms.enumerated()), id: \.offset) { _, child in
                AtomView(atom: child, size: size, block: block)
            }
        }
    }
}
