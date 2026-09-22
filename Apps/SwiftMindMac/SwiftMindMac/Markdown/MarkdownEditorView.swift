import SwiftUI
import AppKit
import SwiftMindCore

/// One-shot insertion request from the note-editor toolbar (spec 3b). The
/// editor applies it to the text storage at the caret (flowing into the
/// binding and the text undo stack) and clears the binding.
struct MarkdownInsertion: Equatable {
    enum Payload: Equatable {
        /// Ready-made `![name](data:…)` markdown line.
        case image(markdown: String)
        case math
        case link
    }

    let id = UUID()
    let payload: Payload
}

/// Markdown source editor for node notes (spec 2026-09-21, Phase 2a/2b).
/// The text storage always holds the plain Markdown source — what you type is
/// what persists; styling is an attributes-only pass on top. Typing aids:
/// Return continues list markers (and removes empty ones), Tab/⇧Tab indent
/// list lines, ⌘B/⌘I toggle `**`/`*` around the selection. Esc is forwarded
/// to `onCancel` (the canvas maps it to the note editor's cancel path).
struct MarkdownEditorView: NSViewRepresentable {
    @Binding var text: String
    /// One-shot toolbar insertion request (3b); the editor applies it at the
    /// caret and clears the binding. Used for the image picker, which lives
    /// in the canvas so it can reuse `ClipboardService.normalizeImage`.
    @Binding var insertion: MarkdownInsertion?
    var onCancel: () -> Void
    var onInsertImage: () -> Void = {}
    /// XCUITest host id: `noteEditorPanel` or `noteEditorOnCard`.
    var chromeIdentifier: String = "noteEditorPanel"

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> MarkdownEditorHost {
        let textView = MarkdownSourceTextView(frame: .zero)
        textView.onCancel = onCancel
        textView.delegate = context.coordinator
        textView.isRichText = false // storage stays plain Markdown source
        textView.allowsUndo = true  // text-level ⌘Z (see undoFocusedTextIfPossible)
        textView.font = MarkdownStyler.baseFont
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        // XCUITest id lives on the text area: a scroll view fully covered by
        // its document view has no hit-testable region of its own.
        textView.setAccessibilityIdentifier("noteEditor")

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let coord = context.coordinator
        let toolbar = NSStackView(views: [
            Self.toolbarButton("photo", id: "noteEditorInsertImage", help: "Insert image",
                               target: coord, action: #selector(Coordinator.insertImageClicked)),
            Self.toolbarButton("function", id: "noteEditorInsertMath", help: "Insert math",
                               target: coord, action: #selector(Coordinator.insertMathClicked)),
            Self.toolbarButton("link", id: "noteEditorInsertLink", help: "Insert link",
                               target: coord, action: #selector(Coordinator.insertLinkClicked)),
        ])
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 4
        toolbar.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 8)
        toolbar.setAccessibilityIdentifier("noteEditorToolbar")
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        let host = MarkdownEditorHost()
        host.scrollView = scroll
        host.setAccessibilityElement(true)
        host.setAccessibilityRole(.group)
        host.setAccessibilityIdentifier(chromeIdentifier)
        host.addSubview(toolbar)
        host.addSubview(scroll)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: host.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: MarkdownEditorHost.toolbarHeight),
            scroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])

