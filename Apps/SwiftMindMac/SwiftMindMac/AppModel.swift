import Foundation
import AppKit
import SwiftUI
import SwiftMindCore
import UniformTypeIdentifiers

/// Application shell: startup open (last / new), My Brain vault navigator, map editing + autosave.
@MainActor
final class AppModel: ObservableObject {
    let library = VaultLibrary.shared

    @Published private(set) var mode: VaultLibrary.AppMode = .map
    @Published private(set) var currentMapURL: URL?
    @Published private(set) var isBrainMode: Bool = false
    /// Session for the active surface (brain navigator or map editor).
    @Published private(set) var session: DocumentSession

    private var accessRoot: URL?
    private var saveTask: Task<Void, Never>?
    private let fileWatcher = MapFileWatcher()
    private var reloadTask: Task<Void, Never>?
    /// Hash of the file content we last read or wrote — watcher events whose
    /// content matches are our own saves and are ignored.
    private var lastKnownFileHash: Int?
    private var suppressAutosave = false
    private var didBootstrap = false

    init() {
        // Placeholder until bootstrap; replaced immediately.
        session = DocumentSession(map: .makeEmpty(title: "Untitled"))
    }

    // MARK: - Launch

    /// Call once from the root view: open last map, or create default in ~/Documents/SwiftMind.
    func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true
        library.ensureDefaultLibraryVault()

        // Prefer last map when valid; else create/open default library map.
        if let last = library.lastMapURL,
           FileManager.default.fileExists(atPath: last.path),
           VaultLibrary.isMindMapFile(last) {
            openMap(at: last, recordAsLast: true)
            return
        }

