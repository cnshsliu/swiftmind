import CryptoKit
import Foundation
import SwiftMindCore

/// Installs the bundled "Welcome to SwiftMind" help/demo map into the default
/// library (`~/Documents/SwiftMind`). The bundled copy is regenerated from
/// `Resources/help-map.ops.json` via `scripts/make-help-map.sh`.
@MainActor
enum HelpMapInstaller {
    static let fileName = "Welcome to SwiftMind.swiftmind.html"

    private static let hashKey = "swiftmind.helpMapHash"

    static var installedURL: URL {
        VaultLibrary.defaultLibraryDirectory.appendingPathComponent(fileName)
    }

    /// Install when missing; refresh when the app ships a newer version and
    /// the user has not edited their copy (tracked by the hash we installed).
    /// Browsing state (fold, expanded note cards) is stripped before hashing,
    /// so poking the demo does not block future updates — only real content
    /// edits (text, structure, notes) do.
    @discardableResult
    static func installIfNeeded() -> URL? {
        install(force: false)
    }

    /// Overwrite with the bundled copy (Help menu: "reinstalls a fresh copy").
    @discardableResult
    static func reinstall() -> URL? {
        install(force: true)
    }

    private static func install(force: Bool) -> URL? {
        guard let bundled = Bundle.main.url(
            forResource: "Welcome to SwiftMind.swiftmind",
            withExtension: "html"
        ), let bundledData = try? Data(contentsOf: bundled) else { return nil }

        let dest = installedURL
        let fm = FileManager.default
        try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)

        let bundledHash = digest(bundledData)
        let defaults = UserDefaults.standard

        if let existing = try? Data(contentsOf: dest) {
            if digest(existing) == bundledHash {
                defaults.set(bundledHash, forKey: hashKey)
                return dest
            }
            let untouched = defaults.string(forKey: hashKey) == digest(existing)
            guard force || untouched else { return dest }
        }

        do {
            try bundledData.write(to: dest, options: .atomic)
            defaults.set(bundledHash, forKey: hashKey)
            return dest
        } catch {
            return nil
        }
    }

    /// Stable across launches (unlike `Data.hashValue`), so yesterday's
    /// installed copy is still recognized after an app update.
    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: normalized(data)).map { String(format: "%02x", $0) }.joined()
    }

    /// Decode → clear volatile browsing state → re-encode, so fold/expand
    /// flips don't change the hash. Falls back to raw bytes if the data does
    /// not decode as a SwiftMind map.
    private static func normalized(_ data: Data) -> Data {
        guard let html = String(data: data, encoding: .utf8),
              var map = try? HTMLCodec.decode(html) else { return data }
        clearBrowsingState(&map.root)
        guard let htmlOut = try? HTMLCodec.encode(map, includeSkin: true) else { return data }
        return Data(htmlOut.utf8)
    }

    private static func clearBrowsingState(_ node: inout Node) {
        node.isFolded = false
        node.isNoteExpanded = false
        for index in node.children.indices {
            clearBrowsingState(&node.children[index])
        }
    }
}
