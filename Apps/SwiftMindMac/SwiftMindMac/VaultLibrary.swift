import Foundation
import SwiftMindCore

/// User-managed mindmap vault roots + last-opened map, persisted in UserDefaults.
/// Vault access uses security-scoped bookmarks when available.
@MainActor
final class VaultLibrary: ObservableObject {
    static let shared = VaultLibrary()

    private enum Keys {
        static let vaultBookmarks = "swiftmind.vaultBookmarks"
        static let lastMapPath = "swiftmind.lastMapPath"
        static let lastMode = "swiftmind.lastMode" // "brain" | "map"
        static let foldState = "swiftmind.brainFoldState"
        static let recentMapPaths = "swiftmind.recentMapPaths"
    }

    private static let maxRecentMaps = 10

    enum AppMode: String {
        case brain
        case map
    }

    @Published private(set) var vaultURLs: [URL] = []
    /// Most-recent-first list of opened map files (max 10).
    @Published private(set) var recentMapURLs: [URL] = []

    private var bookmarkDataByPath: [String: Data] = [:]
    private var foldState: [String: Bool] = [:]

    /// Default library directory: `~/Documents/SwiftMind`
    static var defaultLibraryDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/SwiftMind", isDirectory: true)
    }

    static var defaultNewMapURL: URL {
        defaultLibraryDirectory.appendingPathComponent("Untitled.swiftmind.html", isDirectory: false)
    }

    private init() {
        load()
    }

    // MARK: - Persistence

    private func load() {
        let defaults = UserDefaults.standard
        if let dict = defaults.dictionary(forKey: Keys.foldState) as? [String: Bool] {
            foldState = dict
        }
        if let paths = defaults.array(forKey: Keys.recentMapPaths) as? [String] {
            recentMapURLs = paths.map { URL(fileURLWithPath: $0) }
        }
        guard let bookmarks = defaults.array(forKey: Keys.vaultBookmarks) as? [Data] else {
            vaultURLs = []
            return
        }
        var urls: [URL] = []
        var byPath: [String: Data] = [:]
        for data in bookmarks {
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else { continue }
            let path = url.path
            byPath[path] = data
            if !urls.contains(where: { $0.path == path }) {
                urls.append(url)
            }
        }
        bookmarkDataByPath = byPath
        vaultURLs = urls
    }

    private func saveBookmarks() {
        let ordered = vaultURLs.compactMap { bookmarkDataByPath[$0.path] }
        UserDefaults.standard.set(ordered, forKey: Keys.vaultBookmarks)
    }

    private func saveFoldState() {
        UserDefaults.standard.set(foldState, forKey: Keys.foldState)
    }

    // MARK: - Last opened

    var lastMapURL: URL? {
        get {
            guard let path = UserDefaults.standard.string(forKey: Keys.lastMapPath), !path.isEmpty else {
                return nil
            }
            return URL(fileURLWithPath: path)
        }
        set {
            UserDefaults.standard.set(newValue?.path, forKey: Keys.lastMapPath)
        }
    }

    var lastMode: AppMode {
        get {
            AppMode(rawValue: UserDefaults.standard.string(forKey: Keys.lastMode) ?? "") ?? .map
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Keys.lastMode)
        }
    }

    // MARK: - Recent maps (File → Open Recent)

    /// Record a successfully opened map at the front of the recent list.
    func recordRecentMap(_ url: URL) {
        let path = url.standardizedFileURL.path
        var paths = recentMapURLs.map(\.path).filter { $0 != path }
        paths.insert(path, at: 0)
        if paths.count > Self.maxRecentMaps {
            paths = Array(paths.prefix(Self.maxRecentMaps))
        }
        recentMapURLs = paths.map { URL(fileURLWithPath: $0) }
        UserDefaults.standard.set(paths, forKey: Keys.recentMapPaths)
    }

    /// Drop one entry (e.g. file vanished or failed to open).
    func removeRecentMap(_ url: URL) {
        let path = url.standardizedFileURL.path
        let paths = recentMapURLs.map(\.path).filter { $0 != path }
        guard paths.count != recentMapURLs.count else { return }
        recentMapURLs = paths.map { URL(fileURLWithPath: $0) }
        UserDefaults.standard.set(paths, forKey: Keys.recentMapPaths)
    }

    func clearRecentMaps() {
        recentMapURLs = []
        UserDefaults.standard.set([String](), forKey: Keys.recentMapPaths)
    }

    // MARK: - Vaults

    @discardableResult
    func addVault(url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDir),
              isDir.boolValue else {
            return false
        }

        do {
            let data = try standardized.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            bookmarkDataByPath[standardized.path] = data
        } catch {
            // Still register path (e.g. Documents exception path without bookmark).
        }
        if !vaultURLs.contains(where: { $0.path == standardized.path }) {
            vaultURLs.append(standardized)
        }
        saveBookmarks()
        return true
    }

    func removeVault(url: URL) {
        vaultURLs.removeAll { $0.path == url.path }
        bookmarkDataByPath.removeValue(forKey: url.path)
        saveBookmarks()
    }

    /// Ensure default library exists and is registered as a vault.
    func ensureDefaultLibraryVault() {
        let dir = Self.defaultLibraryDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !vaultURLs.contains(where: { $0.path == dir.path }) {
            addVault(url: dir)
        }
    }

    // MARK: - Security scope

    @discardableResult
    func startAccessing(_ url: URL) -> Bool {
        if let data = bookmarkDataByPath[url.path] {
            var isStale = false
            if let resolved = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                return resolved.startAccessingSecurityScopedResource()
            }
        }
        return url.startAccessingSecurityScopedResource()
    }

    func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }

    /// Start access for a map file via its vault root if known.
    @discardableResult
    func startAccessingForMap(_ mapURL: URL) -> URL? {
        let path = mapURL.standardizedFileURL.path
        for vault in vaultURLs where path.hasPrefix(vault.path) {
            _ = startAccessing(vault)
            return vault
        }
        _ = mapURL.startAccessingSecurityScopedResource()
        return nil
    }

    // MARK: - Fold state (brain navigator)

    func isFolded(path: String) -> Bool {
        foldState[path] ?? false
    }

    func setFolded(path: String, folded: Bool) {
        foldState[path] = folded
        saveFoldState()
    }

    // MARK: - File helpers

    static func isMindMapFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".swiftmind.html") { return true }
        let ext = url.pathExtension.lowercased()
        return ext == "html" || ext == "htm"
    }

    /// Create a new empty map file at `url` if missing; returns the URL.
    @discardableResult
    static func createEmptyMapIfNeeded(at url: URL, title: String = "Untitled") throws -> URL {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            let map = MindMap.makeEmpty(title: title)
            let html = try HTMLCodec.encode(map, includeSkin: true)
            try Data(html.utf8).write(to: url, options: .atomic)
        }
        return url
    }

    /// Unique path in directory: `base.swiftmind.html`, `base 2.swiftmind.html`, …
    static func uniqueMapURL(in directory: URL, baseName: String = "Untitled") -> URL {
        let fm = FileManager.default
        var candidate = directory.appendingPathComponent("\(baseName).swiftmind.html")
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName) \(n).swiftmind.html")
            n += 1
        }
        return candidate
    }
}