        coord.textView = textView
        coord.bindShortcuts(to: textView)
        coord.setText(text, of: textView)
        DispatchQueue.main.async {
            host.window?.makeFirstResponder(textView)
        }
        return host
    }

    func updateNSView(_ host: MarkdownEditorHost, context: Context) {
        guard let textView = host.scrollView.documentView as? MarkdownSourceTextView else { return }
        textView.onCancel = onCancel
        context.coordinator.bindShortcuts(to: textView)
        host.setAccessibilityIdentifier(chromeIdentifier)
        context.coordinator.parent = self
        // External reset (editor open, undo/CLI/agent reload): only push when
        // the model-side text actually diverged — never on our own keystrokes.
        context.coordinator.setText(text, of: textView)
        // Image picker (3b) lands here after NSOpenPanel; apply once.
        if let request = insertion, context.coordinator.lastAppliedInsertionID != request.id {
            context.coordinator.lastAppliedInsertionID = request.id
            textView.applyInsertion(request.payload)
            DispatchQueue.main.async { insertion = nil }
        }
    }

    private static func toolbarButton(
        _ symbol: String, id: String, help: String, target: AnyObject, action: Selector
    ) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .toolbar
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
        button.toolTip = help
        button.setAccessibilityIdentifier(id)
        button.setAccessibilityLabel(help)
        button.target = target
        button.action = action
        return button
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditorView
        weak var textView: MarkdownSourceTextView?
        private var isProgrammaticUpdate = false
        /// Last toolbar insertion already applied — `updateNSView` can fire
        /// again before the async binding clear, and must not re-insert.
        var lastAppliedInsertionID: UUID?
        /// Markdown source. The text view shows the projection, not this string.
        private var markdown = ""
        private var sourceUTF16: [Int] = []
        private var lastDisplay = ""
        private var reveal: MarkdownDisplay.Reveal = .none

        init(parent: MarkdownEditorView) {
            self.parent = parent
        }

        func bindShortcuts(to textView: MarkdownSourceTextView) {
            textView.onFormat = { [weak self] marker in self?.applyWrap(marker) }
            textView.onLink = { [weak self] in self?.applyLink() }
            textView.onHeading = { [weak self] level in self?.applyHeading(level) }
        }

        func applyWrap(_ marker: String) {
            guard let textView else { return }
            let range = sourceSelection(in: textView)
            let updated = MarkdownDisplay.wrap(markdown, rangeUTF16: range, marker: marker)
            commitMarkdown(updated, caret: range.lowerBound + (marker as NSString).length)
        }

        func applyLink() {
            guard let textView else { return }
            let range = sourceSelection(in: textView)
            let ns = markdown as NSString
            let selected = range.isEmpty
                ? "title"
                : ns.substring(with: NSRange(location: range.lowerBound, length: range.count))
            let replacement = "[\(selected)](url)"
            let updated = ns.replacingCharacters(
                in: NSRange(location: range.lowerBound, length: range.count),
                with: replacement
            )
            commitMarkdown(updated, caret: range.lowerBound + 1)
        }

        func applyHeading(_ level: Int) {
            guard let textView else { return }
            let caret = sourceOffset(at: textView.selectedRange().location)
            let updated = MarkdownDisplay.setHeading(markdown, level: level, atUTF16: caret)
            commitMarkdown(updated, caret: caret)
        }

        private func commitMarkdown(_ updated: String, caret: Int) {
            markdown = updated
            reveal = .none
            parent.text = updated
            guard let textView else { return }
            show(MarkdownDisplay.project(updated, reveal: .none), in: textView, sourceCaret: caret)
        }

        private func sourceSelection(in textView: MarkdownSourceTextView) -> Range<Int> {
            let sel = textView.selectedRange()
            let start = min(max(sourceOffset(at: sel.location), 0), (markdown as NSString).length)
            guard sel.length > 0 else { return start..<start }
            let last = sel.location + sel.length - 1
            let end = last >= 0 && last < sourceUTF16.count
                ? sourceUTF16[last] + 1
                : (markdown as NSString).length
            return start..<max(start, end)
        }

        @objc func insertImageClicked() {
            parent.onInsertImage()
        }

        @objc func insertMathClicked() {
            textView?.applyInsertion(.math)
        }

        @objc func insertLinkClicked() {
            textView?.applyInsertion(.link)
        }

        /// Push markdown into the view as its rendered projection.
        func setText(_ text: String, of textView: MarkdownSourceTextView) {
            guard text != markdown else { return }
            markdown = text
            reveal = .none
            let display = MarkdownDisplay.project(text, reveal: .none)
            show(display, in: textView, sourceCaret: display.sourceUTF16.last.map { $0 + 1 })
        }

        func textDidChange(_ notification: Notification) {
            guard !isProgrammaticUpdate,
                  let textView = notification.object as? MarkdownSourceTextView else { return }
            let edited = textView.string
            let change = Self.displayChange(from: lastDisplay, to: edited)
            let previous = MarkdownDisplay(text: lastDisplay, sourceUTF16: sourceUTF16)
            let updated = previous.splicing(
                source: markdown,
                displayReplacement: change.replacement,
                displayUTF16: change.range
            )
            let caret = previous.sourceCaretUTF16(
                displayReplacement: change.replacement,
                displayUTF16: change.range,
                source: markdown
            )
            markdown = updated
            parent.text = updated
            let display = MarkdownDisplay.project(updated, reveal: reveal)
            show(display, in: textView, sourceCaret: caret)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isProgrammaticUpdate,
                  let textView = notification.object as? MarkdownSourceTextView else { return }
            let next = reveal(at: textView.selectedRange().location)
            guard next != reveal else { return }
            reveal = next
            let caret = sourceOffset(at: textView.selectedRange().location)
            let display = MarkdownDisplay.project(markdown, reveal: reveal)
            show(display, in: textView, sourceCaret: caret)
        }

        private func show(
            _ display: MarkdownDisplay,
            in textView: MarkdownSourceTextView,
            sourceCaret: Int?
        ) {
            isProgrammaticUpdate = true
            textView.string = display.text
            sourceUTF16 = display.sourceUTF16
            lastDisplay = display.text
            let location = displayLocation(forSource: sourceCaret, count: (display.text as NSString).length)
            textView.setSelectedRange(NSRange(location: location, length: 0))
            textView.scrollRangeToVisible(textView.selectedRange())
            isProgrammaticUpdate = false
        }

        private func displayLocation(forSource caret: Int?, count: Int) -> Int {
            guard let caret else { return count }
            if let index = sourceUTF16.firstIndex(where: { $0 >= caret }) {
                return index
            }
            return count
        }

        private func sourceOffset(at displayLocation: Int) -> Int {
            if displayLocation <= 0 { return 0 }
            if displayLocation >= sourceUTF16.count {
                return (markdown as NSString).length
            }
            return sourceUTF16[displayLocation]
        }

        private func reveal(at displayLocation: Int) -> MarkdownDisplay.Reveal {
            let offset = sourceOffset(at: displayLocation)
            let index = String.Index(utf16Offset: offset, in: markdown)
            let doc = MarkdownDocument.parse(markdown)
            if let inline = Self.inlineContaining(index, in: doc.blocks) {
                return .inline(Self.contentRange(of: inline))
            }
            if let block = Self.blockContaining(index, in: doc.blocks),
               index < block.marker.upperBound || Self.isObject(block) {
                return .block(Self.isObject(block) ? block.source : block.marker)
            }
            return .none
        }

        private static func isObject(_ block: MarkdownBlock) -> Bool {
            switch block.kind {
            case .image, .codeFence, .mathBlock: return true
            default: return false
            }
        }

        private static func contentRange(of inline: MarkdownInline) -> Range<String.Index> {
            switch inline {
            case .text(let range): return range
            case .strong(let open, _, let close), .emphasis(let open, _, let close):
                return open.upperBound..<close.lowerBound
            case .code(_, let content, _): return content
            case .link(let labelOpen, _, let labelClose, _, _):
                return labelOpen.upperBound..<labelClose.lowerBound
            case .math(_, let latex, _): return latex
            }
        }

        private static func inlineContaining(_ index: String.Index, in blocks: [MarkdownBlock]) -> MarkdownInline? {
            for block in blocks {
                if let found = inlineContaining(index, in: block.inlines) { return found }
                if let found = inlineContaining(index, in: block.children) { return found }
            }
            return nil
        }

        private static func inlineContaining(_ index: String.Index, in inlines: [MarkdownInline]) -> MarkdownInline? {
            for item in inlines {
                switch item {
                case .text(let range):
                    if range.contains(index) { return item }
                case .strong(let open, let content, let close),
                     .emphasis(let open, let content, let close):
                    if (open.lowerBound..<close.upperBound).contains(index) {
                        return inlineContaining(index, in: content) ?? item
                    }
                case .code(let open, _, let close), .math(let open, _, let close):
                    if (open.lowerBound..<close.upperBound).contains(index) { return item }
                case .link(let labelOpen, let label, _, _, let close):
                    if (labelOpen.lowerBound..<close.upperBound).contains(index) {
                        return inlineContaining(index, in: label) ?? item
                    }
                }
            }
            return nil
        }

        private static func blockContaining(_ index: String.Index, in blocks: [MarkdownBlock]) -> MarkdownBlock? {
            for block in blocks {
                if let child = blockContaining(index, in: block.children) { return child }
                if block.source.contains(index) { return block }
            }
            return nil
        }

        private static func displayChange(from old: String, to new: String) -> (range: Range<Int>, replacement: String) {
            let oldUnits = Array(old.utf16)
            let newUnits = Array(new.utf16)
            var prefix = 0
            while prefix < oldUnits.count && prefix < newUnits.count && oldUnits[prefix] == newUnits[prefix] {
                prefix += 1
            }
            var suffix = 0
            while suffix < (oldUnits.count - prefix) && suffix < (newUnits.count - prefix)
                    && oldUnits[oldUnits.count - 1 - suffix] == newUnits[newUnits.count - 1 - suffix] {
                suffix += 1
            }
            let replacement = String(
                decoding: newUnits[prefix..<(newUnits.count - suffix)],
                as: UTF16.self
            )
            return (prefix..<(oldUnits.count - suffix), replacement)
        }
    }
}

