import Foundation
import AppKit
import SwiftUI
import SwiftMindCore
import UniformTypeIdentifiers

/// Application coordinator for multi-window mode (2026-09 design): owns the
/// document registry (one MapDocument per open map window), window opening
/// and focusing, the shared library/recents, the agent bridge, and launch
/// behavior. Per-map concerns (autosave, watching, viewport) live in
/// MapDocument.
@MainActor
final class AppModel: ObservableObject {
    let library = VaultLibrary.shared
    let agentBridge = AgentBridge()

    /// Open documents keyed by MapDocument.id (file path, or "brain").
    @Published private(set) var documents: [String: MapDocument] = [:]
    /// Document whose window is key — commands, bridge and toasts route here.
    @Published private(set) var activeDocument: MapDocument?
    /// True once bootstrap has opened the launch window — lets the launch
    /// placeholder window (nil URL) dismiss itself.
    @Published private(set) var hasOpenedLaunchWindow = false

    /// Set by the window roots so non-View code (menus, bridge, Apple Events)
    /// can open windows. Value-windows focus an existing window for the same
    /// URL instead of spawning a duplicate.
    var openWindowAction: OpenWindowAction?

    private var didBootstrap = false
    private let isUITesting = ProcessInfo.processInfo.arguments.contains("-uitesting")

