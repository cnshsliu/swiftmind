import SwiftUI
import SwiftMindCore

struct MapCanvasView: View {
    @ObservedObject var session: DocumentSession

    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    /// Base scale captured at magnify gesture begin (so magnification multiplies, not replaces).
    @State private var magnifyBase: CGFloat = 1
    /// Base pan offset captured at drag gesture begin.
    @State private var panBase: CGSize = .zero
    @State private var canvasSize: CGSize = .zero

    private static let minScale: CGFloat = 0.25
    private static let maxScale: CGFloat = 3

    var body: some View {
        // Depend on revision so layout redraws after store mutations.
        let _ = session.revision
        let snapshot = session.store.snapshot()

        GeometryReader { geo in
            Canvas { context, size in
                draw(snapshot: snapshot, context: &context, size: size)
            }
            .contentShape(Rectangle())
            .onAppear {
                canvasSize = geo.size
            }
            .onChange(of: geo.size) { _, newSize in
                canvasSize = newSize
            }
            .gesture(panGesture)
            .simultaneousGesture(magnifyGesture)
            .gesture(tapSelectGesture(snapshot: snapshot))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .clipped()
        .accessibilityLabel("Mind map canvas")
    }

    // MARK: - Drawing

    private func draw(snapshot: MapSnapshot, context: inout GraphicsContext, size: CGSize) {
        context.translateBy(x: size.width / 2 + offset.width, y: size.height / 2 + offset.height)
        context.scaleBy(x: scale, y: scale)

        for edge in snapshot.edges {
            var path = Path()
            path.move(to: CGPoint(x: edge.fromPoint.x, y: edge.fromPoint.y))
            path.addLine(to: CGPoint(x: edge.toPoint.x, y: edge.toPoint.y))
            context.stroke(path, with: .color(.secondary), lineWidth: 1.5 / scale)
        }

        for node in snapshot.nodes {
            let rect = CGRect(
                x: node.frame.x,
                y: node.frame.y,
                width: node.frame.width,
                height: node.frame.height
            )
            let path = Path(roundedRect: rect, cornerRadius: 8)

            if let fr = node.style.fillRed,
               let fg = node.style.fillGreen,
               let fb = node.style.fillBlue {
                context.fill(path, with: .color(Color(red: fr, green: fg, blue: fb)))
            } else {
                context.fill(path, with: .color(Color(nsColor: .controlBackgroundColor)))
            }

            let strokeColor = node.isSelected
                ? Color.accentColor
                : Color.secondary.opacity(0.5)
            let strokeWidth = (node.isSelected ? 2.0 : 1.0) / scale
            context.stroke(path, with: .color(strokeColor), lineWidth: strokeWidth)

            let textColor = Color(
                red: node.style.textRed,
                green: node.style.textGreen,
                blue: node.style.textBlue
            )
            let text = Text(node.text)
                .font(.system(
                    size: node.style.fontSize,
                    weight: node.style.isBold ? .bold : .regular
                ))
                .foregroundColor(textColor)
            context.draw(text, in: rect.insetBy(dx: 6, dy: 4))
        }
    }

    // MARK: - Gestures

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                offset = CGSize(
                    width: panBase.width + value.translation.width,
                    height: panBase.height + value.translation.height
                )
            }
            .onEnded { _ in
                panBase = offset
            }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let next = magnifyBase * value.magnification
                scale = min(Self.maxScale, max(Self.minScale, next))
            }
            .onEnded { _ in
                magnifyBase = scale
            }
    }

    private func tapSelectGesture(snapshot: MapSnapshot) -> some Gesture {
        SpatialTapGesture()
            .onEnded { event in
                if let id = hitTest(event.location, snapshot: snapshot, viewSize: canvasSize) {
                    session.select(id)
                }
            }
    }

    // MARK: - Hit testing

    /// Convert a view-space tap into map coordinates by inverting the
    /// canvas transform (center + pan, then scale), then test node frames
    /// back-to-front so later-drawn nodes win.
    private func hitTest(
        _ location: CGPoint,
        snapshot: MapSnapshot,
        viewSize: CGSize
    ) -> NodeID? {
        guard viewSize.width > 0, viewSize.height > 0, scale > 0 else { return nil }

        let mapX = (location.x - viewSize.width / 2 - offset.width) / scale
        let mapY = (location.y - viewSize.height / 2 - offset.height) / scale

        for node in snapshot.nodes.reversed() {
            let f = node.frame
            if mapX >= f.x, mapX <= f.x + f.width,
               mapY >= f.y, mapY <= f.y + f.height {
                return node.id
            }
        }
        return nil
    }
}

#Preview {
    MapCanvasView(session: DocumentSession(map: .makeEmpty(title: "Preview")))
}
