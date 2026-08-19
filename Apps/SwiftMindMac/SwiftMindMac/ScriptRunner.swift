import AppKit
import SwiftMindCore

/// Runs a user-picked `.js` file against the current map via the sandboxed
/// JavaScriptCore runtime. Scripts record intents; a clean run applies them as
/// ONE undoable command — failures and timeouts change nothing.
@MainActor
enum ScriptRunner {

    static func runViaOpenPanel(session: DocumentSession) {
        let panel = NSOpenPanel()
        panel.title = "Run Script"
        panel.allowedContentTypes = [.init(filenameExtension: "js")].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            run(url: url, session: session)
        }
    }

    static func run(url: URL, session: DocumentSession) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            session.showToast("Couldn't read script file", kind: .error)
            return
        }

        let context = MapScriptContext(map: session.store.map)
        let result = JavaScriptCoreRuntime().run(source: source, api: context, timeout: 2)

        if let error = result.error {
            session.showToast("Script failed: \(error)", kind: .error, duration: 4)
            return
        }

        if context.intents.isEmpty {
            let lastLog = context.logs.last.map { " · \($0)" } ?? ""
            session.showToast("Script made no changes\(lastLog)", kind: .info)
            return
        }

        let command = ApplyScriptIntentsCommand(intents: context.intents)
        session.apply(command)
        var message = "Script applied \(command.appliedCount) change(s) · ⌘Z to undo"
        if command.skippedCount > 0 {
            message += " · \(command.skippedCount) skipped (stale ids)"
        }
        session.showToast(message, kind: .success, duration: 3.5)
    }
}
