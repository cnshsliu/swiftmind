import AppKit

/// Filters bogus document paths and suppresses the cold-launch Open panel.
/// Startup open is handled by `AppModel.bootstrap()` (last map or create default).
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let ignoredDocumentNames: Set<String> = [
        "YES", "NO", "yes", "no", "true", "false", "TRUE", "FALSE",
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Document-based open panel is not used (WindowGroup shell).
        NSWindow.allowsAutomaticWindowTabbing = true
    }

    /// Never show the system “Open” panel on launch; AppModel opens last/default map.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        true // claim it so nothing else prompts
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            // All windows closed but the app is still running (Word-style
            // multi-window): Dock click reopens the last map / My Brain.
            NotificationCenter.default.post(name: .swiftMindReopenRequested, object: nil)
        }
        return true
    }

    /// Multi-window mode: closing the last window leaves the app running —
    /// File > New Map / Open / Dock click all reopen windows, which is what
    /// App Review's guideline-4 note asks for. No quit-on-last-close.

    /// Flush every open document before quitting (autosave is debounced, so
    /// a fast quit could otherwise lose the last edit).
    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.post(name: .swiftMindSaveAllDocuments, object: nil)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let name = (filename as NSString).lastPathComponent
        if Self.ignoredDocumentNames.contains(name) {
            return true // swallow — do not show "could not be opened"
        }
        let url = URL(fileURLWithPath: filename)
        NotificationCenter.default.post(name: .swiftMindOpenMapURL, object: url)
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let real = urls.filter { url in
            !Self.ignoredDocumentNames.contains(url.lastPathComponent)
        }
        for url in real {
            NotificationCenter.default.post(name: .swiftMindOpenMapURL, object: url)
        }
    }
}

extension Notification.Name {
    static let swiftMindOpenMapURL = Notification.Name("swiftmind.openMapURL")
    static let swiftMindSaveAllDocuments = Notification.Name("swiftmind.saveAllDocuments")
    static let swiftMindReopenRequested = Notification.Name("swiftmind.reopenRequested")
}
