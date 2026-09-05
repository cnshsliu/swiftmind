import SwiftUI

/// Renders a LaTeX subset (parsed by `LaTeXParser`) with plain SwiftUI.
/// Serif italic glyph runs, stacked fractions, baseline-shifted scripts,
/// and graceful degradation to visible monospace source for unknown
/// commands — content is never lost.
struct LaTeXMathView: View {
    let latex: String
    var fontSize: CGFloat = 12
    var block: Bool = false
    /// Measurement pass (MathBitmapRenderer): bars render pure red so the
    /// baseline can be located from pixels exactly.
    var measure = false

    var body: some View {
        let rows = LaTeXParser.rows(latex)
        let scale: CGFloat = block ? 1.12 : 1.0
        let size = fontSize * scale
        VStack(alignment: block ? .center : .leading, spacing: size * 0.5) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, atom in
                        AtomView(atom: atom, size: size, block: block, measure: measure)
                    }
                }
            }
        }
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
    var measure: Bool = false

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
                    AtomView(atom: sup, size: size * 0.62, block: block)
                        .baselineOffset(size * 0.32)
                }
                if let sub {
                    AtomView(atom: sub, size: size * 0.62, block: block)
                        .baselineOffset(-size * 0.18)
                }
            }
        case .command(let name, let args):
            CommandView(name: name, args: args, size: size, block: block, measure: measure)
        }
    }
}

private struct CommandView: View {
    let name: String
    let args: [[MathAST]]
    let size: CGFloat
    let block: Bool
    var measure: Bool = false

    private var barColor: Color {
        measure ? Color(red: 1, green: 0, blue: 0) : .primary
    }

    var body: some View {
        switch name {
        case "frac":
            let inner = size * 0.85
            VStack(spacing: 1) {
                RowView(atoms: args.first ?? [], size: inner, block: block)
                Rectangle()
                    .fill(barColor)
                    .frame(height: 0.8)
                RowView(atoms: args.count > 1 ? args[1] : [], size: inner, block: block)
            }
            // Rectangle is greedy: without fixedSize the bar stretches to
            // the full proposed width instead of the numerator's width.
            .fixedSize(horizontal: true, vertical: false)
            // The fraction bar is the math baseline: without this guide the
            // surrounding row would align its text with the denominator.
            .alignmentGuide(.firstTextBaseline) { $0.height / 2 }
        case "sqrt":
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("√")
                    .font(.system(size: size * 1.25))
                    .baselineOffset(size * 0.08)
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(barColor)
                        .frame(height: 1)
                    RowView(atoms: args.first ?? [], size: size, block: block)
                }
                .fixedSize(horizontal: true, vertical: false)
                .alignmentGuide(.firstTextBaseline) { $0.height / 2 }
            }
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