    init() {
        // Settings media size applies live to every open session.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.documents.values.forEach { $0.session.applyMediaSize() } }
        }
        // Quit: flush every open document's debounced autosave.
        NotificationCenter.default.addObserver(
            forName: .swiftMindSaveAllDocuments,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.persistAllDocuments() }
        }
        // Dock click with all windows closed: reopen the launch-behavior map.
        NotificationCenter.default.addObserver(
            forName: .swiftMindReopenRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reopenFromDock() }
        }
    }

    /// Dock icon clicked while no window is open: fall back to the launch
    /// behavior (last map, or a fresh default-library map).
    func reopenFromDock() {
        guard documents.isEmpty else { return }
        openLastMapOrDefault()
    }

    // MARK: - Compatibility surface (bridge, commands)

    var session: DocumentSession? { activeDocument?.session }
    var currentMapURL: URL? { activeDocument?.url }
    var isBrainMode: Bool { activeDocument?.isBrain ?? false }

    // MARK: - Launch

    /// Call once from a window root's onAppear: open per launch behavior
    /// (Welcome map by default).
    func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true
        library.ensureDefaultLibraryVault()

        // UI tests opt into a disposable scratch map so keystroke-driven
        // tests never touch the user's last-opened document.
        if ProcessInfo.processInfo.arguments.contains("-uitesting-scratch-map") {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("uitesting.swiftmind.html")
            try? FileManager.default.removeItem(at: url)
            do {
                // Same root title as a fresh map — tests assert on "Central Idea".
                try VaultLibrary.createEmptyMapIfNeeded(at: url, title: "Central Idea")
                openMap(at: url, recordAsLast: false)
            } catch {
                showBrain()
            }
            agentBridge.start(appModel: self)
            return
        }

        switch LaunchBehavior.current {
        case .help:
            openHelpMap(fresh: isUITesting)
        case .brain:
            showBrain()
        case .last:
            openLastMapOrDefault()
        }

        agentBridge.start(appModel: self)
    }

    /// Open the bundled Welcome map (help + live demo) in the default library.
    /// `fresh: true` (Help menu) reinstalls the bundled copy first.
    func openHelpMap(fresh: Bool = false) {
        let installed = fresh ? HelpMapInstaller.reinstall() : HelpMapInstaller.installIfNeeded()
        guard let url = installed, FileManager.default.fileExists(atPath: url.path) else {
            openLastMapOrDefault()
            return
        }
        openMap(at: url)
    }

    /// Prefer last map when valid; else create/open default library map.
    private func openLastMapOrDefault() {
        if let last = library.lastMapURL,
           FileManager.default.fileExists(atPath: last.path),
           VaultLibrary.isMindMapFile(last) {
            openMap(at: last, recordAsLast: true)
        } else {
            do {
                let url = try VaultLibrary.createEmptyMapIfNeeded(
                    at: VaultLibrary.defaultNewMapURL,
                    title: "Untitled"
                )
                openMap(at: url, recordAsLast: true)
            } catch {
                showBrain()
            }
        }
    }

    // MARK: - Window management

    /// Open (or focus) the window for a map file. Freeplane `.mm` files are
    /// imported to a sibling `.swiftmind.html` first.
    func openMap(at rawURL: URL, recordAsLast: Bool = true) {
        var url = rawURL
        // Freeplane/FreeMind import: one-way, saved as a sibling .swiftmind.html.
        if url.pathExtension.lowercased() == "mm" {
            do {
                url = try importFreeplane(at: url)
            } catch {
                toast("Could not import map: \(error.localizedDescription)", kind: .error)
                return
            }
        }

        if let existing = documents[documentID(for: url)] {
            setActiveDocument(existing)
            openWindowAction?(value: url)
            return
        }

        let document: MapDocument
        do {
            document = try MapDocument(fileURL: url)
        } catch {
            library.removeRecentMap(url)
            // Drop it as "last map" too — otherwise every launch retries the
            // doomed open (and autosave keeps toasting permission errors).
            if library.lastMapURL == url {
                library.lastMapURL = nil
            }
            toast("Could not open map: \(error.localizedDescription)", kind: .error)
            // Fall back to brain if open fails and nothing else is open.
            if documents.isEmpty { showBrain() }
            return
        }
        register(document)
        if recordAsLast {
            library.lastMapURL = url
            library.lastMode = .map
            library.recordRecentMap(url)
        }
        openWindowAction?(value: url)
    }

    /// One My Brain window for the whole app.
    func showBrain() {
        if let brain = documents["brain"] {
            setActiveDocument(brain)
        } else {
            let brain = MapDocument(brain: library)
            brain.onBrainStructureChanged = { [weak brain] in
                brain?.refreshBrain()
            }
            register(brain)
            library.lastMode = .brain
        }
        openWindowAction?(id: "brain")
    }

    /// The window root resolved its URL (restored window, or creation raced
    /// the registry): materialize the document if it is missing.
    @discardableResult
    func resolveDocument(for url: URL) -> MapDocument? {
        if let existing = documents[documentID(for: url)] {
            return existing
        }
        do {
            let document = try MapDocument(fileURL: url)
            register(document)
            library.recordRecentMap(url)
            return document
        } catch {
            toast("Could not open map: \(error.localizedDescription)", kind: .error)
            return nil
        }
    }

    /// The brain window root asking for its document.
    func resolveBrainDocument() -> MapDocument {
        if let brain = documents["brain"] { return brain }
        let brain = MapDocument(brain: library)
        brain.onBrainStructureChanged = { [weak brain] in
            brain?.refreshBrain()
        }
        register(brain)
        return brain
    }

    private func register(_ document: MapDocument) {
        documents[document.id] = document
        setActiveDocument(document)
        hasOpenedLaunchWindow = true
    }

    private func documentID(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    func setActiveDocument(_ document: MapDocument?) {
        activeDocument = document
    }

    /// A window closed: flush and unregister its document.
    func documentWindowClosed(_ document: MapDocument) {
        document.close()
        documents[document.id] = nil
        if activeDocument === document {
            activeDocument = documents.values.first
        }
    }

    /// Flush every open document (quit / memory pressure).
    func persistAllDocuments() {
        documents.values.forEach { $0.persistNow() }
    }

    /// Toast routed to the active session (menus, bridge).
    private func toast(_ text: String, kind: StatusToast.Kind) {
        activeDocument?.session.showToast(text, kind: kind)
    }

    private func importFreeplane(at url: URL) throws -> URL {
        let html = try String(contentsOf: url, encoding: .utf8)
        let imported = try MMImport.importMap(from: html)
        let dir = url.deletingPathExtension().deletingLastPathComponent()
        let dest = VaultLibrary.uniqueMapURL(
            in: dir,
            baseName: url.deletingPathExtension().lastPathComponent
        )
        try Data(HTMLCodec.encode(imported, includeSkin: true).utf8).write(to: dest)
        toast("Imported \(url.lastPathComponent) → \(dest.lastPathComponent)", kind: .success)
        return dest
    }

    // MARK: - Create maps

    func createAndOpenMap(in directory: URL? = nil) {
        let dir = directory ?? VaultLibrary.defaultLibraryDirectory
        _ = library.startAccessing(dir)
        let url = VaultLibrary.uniqueMapURL(in: dir, baseName: "Untitled")
        do {
            try VaultLibrary.createEmptyMapIfNeeded(at: url, title: "Untitled")
            openMap(at: url)
        } catch {
            toast("Could not create map: \(error.localizedDescription)", kind: .error)
        }
    }

    /// Bridge path: create a map in the default library with a title; returns
    /// the new file's URL. Used by AgentBridge's `new` method.
    /// The file is always named `Untitled N.swiftmind.html`; the title lives
    /// inside the map, not in the file name.
    func createAndOpenMap(titled title: String) -> URL? {
        let dir = VaultLibrary.defaultLibraryDirectory
        _ = library.startAccessing(dir)
        let url = VaultLibrary.uniqueMapURL(in: dir, baseName: "Untitled")
        do {
            try VaultLibrary.createEmptyMapIfNeeded(at: url, title: title)
            openMap(at: url)
            return url
        } catch {
            toast("Could not create map: \(error.localizedDescription)", kind: .error)
            return nil
        }
    }

    /// New map in the selected brain folder/vault, or default library.
    func createMapNearSelection() {
        if let brain = documents["brain"],
           brain === activeDocument,
           let id = brain.session.store.selection.primary,
           let node = brain.session.store.map.node(id: id),
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
                    // Rebuild the brain window if one is open.
                    self.documents["brain"]?.refreshBrain()
                    self.showBrain()
                    self.toast("Vault added: \(url.lastPathComponent)", kind: .success)
                } else {
                    self.toast("Could not add vault", kind: .error)
                }
            }
        }
    }

    // MARK: - Save

    func saveCurrentMap() {
        activeDocument?.save()
    }

    // MARK: - Navigation from brain nodes

    func activateSelection() {
        guard let document = activeDocument, document.isBrain,
              let id = document.session.store.selection.primary,
              let node = document.session.store.map.node(id: id) else { return }
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
                activeDocument?.session.applyQuiet(SetFoldedCommand(nodeID: node.id, isFolded: next))
                activeDocument?.refreshBrain()
            }
        case .brain:
            break
        }
    }

    /// Intercept fold toggles in brain mode so fold state persists by path.
    func toggleFoldSelection() {
        guard let document = activeDocument,
              let id = document.session.store.selection.primary,
              let node = document.session.store.map.node(id: id) else { return }
        if document.isBrain {
            if let path = BrainMapBuilder.path(of: node),
               BrainMapBuilder.kind(of: node) == .folder
               || BrainMapBuilder.kind(of: node) == .vault {
                let next = !node.isFolded
                library.setFolded(path: path, folded: next)
                document.refreshBrain()
                return
            }
            return
        }
        document.session.apply(SetFoldedCommand(nodeID: id, isFolded: !node.isFolded))
    }

    // MARK: - Capture

    /// Append a thought to `Inbox.swiftmind.html` in the default library without
    /// switching windows. If Inbox is open somewhere, the edit goes to that
    /// document (its autosave persists it).
    func captureToInbox(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let dir = VaultLibrary.defaultLibraryDirectory
        _ = library.startAccessing(dir)
        let url = dir.appendingPathComponent("Inbox.swiftmind.html")
        let inboxID = documentID(for: url)
        if let inbox = documents[inboxID] {
            inbox.session.apply(
                InsertChildCommand(parentID: inbox.session.store.map.root.id, text: trimmed, side: .auto)
            )
            toast("Captured to Inbox", kind: .success)
            return
        }
        do {
            _ = try VaultLibrary.createEmptyMapIfNeeded(at: url, title: "Inbox")
            let html = try String(contentsOf: url, encoding: .utf8)
            var map = try HTMLCodec.decode(html)
            if map.root.text == "Central Idea" {
                map.root.text = "Inbox"
            }
            _ = try BatchOps.apply([
                .addChild(parentID: map.root.id, newNodeID: .generate(), text: trimmed, side: .auto)
            ], to: &map)
            try Data(HTMLCodec.encode(map, includeSkin: true).utf8).write(to: url, options: .atomic)
            // An open window for Inbox would now be stale — nudge it to reload.
            toast("Captured to Inbox", kind: .success)
        } catch {
            toast("Capture failed: \(error.localizedDescription)", kind: .error)
        }
    }

    func promptCapture() {
        let alert = NSAlert()
        alert.messageText = "Capture"
        alert.informativeText = "Adds a child to Inbox in your library. Open maps stay untouched."
        let field = NSTextField(string: "")
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        field.placeholderString = "A thought…"
        alert.accessoryView = field
        alert.addButton(withTitle: "Capture")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            captureToInbox(text: field.stringValue)
        }
    }
}
