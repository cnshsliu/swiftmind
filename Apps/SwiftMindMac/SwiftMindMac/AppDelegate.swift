import AppKit

/// Filters bogus document paths injected by the debugger / CLI defaults.
/// Xcode's "Debug Document Versions" passes `-NSDocumentRevisionsDebugMode YES`,
/// and DocumentGroup may try to open a file literally named "YES".
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let ignoredDocumentNames: Set<String> = [
        "YES", "NO", "yes", "no", "true", "false", "TRUE", "FALSE",
    ]

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let name = (filename as NSString).lastPathComponent
        if Self.ignoredDocumentNames.contains(name) {
            return true // swallow — do not show "could not be opened"
        }
        return false // let SwiftUI DocumentGroup handle real files
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let real = urls.filter { url in
            !Self.ignoredDocumentNames.contains(url.lastPathComponent)
        }
        // DocumentGroup will still receive open events via the system for real files;
        // for ignored names we simply no-op here when we own the open.
        for url in real {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
        }
    }
}
