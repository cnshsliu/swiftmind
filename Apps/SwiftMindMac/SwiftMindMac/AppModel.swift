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
    /// The launch document adopted in place by the nil-URL launch window
    /// (bootstrap fills it; no second window is opened for the launch map).
    /// Cleared once a value window takes the document over.
    @Published private(set) var launchDocument: MapDocument?
    /// True once bootstrap resolved its launch surface — lets a launch
    /// placeholder dismiss itself when the surface is NOT an adopted map
    /// (i.e. the brain window opened instead).
    @Published private(set) var hasOpenedLaunchWindow = false

    /// Set by the window roots so non-View code (menus, bridge, Apple Events)
    /// can open windows. Value-windows focus an existing window for the same
    /// URL instead of spawning a duplicate.
    var openWindowAction: OpenWindowAction?

    /// My Brain copy/move sheet. Nil when the sheet is closed.
    @Published var mapTransfer: MapTransferRequest?

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

    /// Call once from a window root's onAppear: resolve the launch surface.
    /// Map launches are ADOPTED by the nil-URL launch window (no second
    /// window); only the brain launch opens its own window.
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
                adoptLaunchMap(at: url, recordAsLast: false)
            } catch {
                showBrain()
            }
            agentBridge.start(appModel: self)
            return
        }

        switch LaunchBehavior.current {
        case .help:
            let installed = isUITesting
                ? HelpMapInstaller.reinstall()
                : HelpMapInstaller.installIfNeeded()
            if let url = installed, FileManager.default.fileExists(atPath: url.path) {
                adoptLaunchMap(at: url)
            } else {
                openLastMapOrDefault()
            }
        case .brain:
            showBrain()
        case .last:
            openLastMapOrDefault()
        }

        agentBridge.start(appModel: self)
    }

    /// Launch path: make `url` the launch window's document (no window opened).
    private func adoptLaunchMap(at url: URL, recordAsLast: Bool = true) {
        do {
            let document = try MapDocument(fileURL: url)
            documents[document.id] = document
            launchDocument = document
            setActiveDocument(document)
            hasOpenedLaunchWindow = true
            if recordAsLast {
                library.lastMapURL = url
                library.lastMode = .map
                library.recordRecentMap(url)
            }
        } catch {
            if library.lastMapURL == url { library.lastMapURL = nil }
            library.removeRecentMap(url)
            activeDocument?.session.showToast(
                "Could not open map: \(error.localizedDescription)", kind: .error
            )
            if documents.isEmpty { showBrain() }
        }
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
    /// Launch-only: the result is adopted by the launch window.
    private func openLastMapOrDefault() {
        if let last = library.lastMapURL,
           FileManager.default.fileExists(atPath: last.path),
           VaultLibrary.isMindMapFile(last) {
            adoptLaunchMap(at: last, recordAsLast: true)
        } else {
            do {
                let url = try VaultLibrary.createEmptyMapIfNeeded(
                    at: VaultLibrary.defaultNewMapURL,
                    title: "Untitled"
                )
                adoptLaunchMap(at: url, recordAsLast: true)
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
            // The launch-adopted map is already on screen in its window.
            if existing !== launchDocument {
                openWindowAction?(value: url)
            }
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
            connectBrain(brain)
            setActiveDocument(brain)
        } else {
            let brain = MapDocument(brain: library)
            connectBrain(brain)
            register(brain)
            library.lastMode = .brain
        }
        openWindowAction?(id: "brain")
    }

    /// Double-click and Return in My Brain open a map or fold a folder.
    /// The canvas calls `session.activatePrimary()`; without this hook that
    /// call does nothing.
    private func connectBrain(_ brain: MapDocument) {
        brain.onBrainStructureChanged = { [weak brain] in
            brain?.refreshBrain()
        }
        brain.session.onPrimaryActivate = { [weak self, weak brain] in
            guard let self, let brain,
                  let id = brain.session.store.selection.primary,
                  let node = brain.session.store.map.node(id: id) else { return }
            self.activate(node: node)
        }
    }

    /// The window root resolved its URL (restored window, or creation raced
    /// the registry): materialize the document if it is missing. A value
    /// window taking over the launch-adopted document ends the adoption.
    @discardableResult
    func resolveDocument(for url: URL) -> MapDocument? {
        let id = documentID(for: url)
        if let existing = documents[id] {
            if existing === launchDocument { launchDocument = nil }
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
        if let brain = documents["brain"] {
            connectBrain(brain)
            return brain
        }
        let brain = MapDocument(brain: library)
        connectBrain(brain)
        register(brain)
        return brain
    }

    private func register(_ document: MapDocument) {
        documents[document.id] = document
        setActiveDocument(document)
        hasOpenedLaunchWindow = true
    }

    private func fileStem(of url: URL) -> String {
        var name = url.lastPathComponent
        let suffix = ".swiftmind.html"
        if name.lowercased().hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }
        return name
    }

    private func documentID(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    func setActiveDocument(_ document: MapDocument?) {
        activeDocument = document
        // Key-down monitors (installed per window) gate on this so only the
        // key window's canvas eats keys in multi-window mode.
        SketchEventGuard.activeSession = document?.session
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

    /// Copy or move `source` into `directory` under `baseName`, pictures included.
    /// A move of an open map saves and drops that window's document first.
    func transferMap(from source: URL, to directory: URL, baseName: String, move: Bool) {
        for vault in library.vaultURLs {
            _ = library.startAccessing(vault)
        }
        let sourceID = documentID(for: source)
        if let document = documents[sourceID] {
            document.persistNow()
            // CLOSE BEFORE THE FILES MOVE. MapDocument.close() persists to
            // the OLD url — called after the move it resurrects the source
            // html (Lucas's half-moved state: B.html + B.assets in place,
            // A.html back from the dead, A.assets gone forever). Closing
            // first means nothing is left alive that can write A back.
            document.close()
            documents[sourceID] = nil
            if activeDocument === document {
                activeDocument = documents.values.first
            }
        }
        do {
            let destination = try MindMapBundle.transfer(
                mapURL: source, to: directory, baseName: baseName, move: move
            )
            if move { library.removeRecentMap(source) }
            if library.lastMapURL?.standardizedFileURL == source.standardizedFileURL, move {
                library.lastMapURL = destination
            }
            library.recordRecentMap(destination)
            documents["brain"]?.refreshBrain()
            mapTransfer = nil
            let verb = move ? "Moved" : "Copied"
            toast("\(verb) to \(destination.deletingLastPathComponent().lastPathComponent)/\(destination.lastPathComponent)", kind: .success)
            let stem = fileStem(of: destination)
            // A move must NOT auto-open the destination map — move 完就完了
            // (Lucas). The title still follows the new file stem; fixed in
            // the file itself for moves AND copies alike.
            if var map = try? HTMLCodec.decode(String(contentsOf: destination, encoding: .utf8)),
                      map.title != stem {
                map.title = stem
                if let html = try? HTMLCodec.encode(map, includeSkin: true) {
                    try? Data(html.utf8).write(to: destination, options: .atomic)
                }
            }
        } catch {
            let verb = move ? "move" : "copy"
            toast("Could not \(verb) the map: \(error.localizedDescription)", kind: .error)
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

    /// Drop a folder from My Brain. The directory and its maps stay on disk.
    func detachVault(_ url: URL) {
        library.removeVault(url: url)
        documents["brain"]?.refreshBrain()
        toast("Removed from My Brain. The folder is still on disk.", kind: .info)
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

    /// The sidebar map name is the file name. Renames the html file and the
    /// assets folder beside it, and keeps this window pointed at the new path.
    func renameMapFile(for document: MapDocument, to baseName: String) {
        guard let oldURL = document.url else { return }
        let oldID = documentID(for: oldURL)
        do {
            guard let destination = try document.renameFile(to: baseName) else { return }
            documents[oldID] = nil
            documents[documentID(for: destination)] = document
            library.removeRecentMap(oldURL)
            library.recordRecentMap(destination)
            if library.lastMapURL?.standardizedFileURL == oldURL.standardizedFileURL {
                library.lastMapURL = destination
            }
            documents["brain"]?.refreshBrain()
            NotificationCenter.default.post(
                name: .swiftMindMapFileRenamed,
                object: nil,
                userInfo: ["old": oldURL.path, "new": destination.path]
            )
            toast("Renamed file to \(destination.lastPathComponent)", kind: .success)
        } catch {
            toast("Could not rename the file: \(error.localizedDescription)", kind: .error)
        }
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
