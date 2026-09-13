import Foundation
import SwiftMindCore

/// Loads/saves per-map zoom in a SwiftMind HTML preferences map
/// (Application Support, not the user's document library).
@MainActor
final class ViewStateStore {
    private var prefs: MindMap
    private let url: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SwiftMind", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("preferences.swiftmind.html")
        if let data = try? Data(contentsOf: url),
           let html = String(data: data, encoding: .utf8),
           let decoded = try? HTMLCodec.decode(html) {
            prefs = decoded
        } else {
            prefs = PreferencesMap.makeEmpty()
        }
    }

    func viewport(for mapID: String) -> CanvasViewport? {
        PreferencesMap.viewport(forMapID: mapID, in: prefs)
    }

    func save(mapID: String, title: String, viewport: CanvasViewport) {
        PreferencesMap.upsertViewport(mapID: mapID, title: title, viewport: viewport, into: &prefs)
        if let html = try? HTMLCodec.encode(prefs, includeSkin: true) {
            try? Data(html.utf8).write(to: url, options: .atomic)
        }
    }
}
