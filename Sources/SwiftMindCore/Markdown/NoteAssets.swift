import Foundation

/// Note images live as files beside the document, not as base64 inside the
/// note text. `报告.swiftmind.html` stores them in `报告.swiftmind.assets/`.
public enum NoteAssets {
    public static let folderSuffix = ".swiftmind.assets"

    public struct File: Equatable, Sendable {
        public var relativePath: String
        public var data: Data

        public init(relativePath: String, data: Data) {
            self.relativePath = relativePath
            self.data = data
        }
    }

    /// `报告.swiftmind.html` → `报告.swiftmind.assets`.
    public static func folderName(forDocumentFileName name: String) -> String {
        let lower = name.lowercased()
        if lower.hasSuffix(".swiftmind.html") {
            return String(name.dropLast(".html".count)) + ".assets"
        }
        if lower.hasSuffix(".html") || lower.hasSuffix(".htm") {
            let cut = lower.hasSuffix(".html") ? 5 : 4
            return String(name.dropLast(cut)) + ".assets"
        }
        return name + folderSuffix
    }

    /// Stable file name for the same bytes, so one picture is stored once.
    public static func fileName(for data: Data, ext: String = "png") -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "img-%llu-%016llx.%@", UInt64(data.count), hash, ext as NSString)
    }

    public static func decodeDataImage(_ url: String) -> (data: Data, ext: String)? {
        guard url.hasPrefix("data:image/"),
              let comma = url.firstIndex(of: ","),
              url[..<comma].contains("base64")
        else { return nil }
        let meta = url[..<comma].lowercased()
        let payload = String(url[url.index(after: comma)...])
        guard let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters),
              !data.isEmpty else { return nil }
        let ext: String
        if meta.contains("image/jpeg") || meta.contains("image/jpg") {
            ext = "jpg"
        } else if meta.contains("image/gif") {
            ext = "gif"
        } else if meta.contains("image/webp") {
            ext = "webp"
        } else if meta.contains("image/svg") {
            ext = "svg"
        } else {
            ext = "png"
        }
        return (data, ext)
    }

    /// Replace `data:image` URLs in note markdown with `folder/img-….png`.
    /// Other text is left as it is. The same bytes always get the same path.
    public static func externalizeDataImages(
        in markdown: String,
        folderName: String
    ) -> (markdown: String, files: [File]) {
        guard markdown.contains("data:image/") else { return (markdown, []) }
        let document = MarkdownDocument.parse(markdown)
        var hits: [(range: NSRange, file: File)] = []
        func consider(_ url: Range<String.Index>) {
            let text = String(markdown[url])
            guard let decoded = decodeDataImage(text),
                  let start = utf16(url.lowerBound, in: markdown),
                  let end = utf16(url.upperBound, in: markdown),
                  end >= start else { return }
            let name = fileName(for: decoded.data, ext: decoded.ext)
            let relative = folderName + "/" + name
            hits.append((
                NSRange(location: start, length: end - start),
                File(relativePath: relative, data: decoded.data)
            ))
        }
        func walkInlines(_ inlines: [MarkdownInline]) {
            for inline in inlines {
                switch inline {
                case .image(_, let url):
                    consider(url)
                case .strong(_, let content, _), .emphasis(_, let content, _),
                     .strikethrough(_, let content, _), .highlight(_, let content, _),
                     .link(_, let content, _, _, _):
                    walkInlines(content)
                default:
                    break
                }
            }
        }
        func walk(_ blocks: [MarkdownBlock]) {
            for block in blocks {
                if case .image(_, let url) = block.kind { consider(url) }
                walkInlines(block.inlines)
                walk(block.children)
            }
        }
        walk(document.blocks)
        guard !hits.isEmpty else { return (markdown, []) }
        hits.sort { $0.range.location > $1.range.location }
        var ns = markdown as NSString
        var files: [File] = []
        var seen = Set<String>()
        for hit in hits {
            ns = ns.replacingCharacters(in: hit.range, with: hit.file.relativePath) as NSString
            if seen.insert(hit.file.relativePath).inserted {
                files.append(hit.file)
            }
        }
        return (ns as String, files)
    }

    private static func utf16(_ index: String.Index, in source: String) -> Int? {
        guard let utf16 = index.samePosition(in: source.utf16) else { return nil }
        return source.utf16.distance(from: source.utf16.startIndex, to: utf16)
    }
}