/// Scrollable Markdown source plus the insertion toolbar (image / math / link).
final class MarkdownEditorHost: NSView {
    static let toolbarHeight: CGFloat = 28
    var scrollView = NSScrollView()
}

/// The NSTextView behind `MarkdownEditorView`: Return/Tab/⌘B/⌘I typing aids
/// plus Esc forwarding. All edits go through insertText / the
/// shouldChangeText → replaceCharacters → didChangeText cycle so they are
/// undoable and flow into the binding via the delegate.
final class MarkdownSourceTextView: NSTextView {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch event.keyCode {
        case 36, 76 where mods.isEmpty: // Return
            if continueListLine() { return }
            super.keyDown(with: event)
        case 48 where mods == .shift: // ⇧Tab
            indentListLine(outdent: true)
        case 48 where mods.isEmpty: // Tab — never moves focus
            indentListLine(outdent: false)
        case 11 where mods == .command: // ⌘B
            onFormat?("**")
        case 34 where mods == .command: // ⌘I
            onFormat?("*")
        case 40 where mods == .command: // ⌘K
            onLink?()
        case 18 where mods == [.command, .option]: // ⌘⌥1
            onHeading?(1)
        case 19 where mods == [.command, .option]: // ⌘⌥2
            onHeading?(2)
        case 20 where mods == [.command, .option]: // ⌘⌥3
            onHeading?(3)
        default:
            super.keyDown(with: event)
        }
    }

    var onFormat: ((String) -> Void)?
    var onLink: (() -> Void)?
    var onHeading: ((Int) -> Void)?

    // MARK: - Toolbar insertions (3b)

    /// Apply a toolbar insertion at the caret/selection. All paths go through
    /// insertText/replace so they are undoable and reach the binding.
    func applyInsertion(_ payload: MarkdownInsertion.Payload) {
        switch payload {
        case .image(let markdown):
            insertImageBlock(markdown)
        case .math:
            insertMathTemplate()
        case .link:
            insertLinkTemplate()
        }
    }

    /// Image markdown goes on its own line (newline prefix unless the caret
    /// is already at a line start); caret lands after it.
    private func insertImageBlock(_ markdown: String) {
        let ns = string as NSString
        let sel = selectedRange()
        let atLineStart = Self.lineRange(containing: sel.location, in: ns)
            .map { sel.location == $0.content.location } ?? true
        insertText((atLineStart ? "" : "\n") + markdown + "\n", replacementRange: sel)
    }

    /// Block `$$…$$` template on an empty line (caret on the middle line),
    /// otherwise inline `$…$` with the caret between the markers.
    private func insertMathTemplate() {
        let ns = string as NSString
        let sel = selectedRange()
        let line = Self.lineRange(containing: sel.location, in: ns)
        let lineIsEmpty = line
            .map { ns.substring(with: $0.content).trimmingCharacters(in: .whitespaces).isEmpty }
            ?? true
        if lineIsEmpty, let line {
            insertText("$$\n\n$$", replacementRange: line.content)
            setSelectedRange(NSRange(location: line.content.location + 3, length: 0))
        } else {
            let inner = sel.length > 0 ? ns.substring(with: sel) : ""
            insertText("$\(inner)$", replacementRange: sel)
            if inner.isEmpty {
                setSelectedRange(NSRange(location: sel.location + 1, length: 0))
            }
        }
    }

    /// `[title](url)` — selected text becomes the title; the `url`
    /// placeholder stays selected so typing replaces it.
    private func insertLinkTemplate() {
        let ns = string as NSString
        let sel = selectedRange()
        let title = sel.length > 0 ? ns.substring(with: sel) : "title"
        insertText("[\(title)](url)", replacementRange: sel)
        // "[title](" prefix before the url placeholder.
        setSelectedRange(NSRange(location: sel.location + 3 + (title as NSString).length, length: 3))
    }

    // MARK: - List continuation (Return)

    /// Return on a list line: insert newline + same marker (numbered lists
    /// increment, checkboxes reopen); on an empty marker line remove the
    /// marker instead (standard outliner behavior). Returns false when the
    /// current line is not a list line (plain newline, e.g. the H1 title).
    private func continueListLine() -> Bool {
        let ns = string as NSString
        guard let line = Self.lineRange(containing: selectedRange().location, in: ns),
              let marker = Self.listMarker(in: ns, contentRange: line.content) else { return false }
        let content = ns.substring(with: NSRange(
            location: marker.range.upperBound,
            length: line.content.upperBound - marker.range.upperBound
        ))
        if content.trimmingCharacters(in: .whitespaces).isEmpty {
            // Empty marker line: drop the marker, keep the indent.
            replace(marker.range, with: "")
            setSelectedRange(NSRange(location: line.content.location + marker.indent, length: 0))
        } else {
            let insertion = "\n" + String(repeating: " ", count: marker.indent) + marker.continuation
            insertText(insertion, replacementRange: selectedRange())
        }
        return true
    }

    // MARK: - Indent (Tab / ⇧Tab)

    /// List lines indent/outdent by two spaces at the line start (marker
    /// kept); on non-list lines Tab inserts two spaces at the caret, ⇧Tab is
    /// a no-op. Never moves focus.
    private func indentListLine(outdent: Bool) {
        let ns = string as NSString
        guard let line = Self.lineRange(containing: selectedRange().location, in: ns) else { return }
        guard Self.listMarker(in: ns, contentRange: line.content) != nil else {
            if !outdent { insertText("  ", replacementRange: selectedRange()) }
            return
        }
        if outdent {
            var spaces = 0
            while spaces < min(2, line.content.length),
                  ns.character(at: line.content.location + spaces) == 32 { spaces += 1 }
            guard spaces > 0 else { return }
            replace(NSRange(location: line.content.location, length: spaces), with: "")
            let caret = max(line.content.location, selectedRange().location - spaces)
            setSelectedRange(NSRange(location: caret, length: 0))
        } else {
            replace(NSRange(location: line.content.location, length: 0), with: "  ")
            let sel = selectedRange()
            setSelectedRange(NSRange(location: sel.location + 2, length: sel.length))
        }
    }

    // MARK: - ⌘B / ⌘I wrap-toggle

    /// Wrap the selection in the marker (or unwrap when already wrapped);
    /// with no selection insert the marker pair and place the caret inside.
    private func toggleWrap(marker: String) {
        let ns = string as NSString
        let m = (marker as NSString).length
        var sel = selectedRange()
        if sel.length == 0 {
            insertText(marker + marker, replacementRange: sel)
            setSelectedRange(NSRange(location: sel.location + m, length: 0))
            return
        }
        if sel.location >= m, sel.upperBound + m <= ns.length,
           ns.substring(with: NSRange(location: sel.location - m, length: m)) == marker,
           ns.substring(with: NSRange(location: sel.upperBound, length: m)) == marker {
            // Unwrap: trailing marker first so the leading range stays valid.
            replace(NSRange(location: sel.upperBound, length: m), with: "")
            replace(NSRange(location: sel.location - m, length: m), with: "")
            setSelectedRange(NSRange(location: sel.location - m, length: sel.length))
        } else {
            let content = ns.substring(with: sel)
            insertText(marker + content + marker, replacementRange: sel)
            setSelectedRange(NSRange(location: sel.location + m, length: sel.length))
        }
    }

    // MARK: - Line utilities

    /// Line range (content range excludes the line terminator). A caret at
    /// the very end after a trailing newline belongs to the empty last line.
    static func lineRange(containing location: Int, in ns: NSString) -> (full: NSRange, content: NSRange)? {
        guard ns.length > 0 else { return nil }
        let full = ns.lineRange(for: NSRange(location: min(location, ns.length), length: 0))
        var content = full
        while content.length > 0 {
            let c = ns.character(at: content.upperBound - 1)
            if c == 10 || c == 13 { content.length -= 1 } else { break }
        }
        return (full, content)
    }

    /// `- ` / `* ` / `- [ ] ` / `1. ` marker after leading spaces.
    /// `continuation` is the marker text for the NEXT line (numbered lists
    /// increment; checkboxes reopen unchecked).
    static func listMarker(
        in ns: NSString, contentRange: NSRange
    ) -> (indent: Int, range: NSRange, continuation: String)? {
        var i = contentRange.location
        let end = contentRange.upperBound
        var indent = 0
        while i < end, ns.character(at: i) == 32 { i += 1; indent += 1 }
        guard i < end else { return nil }
        let rest = ns.substring(with: NSRange(location: i, length: end - i))
        let markerLength: Int
        let continuation: String
        if rest.hasPrefix("- [ ] ") || rest.hasPrefix("- [x] ") || rest.hasPrefix("- [X] ") {
            markerLength = 6
            continuation = "- [ ] "
        } else if rest.hasPrefix("- ") || rest.hasPrefix("* ") {
            markerLength = 2
            continuation = String(rest.prefix(2))
        } else {
            var digits = 0
            var number = 0
            while digits < rest.count, rest[rest.index(rest.startIndex, offsetBy: digits)].isNumber {
                number = number * 10 + Int(String(rest[rest.index(rest.startIndex, offsetBy: digits)]))!
                digits += 1
            }
            let after = rest.dropFirst(digits)
            guard digits > 0, after.hasPrefix(". ") else { return nil }
            markerLength = digits + 2
            continuation = "\(number + 1). "
        }
        return (indent, NSRange(location: i, length: markerLength), continuation)
    }

    /// Undoable text edit that notifies the delegate (binding sync).
    private func replace(_ range: NSRange, with s: String) {
        guard shouldChangeText(in: range, replacementString: s) else { return }
        textStorage?.replaceCharacters(in: range, with: s)
        didChangeText()
    }
}

