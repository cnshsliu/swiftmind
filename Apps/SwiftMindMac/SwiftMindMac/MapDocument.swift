import Foundation
import AppKit
import SwiftUI
import SwiftMindCore

/// One open map per window (multi-window mode, 2026-09 design):
/// owns the DocumentSession plus everything that used to hang off the global
/// AppModel for a single map — autosave, external-change watching, viewport
/// persistence, security-scoped access. My Brain is a document without a
/// file URL whose session shows the vault navigator.
@MainActor
final class MapDocument: ObservableObject, Identifiable {
    enum Kind: Equatable {
        case mapFile(URL)
        case brain
    }

    let kind: Kind
    var id: String { kind == .brain ? "brain" : (url?.standardizedFileURL.path ?? "") }
    var url: URL? { if case .mapFile(let u) = kind { return u } else { return nil } }
    var isBrain: Bool { kind == .brain }

    /// The editing session. Views observe this directly.
    private(set) var session: DocumentSession

    private let library = VaultLibrary.shared
    private let fileWatcher = MapFileWatcher()
    private let viewStateStore = ViewStateStore()
    private var saveTask: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?
    private var viewportTask: Task<Void, Never>?
    private var accessRoot: URL?
    /// Hash of the file content we last read or wrote — watcher events whose
    /// content matches are our own saves and are ignored.
    private var lastKnownFileHash: Int?
    private var suppressAutosave = false
    private let isUITesting = ProcessInfo.processInfo.arguments.contains("-uitesting")
    /// Fires when brain fold state changed and the navigator should rebuild.
    var onBrainStructureChanged: (() -> Void)?

    // MARK: - Creation

    /// Open a map file. Throws decode/IO errors so the caller can route to a
    /// toast and a fallback window.
    init(fileURL: URL) throws {
        kind = .mapFile(fileURL)
        let data = try Data(contentsOf: fileURL)
        guard let html = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let map = try HTMLCodec.decode(html)
        session = DocumentSession(map: map)
        if !isUITesting, let saved = viewStateStore.viewport(for: map.id) {
            session.viewport = saved
        } else {
            // Never seen this map: open with the whole map in view.
            // The canvas performs the fit once it knows its size.
            session.needsInitialFit = !isUITesting
        }
        lastKnownFileHash = data.hashValue
        accessRoot = library.startAccessingForMap(fileURL)
        wireSession()
        startWatching(url: fileURL)
    }

    /// The My Brain vault navigator session.
    init(brain library: VaultLibrary) {
        kind = .brain
        session = DocumentSession(map: BrainMapBuilder.build(library: library))
        session.isBrainMode = true
        wireSession()
    }

    private func wireSession() {
        session.onContentChanged = { [weak self] in
            self?.scheduleAutosave()
        }
        session.onViewportChanged = { [weak self] in
            self?.scheduleViewportPersist()
        }
    }

    // MARK: - Teardown (window close)

    /// Flush pending autosave + viewport, stop the watcher, release access.
    /// Safe to call more than once.
    func close() {
        persistNow()
        stopWatching()
        if let accessRoot {
            library.stopAccessing(accessRoot)
            self.accessRoot = nil
        }
    }

    func persistNow() {
        saveTask?.cancel()
        viewportTask?.cancel()
        if !isBrain, url != nil {
            persistViewport()
            save()
        }
    }

    // MARK: - Save / autosave

    func save() {
        guard !isBrain, let url else { return }
        // If the file on disk no longer matches what we last read/wrote, an
        // external process (agent CLI) changed it — reload instead of clobbering.
        if let onDisk = try? Data(contentsOf: url),
           let lastKnownFileHash, onDisk.hashValue != lastKnownFileHash {
            reloadIfExternallyChanged()
            return
        }
        do {
            let html = try HTMLCodec.encode(session.exportMap(), includeSkin: true)
            let data = Data(html.utf8)
            try data.write(to: url, options: .atomic)
            lastKnownFileHash = data.hashValue
            library.lastMapURL = url
        } catch {
            // A map we can read but not write (e.g. outside the sandbox via a
            // launch-event handoff) must not stay "last map": every launch
            // would reopen it and every autosave would toast this error.
            if (error as? CocoaError)?.code == .fileWriteNoPermission {
                if library.lastMapURL == url {
                    library.lastMapURL = nil
                }
                library.removeRecentMap(url)
            }
            session.showToast("Save failed: \(error.localizedDescription)", kind: .error)
        }
    }

    private func scheduleAutosave() {
        guard !suppressAutosave, !isBrain, url != nil else { return }
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self.save()
        }
    }

    // MARK: - Viewport persistence

    private func scheduleViewportPersist() {
        guard !isBrain, url != nil else { return }
        viewportTask?.cancel()
        viewportTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self.persistViewport()
        }
    }

    private func persistViewport() {
        guard !isBrain else { return }
        viewStateStore.save(
            mapID: session.store.map.id,
            title: session.store.map.title,
            viewport: session.viewport
        )
    }

    // MARK: - External change watching (agent CLI writes)

    private func startWatching(url: URL) {
        reloadTask?.cancel()
        reloadTask = nil
        fileWatcher.onChange = { [weak self] in
            self?.scheduleExternalReload()
        }
        fileWatcher.watch(url: url)
    }

    private func stopWatching() {
        reloadTask?.cancel()
        reloadTask = nil
        fileWatcher.stop()
        lastKnownFileHash = nil
    }

    private func scheduleExternalReload() {
        reloadTask?.cancel()
        reloadTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            self.reloadIfExternallyChanged()
        }
    }

    func reloadIfExternallyChanged() {
        guard !isBrain, let url else { return }
        guard let data = try? Data(contentsOf: url) else {
            // File missing or unreadable — keep the in-memory map; don't clobber.
            return
        }
        let hash = data.hashValue
        guard hash != lastKnownFileHash else { return }
        guard let html = String(data: data, encoding: .utf8),
              let map = try? HTMLCodec.decode(html) else {
            // External write is malformed — warn once per change, keep memory copy.
            lastKnownFileHash = hash
            session.showToast("External change could not be read — kept in-memory version", kind: .error)
            return
        }
        lastKnownFileHash = hash
        // NOTE: replaceMap clears the undo stack and multi-selection — accepted
        // tradeoff for v1 (see spec §hot reload).
        let selected = session.store.selection.primary
        suppressAutosave = true
        session.syncFromDocument(map)
        if let selected, session.store.map.node(id: selected) != nil {
            session.select(selected)
        } else {
            session.clearSelection()
        }
        suppressAutosave = false
        session.showToast("Reloaded — file changed on disk", kind: .info)
    }

    // MARK: - Brain navigator

    /// Rebuild the brain map, keeping the selection when it still exists.
    func refreshBrain() {
        guard isBrain else { return }
        let selected = session.store.selection.primary
        suppressAutosave = true
        let map = BrainMapBuilder.build(library: library)
        session.syncFromDocument(map)
        if let selected, session.store.map.node(id: selected) != nil {
            session.select(selected)
        }
        suppressAutosave = false
    }
}
