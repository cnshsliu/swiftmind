import SwiftUI
import SwiftMindCore

/// PPT-style color picker for the sketch board: preset swatches plus custom
/// RGB input, with an optional "no color" (transparent) row. One component
/// backs the board background, text/sticky backgrounds, and shape fills.
struct SketchColorPicker: View {
    let title: String
    /// Shows the "No Fill" row when the target supports transparency.
    var supportsNone: Bool = false
    /// Current hex ("#RRGGBB"); nil = none/default.
    @Binding var selection: String?
    let identifier: String

    @State private var presented = false
    @State private var red = ""
    @State private var green = ""
    @State private var blue = ""

    /// Swatch palette: paper tones, basics, and saturated accents.
    static let presets: [String] = [
        "#FFFFFF", "#F2F2F7", "#BDBDC2", "#000000",
        "#FFF8E1", "#FFF685", "#FFD1E8", "#FF6B6B",
        "#C8E6FF", "#4A90D9", "#D6F5D0", "#34C759",
    ]

    var body: some View {
        Button {
            syncFields()
            presented.toggle()
        } label: {
            RoundedRectangle(cornerRadius: 4)
                .fill(swatchColor)
                .frame(width: 18, height: 18)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1)
                )
                .overlay {
                    if selection == nil, supportsNone {
                        // diagonal "none" strike
                        Line()
                            .stroke(Color.red.opacity(0.8), lineWidth: 1.5)
                            .frame(width: 22, height: 22)
                    }
                }
        }
        .buttonStyle(.borderless)
        .help(title)
        .accessibilityIdentifier(identifier)
        .popover(isPresented: $presented, arrowEdge: .bottom) {
            pickerPanel
        }
    }

    private var swatchColor: Color {
        selection.map { Color(nsColor: SketchTextSupport.hexColor($0)) }
            ?? Color(nsColor: .controlBackgroundColor)
    }

    private var pickerPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)

            if supportsNone {
                Button {
                    selection = nil
                    presented = false
                } label: {
                    Label("No Fill", systemImage: "slash.circle")
                }
                .accessibilityIdentifier(identifier + "None")
            }

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 6), count: 6), spacing: 6) {
                ForEach(Self.presets, id: \.self) { hex in
                    Button {
                        selection = hex
                        presented = false
                    } label: {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(nsColor: SketchTextSupport.hexColor(hex)))
                            .frame(width: 26, height: 26)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(
                                        selection == hex ? Color.accentColor : Color.secondary.opacity(0.45),
                                        lineWidth: selection == hex ? 2 : 1
                                    )
                            )
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier(identifier + "-" + hex)
                }
            }

            Divider()

            HStack(spacing: 6) {
                Text("RGB").font(.caption).foregroundStyle(.secondary)
                rgbField("R", $red)
                rgbField("G", $green)
                rgbField("B", $blue)
                Button("Apply") { applyRGB() }
                    .controlSize(.small)
                    .disabled(!rgbValid)
                    .accessibilityIdentifier(identifier + "ApplyRGB")
                RoundedRectangle(cornerRadius: 3)
                    .fill(rgbPreview)
                    .frame(width: 20, height: 20)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.secondary.opacity(0.5)))
            }
        }
        .padding(12)
        .frame(width: 246)
    }

    private func rgbField(_ label: String, _ value: Binding<String>) -> some View {
        TextField(label, text: value)
            .textFieldStyle(.roundedBorder)
            .frame(width: 42)
            .onSubmit { applyRGB() }
    }

    private var rgbComponents: (Int, Int, Int)? {
        func parse(_ s: String) -> Int? {
            guard let v = Int(s.trimmingCharacters(in: .whitespaces)), (0...255).contains(v) else {
                return nil
            }
            return v
        }
        guard let r = parse(red), let g = parse(green), let b = parse(blue) else { return nil }
        return (r, g, b)
    }

    private var rgbValid: Bool { rgbComponents != nil }

    private var rgbPreview: Color {
        if let (r, g, b) = rgbComponents {
            Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
        } else {
            Color(nsColor: .controlBackgroundColor)
        }
    }

    private func applyRGB() {
        guard let (r, g, b) = rgbComponents else { return }
        selection = String(format: "#%02X%02X%02X", r, g, b)
        presented = false
    }

    /// Prefill the RGB fields from the current selection (nil → empty).
    private func syncFields() {
        guard let hex = selection,
              hex.count == 7, hex.hasPrefix("#"),
              let value = UInt64(hex.dropFirst(), radix: 16) else {
            red = ""; green = ""; blue = ""
            return
        }
        red = String((value >> 16) & 0xFF)
        green = String((value >> 8) & 0xFF)
        blue = String(value & 0xFF)
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            return p
        }
    }
}
