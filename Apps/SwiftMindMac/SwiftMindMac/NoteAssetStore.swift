import AppKit
import SwiftMindCore

/// Picture bytes for the open document. The note text only stores a relative
/// path such as `报告.swiftmind.assets/img-12-abcd.png`.
@MainActor
final class NoteAssetStore {
    private(set) var documentURL: URL?
    private var folderName: String
    /// Relative path → bytes. Also the cache for files already on disk.
    private var memory: [String: Data] = [:]
    private static let bookmarkKey = "swiftmind.assetDirectoryBookmarks"

    /// After the document file itself is renamed. Rewrites cached paths.
    func relocate(to newURL: URL) {
        let newFolder = NoteAssets.folderName(forDocumentFileName: newURL.lastPathComponent)
        if newFolder != folderName {
            let prefix = folderName + "/"
            var next: [String: Data] = [:]
            for (key, data) in memory {
                if key.hasPrefix(prefix) {
                    next[newFolder + "/" + String(key.dropFirst(prefix.count))] = data
                } else {
                    next[key] = data
                }
            }
            memory = next
            folderName = newFolder
        }
        documentURL = newURL
        startAccessingFolder()
    }

    init(documentURL: URL? = nil) {
        self.documentURL = documentURL
        self.folderName = documentURL.map {
            NoteAssets.folderName(forDocumentFileName: $0.lastPathComponent)
        } ?? "Untitled.swiftmind.assets"
        startAccessingFolder()
    }

    /// Markdown for a newly inserted picture. The bytes stay in memory until
    /// the next save writes the file.
    func markdown(alt: String, png: Data) -> String {
        let relative = folderName + "/" + NoteAssets.fileName(for: png, ext: "png")
        memory[relative] = png
        return "![\(Self.sanitizedAlt(alt))](\(relative))"
    }

    func image(for reference: String) -> NSImage? {
        let path = reference.hasPrefix("./") ? String(reference.dropFirst(2)) : reference
        guard let data = bytes(for: path) else { return nil }
        return MarkdownImageCache.shared.image(for: path, data: data)
    }

    /// Pull `data:image` URLs out of every note. Returns whether any note changed.
    func extractEmbeddedImages(from map: inout MindMap) -> Bool {
        extract(&map.root)
    }

    /// Write pending pictures next to the document. Existing identical files
    /// are left untouched so a save does not look like an external edit.
    func flush() throws {
        guard let documentURL, !memory.isEmpty else { return }
        let root = documentURL.deletingLastPathComponent()
        let directory = root.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        rememberAccess(to: directory)
        for (relative, data) in memory {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            if let existing = try? Data(contentsOf: url), existing == data { continue }
            try data.write(to: url, options: .atomic)
        }
    }

    private func bytes(for relativePath: String) -> Data? {
        if let hit = memory[relativePath] { return hit }
        guard let documentURL else { return nil }
        let url = documentURL.deletingLastPathComponent().appendingPathComponent(relativePath)
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        memory[relativePath] = data
        return data
    }

    private func extract(_ node: inout Node) -> Bool {
        var changed = false
        let result = NoteAssets.externalizeDataImages(in: node.noteMarkdown, folderName: folderName)
        if result.markdown != node.noteMarkdown {
            node.noteMarkdown = result.markdown
            changed = true
        }
        for file in result.files {
            memory[file.relativePath] = file.data
        }
        for index in node.children.indices where extract(&node.children[index]) {
            changed = true
        }
        return changed
    }

    private static func sanitizedAlt(_ alt: String) -> String {
        let cleaned = alt
            .replacingOccurrences(of: "]", with: "")
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "image" : String(cleaned.prefix(80))
    }

    private func startAccessingFolder() {
        guard let documentURL else { return }
        let directory = documentURL.deletingLastPathComponent().appendingPathComponent(folderName)
        guard let data = bookmarks[directory.path] else { return }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return }
        _ = url.startAccessingSecurityScopedResource()
    }

    private func rememberAccess(to directory: URL) {
        guard let data = try? directory.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }
        var all = bookmarks
        all[directory.path] = data
        UserDefaults.standard.set(all, forKey: Self.bookmarkKey)
    }

    private var bookmarks: [String: Data] {
        UserDefaults.standard.dictionary(forKey: Self.bookmarkKey) as? [String: Data] ?? [:]
    }
}
