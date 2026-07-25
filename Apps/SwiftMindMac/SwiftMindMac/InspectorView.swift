import SwiftUI
import SwiftMindCore
import AppKit

/// Trailing inspector for the selected node's text, note, links, icons, and style.
struct InspectorView: View {
    @ObservedObject var session: DocumentSession

    @State private var titleDraft: String = ""
    @State private var noteDraft: String = ""
    @State private var urlDraft: String = ""
    @State private var fontSize: Double = 14
    @State private var isBold: Bool = false
    @State private var textColor: Color = .primary
    @State private var fillColor: Color = .clear
    @State private var hasFill: Bool = false
    /// Tracks which node the local drafts currently mirror (avoids fighting live edits).
    @State private var boundNodeID: NodeID?
    /// Suppresses command dispatch while drafts are loaded from the model.
    @State private var isSyncing = false

    private var primaryID: NodeID? {
        session.store.selection.primary
    }

    private var primaryNode: Node? {
        guard let primaryID else { return nil }
        return session.store.map.node(id: primaryID)
    }

    var body: some View {
        Form {
            if let node = primaryNode {
                Section("Node") {
                    TextField("Title", text: $titleDraft)
                        .onSubmit { commitTitle(for: node.id) }

                    Button("Apply Title") {
                        commitTitle(for: node.id)
                    }
                    .disabled(titleDraft == node.text)
                }

                Section("Note") {
                    TextEditor(text: $noteDraft)
                        .font(.body)
                        .frame(minHeight: 100)

                    Button("Apply Note") {
                        commitNote(for: node.id)
                    }
                    .disabled(noteDraft == node.noteMarkdown)

                    if !noteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       let attr = try? AttributedString(
                        markdown: noteDraft,
                        options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                       ) {
                        Text(attr)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    }
                }

                Section("Links") {
                    if node.links.isEmpty {
                        Text("No links")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(node.links.enumerated()), id: \.offset) { index, link in
                            HStack {
                                Text(linkDescription(link))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Button(role: .destructive) {
                                    removeLink(at: index, node: node)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .help("Remove link")
                            }
                        }
                    }

                    TextField("https://…", text: $urlDraft)
                        .onSubmit { addURL(to: node) }

                    Button("Add URL") {
                        addURL(to: node)
                    }
                    .disabled(urlDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Menu("Link to Node") {
                        let others = flatten(session.store.map.root).filter { $0.id != node.id }
                        if others.isEmpty {
                            Text("No other nodes")
                        } else {
                            ForEach(others, id: \.id) { other in
                                Button(other.text.isEmpty ? "(untitled)" : other.text) {
                                    addNodeLink(to: node, otherID: other.id)
                                }
                            }
                        }
                    }
                }

                Section("Icons") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 28))], spacing: 8) {
                        ForEach(SwiftMindCore.IconRef.catalog) { icon in
                            let on = node.icons.contains(icon)
                            Button {
                                toggleIcon(icon, on: node)
                            } label: {
                                Image(systemName: SwiftMindCore.IconRef.sfSymbolNames[icon.id] ?? "questionmark")
                                    .font(.title3)
                                    .symbolVariant(on ? .fill : .none)
                                    .foregroundStyle(on ? Color.accentColor : Color.secondary)
                                    .frame(width: 28, height: 28)
                            }
                            .buttonStyle(.plain)
                            .help(icon.id)
                        }
                    }
                }

                Section("Style") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Font Size")
                            Spacer()
                            Text("\(Int(fontSize.rounded()))")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(
                            value: $fontSize,
                            in: 10...28,
                            step: 1,
                            onEditingChanged: { editing in
                                if !editing {
                                    commitStyle(for: node.id)
                                }
                            }
                        ) {
                            Text("Font Size")
                        }
                    }

                    Toggle("Bold", isOn: $isBold)
                        .onChange(of: isBold) { _, _ in
                            commitStyleIfUser(for: node.id)
                        }

                    ColorPicker("Text Color", selection: $textColor, supportsOpacity: false)
                        .onChange(of: textColor) { _, _ in
                            commitStyleIfUser(for: node.id)
                        }

                    Toggle("Fill Color", isOn: $hasFill)
                        .onChange(of: hasFill) { _, _ in
                            commitStyleIfUser(for: node.id)
                        }

                    if hasFill {
                        ColorPicker("Fill", selection: $fillColor, supportsOpacity: false)
                            .onChange(of: fillColor) { _, _ in
                                commitStyleIfUser(for: node.id)
                            }
                    }
                }
            } else {
                ContentUnavailableView(
                    "No Selection",
                    systemImage: "sidebar.trailing",
                    description: Text("Select a node to edit its title, note, links, icons, and style.")
                )
            }
        }
        .formStyle(.grouped)
        .padding(.top, 4)
        .onChange(of: session.revision) { _, _ in
            syncFromSelection(force: false)
        }
        .onAppear {
            syncFromSelection(force: true)
        }
    }

    // MARK: - Sync

    /// Pull model → drafts when selection changes or after external edits.
    private func syncFromSelection(force: Bool) {
        guard let node = primaryNode else {
            boundNodeID = nil
            return
        }
        // Refresh drafts when primary changes or forced; keep in-progress typing otherwise.
        if force || boundNodeID != node.id {
            boundNodeID = node.id
            isSyncing = true
            titleDraft = node.text
            noteDraft = node.noteMarkdown
            urlDraft = ""
            applyStyleToDrafts(node.style)
            isSyncing = false
        } else if titleDraft == node.text {
            // Same node, title not dirty — still refresh style from model (e.g. undo).
            // Note draft keeps the title-style pattern: only reloaded on selection change.
            isSyncing = true
            applyStyleToDrafts(node.style)
            isSyncing = false
        }
    }

    private func applyStyleToDrafts(_ style: NodeStyle) {
        fontSize = min(28, max(10, style.fontSize))
        isBold = style.isBold
        textColor = Color(
            red: style.textRed,
            green: style.textGreen,
            blue: style.textBlue
        )
        if let r = style.fillRed, let g = style.fillGreen, let b = style.fillBlue {
            hasFill = true
            fillColor = Color(red: r, green: g, blue: b)
        } else {
            hasFill = false
            fillColor = Color(nsColor: .controlBackgroundColor)
        }
    }

    // MARK: - Commands

    private func commitTitle(for id: NodeID) {
        guard let node = session.store.map.node(id: id) else { return }
        let trimmed = titleDraft
        guard trimmed != node.text else { return }
        session.apply(SetTextCommand(nodeID: id, newText: trimmed))
    }

    private func commitNote(for id: NodeID) {
        guard let node = session.store.map.node(id: id) else { return }
        guard noteDraft != node.noteMarkdown else { return }
        session.apply(SetNoteCommand(nodeID: id, noteMarkdown: noteDraft))
    }

    private func commitStyleIfUser(for id: NodeID) {
        guard !isSyncing else { return }
        commitStyle(for: id)
    }

    private func commitStyle(for id: NodeID) {
        guard !isSyncing else { return }
        guard let node = session.store.map.node(id: id) else { return }
        let next = styleFromDrafts()
        guard next != node.style else { return }
        session.apply(SetStyleCommand(nodeID: id, style: next))
    }

    private func styleFromDrafts() -> NodeStyle {
        let textRGB = rgbComponents(of: textColor)
        var style = NodeStyle(
            fontSize: fontSize,
            isBold: isBold,
            textRed: textRGB.r,
            textGreen: textRGB.g,
            textBlue: textRGB.b
        )
        if hasFill {
            let fillRGB = rgbComponents(of: fillColor)
            style.fillRed = fillRGB.r
            style.fillGreen = fillRGB.g
            style.fillBlue = fillRGB.b
        }
        return style
    }

    private func rgbComponents(of color: Color) -> (r: Double, g: Double, b: Double) {
        let ns = NSColor(color)
        guard let rgb = ns.usingColorSpace(.sRGB) else {
            return (0, 0, 0)
        }
        return (
            Double(rgb.redComponent),
            Double(rgb.greenComponent),
            Double(rgb.blueComponent)
        )
    }

    // MARK: - Links

    private func linkDescription(_ link: NodeLink) -> String {
        switch link {
        case .url(let url):
            return url.absoluteString
        case .node(let id):
            if let n = session.store.map.node(id: id) {
                let title = n.text.isEmpty ? "(untitled)" : n.text
                return "→ \(title)"
            }
            return "→ \(id.rawValue)"
        }
    }

    private func removeLink(at index: Int, node: Node) {
        var links = node.links
        guard links.indices.contains(index) else { return }
        links.remove(at: index)
        session.apply(SetLinksCommand(nodeID: node.id, links: links))
    }

    private func addURL(to node: Node) {
        let raw = urlDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        var s = raw
        if !s.contains("://") {
            s = "https://" + s
        }
        guard let url = URL(string: s), url.scheme != nil, url.host != nil else { return }
        var links = node.links
        links.append(.url(url))
        session.apply(SetLinksCommand(nodeID: node.id, links: links))
        urlDraft = ""
    }

    private func addNodeLink(to node: Node, otherID: NodeID) {
        // Avoid duplicate node links.
        if node.links.contains(.node(otherID)) { return }
        var links = node.links
        links.append(.node(otherID))
        session.apply(SetLinksCommand(nodeID: node.id, links: links))
    }

    // MARK: - Icons

    private func toggleIcon(_ icon: SwiftMindCore.IconRef, on node: Node) {
        var icons = node.icons
        if let idx = icons.firstIndex(of: icon) {
            icons.remove(at: idx)
        } else {
            icons.append(icon)
        }
        session.apply(SetIconsCommand(nodeID: node.id, icons: icons))
    }

    // MARK: - Helpers

    private func flatten(_ node: Node) -> [Node] {
        [node] + node.children.flatMap { flatten($0) }
    }
}
