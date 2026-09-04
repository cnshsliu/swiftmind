import Foundation
import AppKit
import SwiftUI
import SwiftMindCore

/// Copy/cut/paste/drop brain for the map. All mutations are one
/// `CompositeAgentCommand` (single undo step) dispatched through the
/// session; new nodes are then selected explicitly (composites do not
/// auto-select).
///
/// The private `app.swiftmind.node` pasteboard flavor carries full node
/// subtrees (JSON `[Node]`). It is a transient IPC channel only — the HTML
/// codec remains the single persistence path.
@MainActor
enum ClipboardService {
    static let maxCreatedNodes = 200

    /// Private node-subtree pasteboard flavor.
    static let nodeType = NSPasteboard.PasteboardType("app.swiftmind.node")

    // MARK: - Copy / Cut

    /// Copy the selection's topmost non-root nodes (a node whose ancestor is
    /// also selected is skipped — its subtree comes along via the ancestor).
    static func copySelection(from session: DocumentSession) {
        if let textview = firstResponderTextView {
            textview.copy(nil)
            return
        }
        let nodes = selectedTopmostNodes(in: session)
        guard !nodes.isEmpty else { return }
        write(nodes: nodes)
    }

    static func cutSelection(from session: DocumentSession) {
        if let textview = firstResponderTextView {
            textview.cut(nil)
            return
        }
        let nodes = selectedTopmostNodes(in: session)
        guard !nodes.isEmpty else { return }
        write(nodes: nodes)
        session.apply(DeleteNodesCommand(nodeIDs: nodes.map(\.id)))
    }

    private static func write(nodes: [Node]) {
        let board = NSPasteboard.general
        board.clearContents()
        if let json = try? JSONEncoder().encode(nodes) {
            board.setData(json, forType: Self.nodeType)
        }
        board.setString(MarkdownOutline.export(nodes), forType: .string)
        board.setString(htmlOutline(nodes), forType: .html)
    }

    private static func htmlOutline(_ nodes: [Node]) -> String {
        func li(_ node: Node) -> String {
            var s = "<li>" + escapeHTML(node.text)
            if !node.noteMarkdown.isEmpty {
                s += "\n<p>" + escapeHTML(node.noteMarkdown) + "</p>"
            }
            if !node.children.isEmpty {
                s += "\n<ul>\n" + node.children.map(li).joined(separator: "\n") + "\n</ul>"
            }
            return s + "</li>"
        }
        return "<ul>\n" + nodes.map(li).joined(separator: "\n") + "\n</ul>"
    }

    private static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static var firstResponderTextView: NSTextView? {
        NSApp.keyWindow?.firstResponder as? NSTextView
    }

    private static func selectedTopmostNodes(in session: DocumentSession) -> [Node] {
        let map = session.store.map
        let rootID = map.root.id
        let selected = Set(session.store.selection.selectedIDs.filter { $0 != rootID })
        guard !selected.isEmpty else { return [] }
        // DFS with the ancestor chain: a node is topmost when no strict
        // ancestor is also selected.
        var result: [Node] = []
        func visit(_ node: Node, chain: [NodeID]) {
            if selected.contains(node.id), !chain.contains(where: selected.contains) {
                result.append(node)
            }
            for child in node.children {
                visit(child, chain: chain + [node.id])
            }
        }
        visit(map.root, chain: [])
        return result
    }

    // MARK: - Paste

    static func paste(into session: DocumentSession) {
        if let textview = firstResponderTextView {
            textview.paste(nil)
            return
        }
        guard !session.isBrainMode else { return }
        let board = NSPasteboard.general

        // 1. Private node flavor.
        if let data = board.data(forType: Self.nodeType),
           let nodes = try? JSONDecoder().decode([Node].self, from: data), !nodes.isEmpty {
            applyNodes(nodes, into: session, toast: "Pasted nodes · ⌘Z to undo")
            return
        }

        // 2. URLs (file or web).
        if let urls = board.readObjects(forClasses: [NSURL.self]) as? [URL], let url = urls.first {
            ingest(url: url, into: session)
            return
        }

        // 3. Image data.
        if let data = imageData(from: board) {
            ingestImageData(data, into: session)
            return
        }

        // 4. HTML → plain text.
        if let html = board.string(forType: .html), !html.isEmpty {
            let text = htmlToPlainText(html)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ingestText(text, into: session)
                return
            }
        }

