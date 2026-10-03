import Foundation

/// A `.swiftmind.html` file and the `.swiftmind.assets` folder beside it.
public enum MindMapBundle {
    public enum Failure: Error, Equatable {
        case emptyName
        case unsafeName
        case destinationInsideAssets
        case assetsDestinationExists
        case sourceMissing
        case destinationNotWritable
    }

    public struct Child: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case folder, map }
        public var url: URL
        public var kind: Kind
    }

    public static func isMapFile(_ url: URL) -> Bool {
        url.lastPathComponent.lowercased().hasSuffix(".swiftmind.html")
    }

    public static func isAssetsDirectory(_ url: URL) -> Bool {
        url.lastPathComponent.hasSuffix(NoteAssets.folderSuffix)
    }

    public static func assetsURL(for mapURL: URL) -> URL {
        let folder = NoteAssets.folderName(forDocumentFileName: mapURL.lastPathComponent)
        return mapURL.deletingLastPathComponent().appendingPathComponent(folder, isDirectory: true)
    }

    public static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// One directory level. Skips hidden files, asset folders, and anything
    /// that is not a mind map. Does not recurse.
    public static func children(of directory: URL) -> [Child] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var result: [Child] = []
        for item in contents.sorted(by: {
            $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
        }) {
            if isAssetsDirectory(item) { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: item.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                result.append(Child(url: item, kind: .folder))
            } else if isMapFile(item) {
                result.append(Child(url: item, kind: .map))
            }
        }
        return result
    }

    /// Vault roots plus nested folders. A symlink that points at an ancestor
    /// is listed once and not walked again. Depth is capped.
    public static func destinationFolders(
        vaults: [URL],
        maxDepth: Int = 16
    ) -> [(title: String, url: URL)] {
        var result: [(title: String, url: URL)] = []
        var seen = Set<String>()
        for vault in vaults {
            let name = vault.lastPathComponent
            result.append((name, vault))
            walkFolders(of: vault, prefix: name, depth: 0, maxDepth: maxDepth, seen: &seen, into: &result)
        }
        return result
    }

    public static func sanitizedBaseName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasSuffix(".swiftmind.html") {
            name = String(name.dropLast(".swiftmind.html".count))
        }
        name = name.replacingOccurrences(of: "/", with: "-")
        name = name.replacingOccurrences(of: ":", with: "-")
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Copy or move the html file and its assets folder. A failed assets
    /// step puts the html back where it was.
    public static func transfer(
        mapURL: URL,
        to directory: URL,
        baseName: String,
        move: Bool
    ) throws -> URL {
        let name = sanitizedBaseName(baseName)
        if name.isEmpty { throw Failure.emptyName }
        if name == "." || name == ".." { throw Failure.unsafeName }
        let destinationDir = directory.standardizedFileURL
        let assetsRoot = assetsURL(for: mapURL).standardizedFileURL.path
        let destPath = destinationDir.path
        if destPath == assetsRoot || destPath.hasPrefix(assetsRoot + "/") {
            throw Failure.destinationInsideAssets
        }
        let destination = uniqueMapURL(in: destinationDir, baseName: name, excluding: move ? mapURL : nil)
        if canonicalPath(destination) == canonicalPath(mapURL) {
            return mapURL
        }
        let fm = FileManager.default
        // Preflight BEFORE touching anything — atomicity means the failure
        // window is as small as possible and every half-step rolls back.
        guard fm.fileExists(atPath: mapURL.path) else { throw Failure.sourceMissing }
        guard fm.isWritableFile(atPath: destinationDir.path) else { throw Failure.destinationNotWritable }
        try fm.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        let sourceAssets = assetsURL(for: mapURL)
        let destinationAssets = assetsURL(for: destination)
        if fm.fileExists(atPath: destinationAssets.path) {
            throw Failure.assetsDestinationExists
        }
        var htmlMoved = false
        var assetsMoved = false
        do {
            if move {
                try fm.moveItem(at: mapURL, to: destination)
            } else {
                try fm.copyItem(at: mapURL, to: destination)
            }
            htmlMoved = true
            if fm.fileExists(atPath: sourceAssets.path) {
                if move {
                    try fm.moveItem(at: sourceAssets, to: destinationAssets)
                } else {
                    try fm.copyItem(at: sourceAssets, to: destinationAssets)
                }
                assetsMoved = true
            }
        } catch {
            // Roll back in REVERSE order — either side of the pair may have
            // made it before the failure; the map must never end up with
            // the html in one place and the assets in another.
            if assetsMoved {
                if move {
                    try? fm.moveItem(at: destinationAssets, to: sourceAssets)
                } else {
                    try? fm.removeItem(at: destinationAssets)
                }
            }
            if htmlMoved {
                if move {
                    try? fm.moveItem(at: destination, to: mapURL)
                } else {
                    try? fm.removeItem(at: destination)
                }
            }
            throw error
        }
        return destination
    }

    public static func uniqueMapURL(in directory: URL, baseName: String, excluding: URL?) -> URL {
        let fm = FileManager.default
        let excluded = excluding.map(canonicalPath)
        func candidate(_ suffix: String) -> URL {
            directory.appendingPathComponent("\(baseName)\(suffix).swiftmind.html")
        }
        var url = candidate("")
        var n = 2
        while fm.fileExists(atPath: url.path), canonicalPath(url) != excluded {
            url = candidate(" \(n)")
            n += 1
            if n > 1000 { break }
        }
        return url
    }

    private static func walkFolders(
        of directory: URL,
        prefix: String,
        depth: Int,
        maxDepth: Int,
        seen: inout Set<String>,
        into result: inout [(title: String, url: URL)]
    ) {
        let canonical = canonicalPath(directory)
        guard seen.insert(canonical).inserted else { return }
        guard depth < maxDepth else { return }
        for child in children(of: directory) where child.kind == .folder {
            let title = prefix + " / " + child.url.lastPathComponent
            result.append((title, child.url))
            walkFolders(
                of: child.url, prefix: title, depth: depth + 1, maxDepth: maxDepth,
                seen: &seen, into: &result
            )
        }
    }
}
