import SwiftUI
import AppKit

/// Renders a standalone markdown image line. `data:` URIs decode locally
/// (cached); remote URLs are never fetched (the app has no network
/// entitlement) and render as a placeholder.
struct MarkdownImageView: View {
    let alt: String
    let urlString: String
    var maxHeight: CGFloat = 200

    var body: some View {
        if let image = decodedImage {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: maxHeight)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .accessibilityLabel(alt.isEmpty ? "Image" : alt)
        } else {
            Label(alt.isEmpty ? "Remote image (not fetched)" : alt, systemImage: "photo")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                )
                .accessibilityLabel(alt.isEmpty ? "Remote image placeholder" : alt)
        }
    }

    private var decodedImage: NSImage? {
        guard urlString.hasPrefix("data:") else { return nil }
        guard let comma = urlString.firstIndex(of: ",") else { return nil }
        let payload = String(urlString[urlString.index(after: comma)...])
        guard let data = Data(base64Encoded: payload) else { return nil }
        return MarkdownImageCache.shared.image(for: urlString, data: data)
    }
}

/// Decodes and caches data-URI images: notes re-render per keystroke while
/// the editor is open, so decoding must be memoized.
final class MarkdownImageCache {
    static let shared = MarkdownImageCache()
    private init() {}
    private let cache = NSCache<NSString, NSImage>()

    func image(for key: String, data: Data) -> NSImage? {
        if let hit = cache.object(forKey: key as NSString) { return hit }
        guard let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: key as NSString)
        return image
    }
}