/// Attributes-only Markdown styling pass over the editor's text storage.
/// Own line scanner (MarkdownSegmenter reports no ranges, so it cannot drive
/// attribute ranges): fenced code + block math state, headings, list
/// markers, image lines, and an inline pass for `**`/`*`/`` ` ``/`$` spans.
enum MarkdownStyler {
    static let baseFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private static let headingSizes: [CGFloat] = [17, 15, 13.5]
    private static let codeBackground = NSColor.labelColor.withAlphaComponent(0.08)

    static func apply(to storage: NSTextStorage) {
        let ns = storage.string as NSString
        let whole = NSRange(location: 0, length: ns.length)
        storage.beginEditing()
        storage.setAttributes([.font: baseFont, .foregroundColor: NSColor.labelColor], range: whole)

        var fenceChar: unichar = 0 // 0 = outside a fence
        var inBlockMath = false
        var lineStart = 0
        while lineStart < ns.length {
            guard let line = MarkdownSourceTextView.lineRange(containing: lineStart, in: ns) else { break }
            styleLine(in: storage, ns: ns, line: line, fenceChar: &fenceChar, inBlockMath: &inBlockMath)
            let next = line.full.upperBound
            guard next > lineStart else { break }
            lineStart = next
        }
        storage.endEditing()
    }