        do {
            let url = try VaultLibrary.createEmptyMapIfNeeded(
                at: VaultLibrary.defaultNewMapURL,
                title: "Untitled"
            )
            openMap(at: url, recordAsLast: true)
        } catch {
            // Last resort: in-memory untitled (still no open panel).
            suppressAutosave = true
            isBrainMode = false
            mode = .map
            currentMapURL = nil
            session = DocumentSession(map: .makeEmpty(title: "Untitled"))
            wireSession()
            suppressAutosave = false
        }
    }

    // MARK: - My Brain

    func showBrain() {
        persistCurrentMapIfNeeded()
        stopWatching()
        suppressAutosave = true
        isBrainMode = true
        mode = .brain
        library.lastMode = .brain
        let map = BrainMapBuilder.build(library: library)
        session = DocumentSession(map: map)
        session.isBrainMode = true
        wireSession()
        suppressAutosave = false
    }

    func refreshBrain() {
        guard isBrainMode else { return }
        let selected = session.store.selection.primary
        suppressAutosave = true
        let map = BrainMapBuilder.build(library: library)
        session.syncFromDocument(map)
        if let selected, session.store.map.node(id: selected) != nil {
            session.select(selected)
        }
        suppressAutosave = false
    }

    // MARK: - Open / create maps

    func openMap(at url: URL, recordAsLast: Bool = true) {
        persistCurrentMapIfNeeded()
        releaseAccess()

        accessRoot = library.startAccessingForMap(url)

        do {
            let data = try Data(contentsOf: url)
            guard let html = String(data: data, encoding: .utf8) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            // Freeplane/FreeMind import: one-way, saved as a sibling .swiftmind.html.
            if url.pathExtension.lowercased() == "mm" {
                let imported = try MMImport.importMap(from: html)
                let dir = url.deletingLastPathComponent()
                let dest = VaultLibrary.uniqueMapURL(
                    in: dir,
                    baseName: url.deletingPathExtension().lastPathComponent
                )
                try Data(HTMLCodec.encode(imported, includeSkin: true).utf8).write(to: dest)
                openMap(at: dest)
                session.showToast(
                    "Imported \(url.lastPathComponent) → \(dest.lastPathComponent)",
                    kind: .success
                )
                return
            }
            let map = try HTMLCodec.decode(html)
            suppressAutosave = true
            isBrainMode = false
            mode = .map
            currentMapURL = url
            if recordAsLast {
                library.lastMapURL = url
                library.lastMode = .map
                library.recordRecentMap(url)
            }
            session = DocumentSession(map: map)
            session.isBrainMode = false
            wireSession()
            lastKnownFileHash = data.hashValue
            startWatching(url: url)
            suppressAutosave = false
        } catch {
            library.removeRecentMap(url)
            session.showToast("Could not open map: \(error.localizedDescription)", kind: .error)
            // Fall back to brain if open fails.
            showBrain()
        }
    }

    func createAndOpenMap(in directory: URL? = nil) {
        let dir = directory ?? VaultLibrary.defaultLibraryDirectory
        _ = library.startAccessing(dir)
        let url = VaultLibrary.uniqueMapURL(in: dir, baseName: "Untitled")
        do {
            try VaultLibrary.createEmptyMapIfNeeded(at: url, title: "Untitled")
            openMap(at: url)
        } catch {
            session.showToast("Could not create map: \(error.localizedDescription)", kind: .error)
        }
    }

    /// New map in the selected brain folder/vault, or default library.
    func createMapNearSelection() {
        if isBrainMode,
           let id = session.store.selection.primary,
           let node = session.store.map.node(id: id),
           let path = BrainMapBuilder.path(of: node) {
            var dir = URL(fileURLWithPath: path)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue {
                dir = dir.deletingLastPathComponent()
            }
            createAndOpenMap(in: dir)
            return
        }
        createAndOpenMap(in: VaultLibrary.defaultLibraryDirectory)
    }

    func openMapPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "html") ?? .html,
            UTType(filenameExtension: "htm") ?? .html,
            UTType(filenameExtension: "mm") ?? .xml,
        ]
        panel.message = "Open a SwiftMind map (or import a Freeplane .mm)"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                self?.openMap(at: url)
            }
        }
    }

    func addVaultPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder to use as a mindmap vault"
        panel.prompt = "Add Vault"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard let self else { return }
                if self.library.addVault(url: url) {
                    if self.isBrainMode {
                        self.refreshBrain()
                    } else {
                        self.showBrain()
                    }
                    self.session.showToast("Vault added: \(url.lastPathComponent)", kind: .success)
                } else {
                    self.session.showToast("Could not add vault", kind: .error)
                }
            }
        }
    }

    func saveCurrentMap() {
        guard !isBrainMode, let url = currentMapURL else { return }
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
            session.showToast("Save failed: \(error.localizedDescription)", kind: .error)
        }
    }

    // MARK: - Navigation from brain nodes

    func activateSelection() {
        guard isBrainMode,
              let id = session.store.selection.primary,
              let node = session.store.map.node(id: id) else { return }
        activate(node: node)
    }

    func activate(node: Node) {
        guard let kind = BrainMapBuilder.kind(of: node) else { return }
        switch kind {
        case .map:
            if let path = BrainMapBuilder.path(of: node) {
                openMap(at: URL(fileURLWithPath: path))
            }
        case .folder, .vault:
            if let path = BrainMapBuilder.path(of: node) {
                let next = !library.isFolded(path: path)
                library.setFolded(path: path, folded: next)
                // Mirror into store then rebuild so layout matches disk fold.
                session.applyQuiet(SetFoldedCommand(nodeID: node.id, isFolded: next))
                refreshBrain()
            }
        case .brain:
            break
        }
    }

    /// Intercept fold toggles in brain mode so fold state persists by path.
    func toggleFoldSelection() {
        guard let id = session.store.selection.primary,
              let node = session.store.map.node(id: id) else { return }
        if isBrainMode {
            if let path = BrainMapBuilder.path(of: node),
               BrainMapBuilder.kind(of: node) == .folder
                || BrainMapBuilder.kind(of: node) == .vault {
                let next = !node.isFolded
                library.setFolded(path: path, folded: next)
                refreshBrain()
                return
            }
            return
        }
        session.apply(SetFoldedCommand(nodeID: id, isFolded: !node.isFolded))
    }

    // MARK: - Session wiring

    private func wireSession() {
        session.onPrimaryActivate = { [weak self] in
            self?.activateSelection()
        }
        session.onContentChanged = { [weak self] in
            self?.scheduleAutosave()
        }
    }

    private func scheduleAutosave() {
        guard !suppressAutosave, !isBrainMode, currentMapURL != nil else { return }
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self.saveCurrentMap()
        }
    }

    private func persistCurrentMapIfNeeded() {
        saveTask?.cancel()
        if !isBrainMode, currentMapURL != nil {
            saveCurrentMap()
        }
    }

    private func releaseAccess() {
        if let accessRoot {
            library.stopAccessing(accessRoot)
            self.accessRoot = nil
        }
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

    private func reloadIfExternallyChanged() {
        guard !isBrainMode, let url = currentMapURL else { return }
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
}