        // 5. Plain text / markdown.
        if let text = board.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ingestText(text, into: session)
        }
    }

    private static func ingest(url: URL, into session: DocumentSession) {
        if isImageFile(url), let data = try? Data(contentsOf: url) {
            ingestImageData(data, into: session)
            return
        }
        if url.isFileURL {
            // Follow-up: graft imported .mm/.swiftmind.html maps as subtrees.
            let title = url.lastPathComponent
            let (ops, id) = buildAddOps(
                parent: targetID(in: session),
                title: title,
                noteMarkdown: url.path,
                links: [.url(url)]
            )
            apply(ops, into: session, select: id, toast: "Added file link · ⌘Z to undo")
        } else {
            let title = urlLabel(url)
            let (ops, id) = buildAddOps(
                parent: targetID(in: session),
                title: title,
                noteMarkdown: "",
                links: [.url(url)]
            )
            apply(ops, into: session, select: id, toast: "Added link · ⌘Z to undo")
        }
    }

    static func ingestImageData(_ data: Data, into session: DocumentSession, at point: Point2D? = nil) {
        guard let png = normalizeImage(data) else {
            session.showToast("Couldn't read that image", kind: .error)
            return
        }
        let uri = "![pasted](data:image/png;base64,\(png.base64EncodedString()))"
        if point == nil, let node = session.store.map.node(id: targetNode(in: session)) {
            // Append into the existing note (the note editor reconciles via
            // its contentRevision watcher).
            let note = node.noteMarkdown
            let merged = note.isEmpty ? uri : note.trimmingCharacters(in: .newlines) + "\n\n" + uri
            apply([.setNote(nodeID: node.id, markdown: merged)], into: session,
                  select: nil, toast: "Pasted image into note · ⌘Z to undo")
        } else {
            let id = NodeID.generate()
            var ops: [MapOp] = [
                .addChild(parentID: targetID(in: session), newNodeID: id, text: "Pasted image", side: .auto),
                .setNote(nodeID: id, markdown: uri),
            ]
            if let point {
                ops.append(.setPin(nodeID: id, position: point))
            }
            apply(ops, into: session, select: id, toast: "Pasted image · ⌘Z to undo")
        }
    }

    private static func ingestText(_ text: String, into session: DocumentSession) {
        if let nodes = MarkdownOutline.parse(text), !nodes.isEmpty {
            applyNodes(nodes, into: session, toast: "Pasted outline · ⌘Z to undo")
            return
        }
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return }
        if lines.count > maxCreatedNodes {
            session.showToast("Pasted text truncated to \(maxCreatedNodes) nodes", kind: .error, duration: 3.2)
        }
        let capped = Array(lines.prefix(maxCreatedNodes))
        let parent = targetID(in: session)
        var firstNew: NodeID?
        let ops: [MapOp] = capped.map { line in
            let id = NodeID.generate()
            if firstNew == nil { firstNew = id }
            return .addChild(parentID: parent, newNodeID: id, text: String(line.prefix(200)), side: .auto)
        }
        apply(ops, into: session, select: firstNew,
              toast: "Pasted \(capped.count) node\(capped.count == 1 ? "" : "s") · ⌘Z to undo")
    }

    // MARK: - Shared application

    private static func targetID(in session: DocumentSession) -> NodeID {
        session.store.selection.primary ?? session.store.map.root.id
    }

    private static func targetNode(in session: DocumentSession) -> NodeID {
        targetID(in: session)
    }

    /// Paste full node subtrees as children of the target (fresh ids so
    /// pasting into the same map never collides).
    static func applyNodes(
        _ nodes: [Node], into session: DocumentSession, toast: String
    ) {
        let parent = targetID(in: session)
        var ops: [MapOp] = []
        var firstNew: NodeID?
        func emit(_ node: Node, parentID: NodeID) {
            let id = NodeID.generate()
            if firstNew == nil { firstNew = id }
            ops.append(.addChild(parentID: parentID, newNodeID: id, text: node.text, side: .auto))
            if !node.noteMarkdown.isEmpty {
                ops.append(.setNote(nodeID: id, markdown: node.noteMarkdown))
            }
            if !node.links.isEmpty {
                ops.append(.setLinks(nodeID: id, links: node.links))
            }
            for child in node.children {
                emit(child, parentID: id)
            }
        }
        for node in nodes {
            emit(node, parentID: parent)
        }
        apply(ops, into: session, select: firstNew, toast: toast)
    }

    /// Returns the add ops plus the new node's id (for selection/pinning).
    private static func buildAddOps(
        parent: NodeID, title: String, noteMarkdown: String, links: [NodeLink]
    ) -> (ops: [MapOp], id: NodeID) {
        let id = NodeID.generate()
        var ops: [MapOp] = [.addChild(parentID: parent, newNodeID: id, text: title, side: .auto)]
        if !noteMarkdown.isEmpty {
            ops.append(.setNote(nodeID: id, markdown: noteMarkdown))
        }
        if !links.isEmpty {
            ops.append(.setLinks(nodeID: id, links: links))
        }
        return (ops, id)
    }

    static func apply(
        _ ops: [MapOp], into session: DocumentSession,
        select: NodeID? = nil, toast: String? = nil
    ) {
        guard !ops.isEmpty, !session.isBrainMode else { return }
        session.applyQuiet(CompositeAgentCommand(ops: ops))
        if let select {
            session.select(select)
        }
        if let toast {
            session.showToast(toast, kind: .success)
        }
    }

    // MARK: - Payload helpers

    private static func isImageFile(_ url: URL) -> Bool {
        let exts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "tiff", "heic", "bmp"]
        guard let ext = url.pathExtension.lowercased() as String? else { return false }
        return exts.contains(ext)
    }

    private static func imageData(from board: NSPasteboard) -> Data? {
        if let tiff = board.data(forType: .tiff) { return tiff }
        if let png = board.data(forType: .png) { return png }
        return nil
    }

    /// Downscale to ≤720pt longest side and re-encode as PNG.
    static func normalizeImage(_ data: Data) -> Data? {
        guard let image = NSImage(data: data) else { return nil }
        let maxSide: CGFloat = 720
        var size = image.size
        if size.width > 0, size.height > 0,
           max(size.width, size.height) > maxSide {
            let scale = maxSide / max(size.width, size.height)
            size = NSSize(width: size.width * scale, height: size.height * scale)
        }
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: max(1, Int(size.width)),
            pixelsHigh: max(1, Int(size.height)),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(
            in: NSRect(origin: .zero, size: size),
            from: .zero,
            operation: .copy,
            fraction: 1.0,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        NSGraphicsContext.current = nil
        NSGraphicsContext.restoreGraphicsState()
        guard let out = rep.representation(using: .png, properties: [:]) else { return nil }
        guard out.count < 10 * 1024 * 1024 else { return nil }
        return out
    }

    private static func urlLabel(_ url: URL) -> String {
        guard let scheme = url.scheme?.lowercased(), scheme.hasPrefix("http") else {
            return String(url.absoluteString.prefix(60))
        }
        var label = url.host ?? url.absoluteString
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !path.isEmpty {
            label += "/" + path
        }
        return String(label.prefix(60))
    }

    private static func htmlToPlainText(_ html: String) -> String {
        guard html.utf8.count < 2 * 1024 * 1024,
              let attr = try? NSAttributedString(
                html: Data(html.utf8),
                options: [.characterEncoding: String.Encoding.utf8.rawValue],
                documentAttributes: nil
              )
        else { return "" }
        return attr.string
    }
}