    private static func styleLine(
        in storage: NSTextStorage, ns: NSString,
        line: (full: NSRange, content: NSRange),
        fenceChar: inout unichar, inBlockMath: inout Bool
    ) {
        let content = line.content
        guard content.length > 0 else { return }
        let text = ns.substring(with: content)
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let leadingWhitespace = text.prefix(while: { $0 == " " || $0 == "\t" }).count
        let trimOffset = leadingWhitespace

        // Fenced code: everything verbatim until the matching closing fence.
        if fenceChar != 0 {
            styleCodeLine(storage, range: line.full)
            if leadingWhitespace <= 3, isFenceRun(trimmed, char: fenceChar) {
                fenceChar = 0
            }
            return
        }
        if inBlockMath {
            storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: content)
            if trimmed == "$$" { inBlockMath = false }
            return
        }
        if leadingWhitespace <= 3, let opener = fenceOpener(trimmed) {
            fenceChar = opener
            styleCodeLine(storage, range: line.full)
            return
        }
        if trimmed == "$$" {
            inBlockMath = true
            storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: content)
            return
        }
        // Image lines: visually collapse the noisy data-URI — small and dim
        // (storage untouched, styling only).
        if trimmed.hasPrefix("![") {
            storage.addAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ], range: content)
            return
        }

        // Inline spans start after any structural marker so `* item` never
        // parses its list marker as italic.
        var inlineStart = 0

        // Heading: 1-3 '#' followed by a space.
        var hashes = 0
        while hashes < content.length, ns.character(at: content.location + hashes) == 35 { hashes += 1 }
        if hashes >= 1, hashes <= 3, content.length > hashes,
           ns.character(at: content.location + hashes) == 32 {
            let level = hashes - 1
            storage.addAttribute(
                .font,
                value: NSFont.monospacedSystemFont(ofSize: headingSizes[level], weight: .bold),
                range: content
            )
            storage.addAttribute(
                .foregroundColor,
                value: NSColor.secondaryLabelColor,
                range: NSRange(location: content.location, length: hashes + 1)
            )
            inlineStart = hashes + 1
        }

        // List marker dimming.
        if let marker = MarkdownSourceTextView.listMarker(in: ns, contentRange: content) {
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: marker.range)
            inlineStart = max(inlineStart, marker.range.upperBound - content.location)
        }

        styleInlineSpans(in: storage, ns: ns, content: content, from: inlineStart)
    }

    private static func styleCodeLine(_ storage: NSTextStorage, range: NSRange) {
        storage.addAttributes([
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .backgroundColor: codeBackground,
        ], range: range)
    }

    /// `true` when the trimmed line is a run of ≥3 of `char` (fence rule).
    private static func isFenceRun(_ trimmed: String, char: unichar) -> Bool {
        guard trimmed.count >= 3 else { return false }
        return trimmed.utf16.allSatisfy { $0 == char }
    }

    /// Fence opener char (backtick or tilde) for a trimmed line — a run of
    /// ≥3, optionally followed by an info string (```swift) — else nil.
    private static func fenceOpener(_ trimmed: String) -> unichar? {
        guard trimmed.count >= 3, let first = trimmed.utf16.first,
              first == 96 /* ` */ || first == 126 /* ~ */,
              trimmed.utf16.prefix(3).allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    /// Single left-to-right inline pass for `**bold**`, `*italic*`,
    /// `` `code` `` and `$math$` spans. Non-recursive; markers get dimmed.
    /// Token checks run longest-first so `**` and `$$` win over `*` and `$`.
    private static func styleInlineSpans(in storage: NSTextStorage, ns: NSString, content: NSRange, from start: Int) {
        func has(_ token: String, at i: Int) -> Bool {
            let t = token as NSString
            guard i + t.length <= content.length else { return false }
            return ns.substring(with: NSRange(location: content.location + i, length: t.length)) == token
        }
        func findClosing(_ token: String, from i: Int) -> Int? {
            let t = token as NSString
            var j = i
            while j + t.length <= content.length {
                if ns.substring(with: NSRange(location: content.location + j, length: t.length)) == token {
                    return j
                }
                j += 1
            }
            return nil
        }
        func apply(_ token: String, at i: Int, end j: Int, style: (NSRange) -> Void) {
            let t = (token as NSString).length
            let markerStyle: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.secondaryLabelColor]
            storage.addAttributes(markerStyle, range: NSRange(location: content.location + i, length: t))
            storage.addAttributes(markerStyle, range: NSRange(location: content.location + j, length: t))
            style(NSRange(location: content.location + i + t, length: j - i - t))
        }

        var i = start
        while i < content.length {
            if has("**", at: i), let j = findClosing("**", from: i + 2) {
                apply("**", at: i, end: j) { inner in
                    storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 13, weight: .bold), range: inner)
                }
                i = j + 2
            } else if has("*", at: i), let j = findClosing("*", from: i + 1) {
                apply("*", at: i, end: j) { inner in
                    storage.addAttribute(.font, value: italicFont(), range: inner)
                }
                i = j + 1
            } else if has("`", at: i), let j = findClosing("`", from: i + 1) {
                apply("`", at: i, end: j) { inner in
                    storage.addAttribute(.backgroundColor, value: codeBackground, range: inner)
                }
                i = j + 1
            } else if has("$$", at: i), let j = findClosing("$$", from: i + 2) {
                storage.addAttribute(
                    .foregroundColor,
                    value: NSColor.controlAccentColor,
                    range: NSRange(location: content.location + i, length: j + 2 - i)
                )
                i = j + 2
            } else if has("$", at: i), let j = findClosing("$", from: i + 1) {
                storage.addAttribute(
                    .foregroundColor,
                    value: NSColor.controlAccentColor,
                    range: NSRange(location: content.location + i, length: j + 1 - i)
                )
                i = j + 1
            } else {
                i += 1
            }
        }
    }

    private static func italicFont() -> NSFont {
        let base = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let italic = NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
        return italic
    }
}
