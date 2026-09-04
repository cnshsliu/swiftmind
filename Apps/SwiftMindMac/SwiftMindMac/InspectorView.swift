import SwiftUI
import SwiftMindCore
import AppKit

/// Trailing inspector for the selected node's text, note, links, icons, and style.
struct InspectorView: View {
    @ObservedObject var session: DocumentSession

    @State private var titleDraft: String = ""
    @State private var urlDraft: String = ""
    @State private var fontSize: Double = 14
    @State private var isBold: Bool = false
    @State private var textColor: Color = .primary
    @State private var fillColor: Color = .clear
    @State private var hasFill: Bool = false
    /// Tracks which node the local drafts currently mirror (avoids fighting live edits).
    @State private var boundNodeID: NodeID?
    /// Last model values we pushed into drafts; if draft still equals these, it is not dirty.
    @State private var lastSyncedTitle: String = ""
    /// Suppresses command dispatch while drafts are loaded from the model.
    @State private var isSyncing = false
    @FocusState private var titleFocused: Bool

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
                        .font(.body.weight(.medium))
                        .focused($titleFocused)
                        .onSubmit { commitTitle(for: node.id) }
                        .onChange(of: titleFocused) { _, focused in
                            if !focused { commitTitle(for: node.id) }
                        }
                    Text("Saves on Return or when you leave the field")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Section("Note") {
                    let bodyMarkdown: String = {
                        if let live = session.liveNoteDocument, live.nodeID == node.id {
                            return NoteDocument.split(live.document).body
                        }
                        return node.noteMarkdown
                    }()
                    if !bodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        MarkdownTextView(markdown: bodyMarkdown, fontSize: 13, maxImageHeight: 320)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("notePreview")
                    } else {
                        Text("No note — select the node on the canvas and press E to edit")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
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
                        ForEach(NodeIcon.catalog) { icon in
                            let on = node.icons.contains(icon)
                            Button {
                                toggleIcon(icon, on: node)
                            } label: {
                                Image(systemName: NodeIcon.sfSymbolNames[icon.id] ?? "questionmark")
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

                Section("Attributes") {
                    AttributeInspectorSection(session: session, node: node)
                }

                Section("Formula") {
                    FormulaInspectorSection(session: session, node: node)
                }

                Section("Named Style") {
                    Picker("Style", selection: Binding(
                        get: { node.styleName ?? "" },
                        set: { newValue in
                            let name: String? = newValue.isEmpty ? nil : newValue
                            guard name != node.styleName else { return }
                            session.applyQuiet(SetStyleNameCommand(nodeID: node.id, styleName: name))
                        }
                    )) {
                        Text("None").tag("")
                        ForEach(namedStyleKeys, id: \.self) { key in
                            Text(key.capitalized).tag(key)
                        }
                    }
                    .accessibilityIdentifier("namedStylePicker")
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

            Section("Style Rules") {
                StyleRulesSection(session: session)
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

    /// Pull model → drafts when selection changes or after external edits
    /// (canvas rename, outline, undo). Keep dirty inspector drafts until Apply.
    private func syncFromSelection(force: Bool) {
        guard let node = primaryNode else {
            boundNodeID = nil
            lastSyncedTitle = ""
            return
        }

        let selectionChanged = boundNodeID != node.id
        isSyncing = true
        defer { isSyncing = false }

        if force || selectionChanged {
            boundNodeID = node.id
            titleDraft = node.text
            lastSyncedTitle = node.text
            urlDraft = ""
            applyStyleToDrafts(node.style)
            return
        }

        // Same node: refresh non-dirty fields so canvas/outline renames show up.
        if titleDraft == lastSyncedTitle {
            titleDraft = node.text
            lastSyncedTitle = node.text
        }
        applyStyleToDrafts(node.style)
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
        session.applyQuiet(SetTextCommand(nodeID: id, newText: trimmed))
        lastSyncedTitle = trimmed
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
        session.applyQuiet(SetStyleCommand(nodeID: id, style: next))
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

    private func toggleIcon(_ icon: NodeIcon, on node: Node) {
        var icons = node.icons
        if let idx = icons.firstIndex(of: icon) {
            icons.remove(at: idx)
        } else {
            icons.append(icon)
        }
        session.apply(SetIconsCommand(nodeID: node.id, icons: icons))
    }

    // MARK: - Helpers

    private var namedStyleKeys: [String] {
        session.store.map.styleSheet.styles.keys.sorted()
    }

    private func flatten(_ node: Node) -> [Node] {
        [node] + node.children.flatMap { flatten($0) }
    }
}

// MARK: - Formula

/// L1 formula editor: monospaced field, live result, inline #ERR, clear button.
/// Commits via SetFormulaCommand on Return / focus loss (never per keystroke).
struct FormulaInspectorSection: View {
    @ObservedObject var session: DocumentSession
    let node: Node

    @State private var draft: String = ""
    /// Which node the draft currently mirrors (avoids fighting live edits).
    @State private var boundNodeID: NodeID?
    @FocusState private var fieldFocused: Bool

    /// Live result of the *stored* formula (memoized in the store's engine).
    private var result: FormulaValue? {
        session.store.formulaValue(for: node.id)
    }

    var body: some View {
        Group {
            TextField("e.g. sum(children, attr: \"cost\")", text: $draft)
                .font(.body.monospaced())
                .focused($fieldFocused)
                .onSubmit { commit() }
                .onChange(of: fieldFocused) { _, focused in
                    if !focused { commit() }
                }
                .accessibilityIdentifier("formulaField")

            // L0: one-click aggregates write the corresponding L1 formula.
            Menu("Insert Aggregate") {
                let attrNames = session.store.map.attributeRegistry.definitions.map(\.name)
                Menu("Sum of Attribute") {
                    if attrNames.isEmpty {
                        Text("No attributes in registry")
                    } else {
                        ForEach(attrNames, id: \.self) { name in
                            Button(name) { applyAggregate("sum(children, attr: \"\(name)\")") }
                        }
                    }
                }
                .disabled(attrNames.isEmpty)
                Button("Count Children") { applyAggregate("count(children)") }
                Button("Progress %") { applyAggregate("progress()") }
            }
            .font(.caption)
            .accessibilityIdentifier("aggregatePicker")

            if let result {
                HStack {
                    Text("Result")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(result.displayText)
                        .font(.caption.monospaced().weight(.medium))
                        .foregroundStyle(isError(result) ? Color.red : Color.primary)
                        .lineLimit(2)
                        .accessibilityIdentifier("formulaResult")
                }
            } else {
                Text("No formula — computed values never modify the map")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if node.formula != nil {
                Button("Clear Formula", role: .destructive) {
                    draft = ""
                    session.applyQuiet(SetFormulaCommand(nodeID: node.id, formula: nil))
                }
                .accessibilityIdentifier("clearFormulaButton")
            }
        }
        .onAppear { syncDraft() }
        .onChange(of: node.id) { _, _ in syncDraft() }
        .onChange(of: node.formula) { _, newFormula in
            // External change (undo, palette): refresh only if the user isn't editing.
            if !fieldFocused, draft != (newFormula ?? "") {
                draft = newFormula ?? ""
            }
        }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let next: String? = trimmed.isEmpty ? nil : trimmed
        guard next != node.formula else { return }
        session.applyQuiet(SetFormulaCommand(nodeID: node.id, formula: next))
    }

    /// L0 picker action: replaces the formula and commits immediately.
    private func applyAggregate(_ formula: String) {
        draft = formula
        session.apply(SetFormulaCommand(nodeID: node.id, formula: formula))
    }

    private func isError(_ value: FormulaValue) -> Bool {
        if case .error = value { return true }
        return false
    }

    private func syncDraft() {
        guard boundNodeID != node.id else { return }
        boundNodeID = node.id
        draft = node.formula ?? ""
    }
}

// MARK: - Style Rules

/// Map-level conditional style rules: "if hasIcon(check) apply note", etc.
/// Rules layer over the node's named style; local style fields still win.
struct StyleRulesSection: View {
    @ObservedObject var session: DocumentSession

    @State private var conditionKind = 0 // 0 = icon, 1 = attribute
    @State private var selectedIcon = "check"
    @State private var attrName = ""
    @State private var attrValue = ""
    @State private var selectedStyle = "note"

    private var rules: [ConditionalStyleRule] {
        session.store.map.styleSheet.rules
    }

    private var styleKeys: [String] {
        session.store.map.styleSheet.styles.keys.sorted()
    }

    var body: some View {
        if rules.isEmpty {
            Text("No rules — e.g. \"icon check → note\"")
                .foregroundStyle(.secondary)
                .font(.caption)
        } else {
            ForEach(rules) { rule in
                HStack {
                    Text(describe(rule))
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                    Button(role: .destructive) {
                        remove(rule)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }

        Picker("Condition", selection: $conditionKind) {
            Text("Has Icon").tag(0)
            Text("Attribute").tag(1)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("ruleConditionPicker")

        if conditionKind == 0 {
            Picker("Icon", selection: $selectedIcon) {
                ForEach(NodeIcon.catalog) { icon in
                    Label(icon.id, systemImage: NodeIcon.sfSymbolNames[icon.id] ?? "circle")
                        .tag(icon.id)
                }
            }
        } else {
            HStack {
                TextField("Name", text: $attrName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("ruleAttrNameField")
                TextField("Value", text: $attrValue)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("ruleAttrValueField")
            }
        }

        HStack {
            Picker("Style", selection: $selectedStyle) {
                ForEach(styleKeys, id: \.self) { key in
                    Text(key.capitalized).tag(key)
                }
            }
            .accessibilityIdentifier("ruleStylePicker")
            Button("Add Rule") { addRule() }
                .disabled(conditionKind == 1 && attrName.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("addRuleButton")
        }
    }

    private func describe(_ rule: ConditionalStyleRule) -> String {
        switch rule.condition {
        case .hasIcon(let iconID):
            return "icon \(iconID) → \(rule.styleName)"
        case .attributeEquals(let name, let value):
            return "\(name)=\(value) → \(rule.styleName)"
        }
    }

    private func addRule() {
        let condition: ConditionalStyleRule.Condition
        if conditionKind == 0 {
            condition = .hasIcon(selectedIcon)
        } else {
            condition = .attributeEquals(
                name: attrName.trimmingCharacters(in: .whitespaces),
                value: attrValue
            )
        }
        session.apply(SetStyleRulesCommand(rules: rules + [
            ConditionalStyleRule(condition: condition, styleName: selectedStyle)
        ]))
        attrName = ""
        attrValue = ""
    }

    private func remove(_ rule: ConditionalStyleRule) {
        session.apply(SetStyleRulesCommand(rules: rules.filter { $0.id != rule.id }))
    }
}

// MARK: - Attributes

/// Editable name/value rows for the selected node; auto-registers names.
struct AttributeInspectorSection: View {
    @ObservedObject var session: DocumentSession
    let node: Node

    @State private var newName: String = ""
    @State private var newValue: String = ""

    var body: some View {
        if node.attributes.isEmpty {
            Text("No attributes")
                .foregroundStyle(.secondary)
                .font(.caption)
        } else {
            ForEach(node.attributes) { attr in
                HStack {
                    Text(attr.name)
                        .font(.caption.weight(.medium))
                        .frame(width: 72, alignment: .leading)
                        .lineLimit(1)
                    TextField("Value", text: Binding(
                        get: { attr.value },
                        set: { newVal in
                            session.applyQuiet(
                                UpsertAttributeCommand(
                                    nodeID: node.id,
                                    attribute: NodeAttribute(name: attr.name, value: newVal)
                                )
                            )
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    Button(role: .destructive) {
                        removeAttribute(named: attr.name)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }

        HStack {
            TextField("Name", text: $newName)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("attrNameField")
            TextField("Value", text: $newValue)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("attrValueField")
                .onSubmit { addAttribute() }
            Button("Add") { addAttribute() }
                .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("addAttributeButton")
        }
    }

    private func addAttribute() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        session.apply(
            UpsertAttributeCommand(
                nodeID: node.id,
                attribute: NodeAttribute(name: name, value: newValue)
            )
        )
        newName = ""
        newValue = ""
    }

    private func removeAttribute(named name: String) {
        let next = node.attributes.filter { $0.name != name }
        session.apply(SetAttributesCommand(nodeID: node.id, attributes: next))
    }
}
