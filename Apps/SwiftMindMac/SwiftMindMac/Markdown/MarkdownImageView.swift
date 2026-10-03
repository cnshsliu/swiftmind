import SwiftUI
import AppKit

/// Renders a note image. `data:` URIs and files in the document's
/// `.swiftmind.assets` folder decode locally. Other remote URLs stay a
/// placeholder.
struct MarkdownImageView: View {
    let alt: String
    let urlString: String
    /// Square display box (points) the image scales to fit inside.
    var maxHeight: CGFloat = 200
    var noteAssets: NoteAssetStore? = nil

    var body: some View {
        if let image = decodedImage {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: maxHeight, maxHeight: maxHeight)
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
        if let stored = noteAssets?.image(for: urlString) { return stored }
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

    func image(in source: String, url: Range<String.Index>) -> NSImage? {
        let ns = source as NSString
        guard let startUTF = url.lowerBound.samePosition(in: source.utf16),
              let endUTF = url.upperBound.samePosition(in: source.utf16) else { return nil }
        let location = source.utf16.distance(from: source.utf16.startIndex, to: startUTF)
        let length = source.utf16.distance(from: startUTF, to: endUTF)
        guard length > 0, location >= 0, location + length <= ns.length else { return nil }
        let headLength = min(64, length)
        let tailLength = min(32, length)
        let head = ns.substring(with: NSRange(location: location, length: headLength))
        let tail = ns.substring(with: NSRange(location: location + length - tailLength, length: tailLength))
        let key = "\(length)|\(head)|\(tail)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let urlString = ns.substring(with: NSRange(location: location, length: length))
        guard urlString.hasPrefix("data:"),
              let comma = urlString.firstIndex(of: ","),
              let data = Data(base64Encoded: String(urlString[urlString.index(after: comma)...]),
                              options: .ignoreUnknownCharacters),
              let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}
