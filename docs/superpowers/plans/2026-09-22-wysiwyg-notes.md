# WYSIWYG Notes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render note editing as the formatted note while the file stays Markdown, measure expanded-card height from that rendering, and parse notes into a source-ranged AST both sides share.

**Architecture:** `MarkdownDocument` in SwiftMindCore parses a fixed subset into blocks and inlines with `Range<String.Index>`. `MarkdownDisplay` projects that tree into the string the editor shows and maps every UTF-16 unit back to the source. `LayoutEngine` still starts from a parser guess; `MapStore.noteCardHeights` overrides it after the Mac app measures `MarkdownTextView`. The NSTextView stores the display string only; commits still go through `NoteDocument.split` on the markdown binding.

**Tech Stack:** Swift 5.10, SwiftMindCore (no AppKit), AppKit `NSTextView`, SwiftUI `NSHostingView`, XCTest. No new packages.

**Spec:** `docs/superpowers/specs/2026-09-21-wysiwyg-notes-design.md`

Three phases, one plan, because each phase's API is the next phase's input. Stop after Task 6 and the core still builds. Stop after Task 9 and cards measure without the WYSIWYG editor. Tasks 10–16 are the editor.

---

## File map

| File | Responsibility |
|------|----------------|
| `Sources/SwiftMindCore/Markdown/MarkdownDocument.swift` | AST, `parse`, source ranges |
| `Sources/SwiftMindCore/Markdown/MarkdownMeasure.swift` | Parser-based height guess |
| `Sources/SwiftMindCore/Markdown/MarkdownDisplay.swift` | Rendered string, reveal, UTF-16 source map, splice |
| `Tests/SwiftMindCoreTests/MarkdownDocumentTests.swift` | Parse cases and ranges |
| `Tests/SwiftMindCoreTests/MarkdownMeasureTests.swift` | Wrap, image, fence, cap inputs |
| `Tests/SwiftMindCoreTests/MarkdownDisplayTests.swift` | Hide marks, reveal, splice |
| `Sources/SwiftMindCore/Layout/LayoutEngine.swift` | `measuredNoteHeights` override |
| `Sources/SwiftMindCore/Store/MapStore.swift` | In-memory heights, one re-layout |
| `Tests/SwiftMindCoreTests/LayoutEngineTests.swift` | Override and cap |
| `Apps/SwiftMindMac/SwiftMindMac/Markdown/NoteCardMeasurer.swift` | Host the real card view, return map-point height |
| `Apps/SwiftMindMac/SwiftMindMac/Markdown/MarkdownEditorView.swift` | Display string, reveal, shortcuts |
| `Apps/SwiftMindMac/SwiftMindMac/Markdown/MarkdownTextView.swift` | Read-only card reads the AST for images and math |
| `Apps/SwiftMindMac/SwiftMindMac/MapCanvasView.swift` | Measure after layout; pass markdown binding unchanged |
| `Apps/SwiftMindMac/SwiftMindMacUITests/SwiftMindMacUITests.swift` | Reveal and measured card |
| `README.md`, `help-map.ops.json` | User-facing note copy |

SPM picks up new files under `Sources/SwiftMindCore` and `Tests/`. XcodeGen picks up new files under `Apps/SwiftMindMac/SwiftMindMac/`.

Run a single test with:

```bash
swift test --filter MarkdownDocumentTests.testParagraphIsLiteralText
```

Expected failure before the type exists: `error: cannot find 'MarkdownDocument' in scope`. Expected pass after the matching step: `Test Case '...testParagraphIsLiteralText' passed`.

---

### Task 1: AST types and paragraph parse

**Files:**
- Create: `Tests/SwiftMindCoreTests/MarkdownDocumentTests.swift`
- Create: `Sources/SwiftMindCore/Markdown/MarkdownDocument.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import SwiftMindCore

final class MarkdownDocumentTests: XCTestCase {
    func testParagraphIsLiteralText() {
        let source = "Ship Friday."
        let doc = MarkdownDocument.parse(source)
        XCTAssertEqual(doc.blocks.count, 1)
        XCTAssertEqual(doc.blocks[0].kind, .paragraph)
        XCTAssertEqual(String(source[doc.blocks[0].source]), "Ship Friday.")
        guard case .text(let range) = doc.blocks[0].inlines.first else {
            return XCTFail("expected a text inline")
        }
        XCTAssertEqual(String(source[range]), "Ship Friday.")
    }

    func testEmptyIsNoBlocks() {
        XCTAssertEqual(MarkdownDocument.parse("").blocks, [])
        XCTAssertEqual(MarkdownDocument.parse("\n\n").blocks, [])
    }
}
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `swift test --filter MarkdownDocumentTests.testParagraphIsLiteralText`

Expected: FAIL, `cannot find 'MarkdownDocument' in scope`.

- [ ] **Step 3: Add the types and a paragraph-only parser**

Create `Sources/SwiftMindCore/Markdown/MarkdownDocument.swift`:

```swift
import Foundation

public struct MarkdownDocument: Equatable, Sendable {
    public var blocks: [MarkdownBlock]

    public init(blocks: [MarkdownBlock]) {
        self.blocks = blocks
    }

    public static func parse(_ source: String) -> MarkdownDocument {
        MarkdownParser.parse(source)
    }
}

public struct MarkdownBlock: Equatable, Sendable {
    public var kind: MarkdownBlockKind
    /// Whole block, including its marker and the trailing newline when present.
    public var source: Range<String.Index>
    /// Delimiter the editor reveals. Empty (`lowerBound == upperBound`) for a paragraph.
    public var marker: Range<String.Index>
    public var inlines: [MarkdownInline]
    public var children: [MarkdownBlock]

    public init(
        kind: MarkdownBlockKind,
        source: Range<String.Index>,
        marker: Range<String.Index>,
        inlines: [MarkdownInline] = [],
        children: [MarkdownBlock] = []
    ) {
        self.kind = kind
        self.source = source
        self.marker = marker
        self.inlines = inlines
        self.children = children
    }
}

public enum MarkdownBlockKind: Equatable, Sendable {
    case heading(level: Int)
    case paragraph
    case listItem(ordered: Bool, checked: Bool?, indent: Int)
    case quote
    case codeFence
    case mathBlock
    case image(alt: Range<String.Index>, url: Range<String.Index>)
}

public enum MarkdownInline: Equatable, Sendable {
    case text(Range<String.Index>)
    case strong(open: Range<String.Index>, content: [MarkdownInline], close: Range<String.Index>)
    case emphasis(open: Range<String.Index>, content: [MarkdownInline], close: Range<String.Index>)
    case code(open: Range<String.Index>, content: Range<String.Index>, close: Range<String.Index>)
    case link(
        labelOpen: Range<String.Index>,
        label: [MarkdownInline],
        labelClose: Range<String.Index>,
        url: Range<String.Index>,
        close: Range<String.Index>
    )
    case math(open: Range<String.Index>, latex: Range<String.Index>, close: Range<String.Index>)
}

enum MarkdownParser {
    static func parse(_ source: String) -> MarkdownDocument {
        var blocks: [MarkdownBlock] = []
        var index = source.startIndex
        while index < source.endIndex {
            if source[index] == "\n" {
                index = source.index(after: index)
                continue
            }
            let start = index
            var end = index
            while end < source.endIndex, source[end] != "\n" {
                end = source.index(after: end)
            }
            let lineEnd = end
            if end < source.endIndex { end = source.index(after: end) }
            let content = start..<lineEnd
            blocks.append(MarkdownBlock(
                kind: .paragraph,
                source: start..<end,
                marker: start..<start,
                inlines: [.text(content)]
            ))
            index = end
        }
        return MarkdownDocument(blocks: blocks)
    }
}
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `swift test --filter MarkdownDocumentTests`

Expected: `testParagraphIsLiteralText` and `testEmptyIsNoBlocks` passed.

- [ ] **Step 5: Commit**

```bash
git add Sources/SwiftMindCore/Markdown/MarkdownDocument.swift Tests/SwiftMindCoreTests/MarkdownDocumentTests.swift
git commit -m "feat(markdown): paragraph AST with source ranges"
```

---

### Task 2: ATX headings

**Files:**
- Modify: `Tests/SwiftMindCoreTests/MarkdownDocumentTests.swift`
- Modify: `Sources/SwiftMindCore/Markdown/MarkdownDocument.swift` (`MarkdownParser.parse`)

- [ ] **Step 1: Write the failing test**

Append to `MarkdownDocumentTests`:

```swift
func testHeadingMarkerAndLevel() {
    let source = "## title2\n"
    let doc = MarkdownDocument.parse(source)
    XCTAssertEqual(doc.blocks.count, 1)
    XCTAssertEqual(doc.blocks[0].kind, .heading(level: 2))
    XCTAssertEqual(String(source[doc.blocks[0].marker]), "## ")
    guard case .text(let range) = doc.blocks[0].inlines.first else {
        return XCTFail("expected heading text")
    }
    XCTAssertEqual(String(source[range]), "title2")
}

func testUnclosedHeadingStaysParagraph() {
    let source = "##title"
    let doc = MarkdownDocument.parse(source)
    XCTAssertEqual(doc.blocks[0].kind, .paragraph)
}
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `swift test --filter MarkdownDocumentTests.testHeadingMarkerAndLevel`

Expected: FAIL, kind is `.paragraph`.

- [ ] **Step 3: Detect a heading line before the paragraph fallback**

In `MarkdownParser.parse`, before appending the paragraph, if `headingBlock(source, start: start, lineEnd: lineEnd, blockEnd: end)` returns a block, append that and `continue`.

Add this function inside `MarkdownParser`:

```swift
static func headingBlock(
    _ source: String,
    start: String.Index,
    lineEnd: String.Index,
    blockEnd: String.Index
) -> MarkdownBlock? {
    var i = start
    var level = 0
    while i < lineEnd, source[i] == "#", level < 6 {
        level += 1
        i = source.index(after: i)
    }
    guard level >= 1, i < lineEnd, source[i] == " " else { return nil }
    let markerEnd = source.index(after: i)
    return MarkdownBlock(
        kind: .heading(level: level),
        source: start..<blockEnd,
        marker: start..<markerEnd,
        inlines: [.text(markerEnd..<lineEnd)]
    )
}
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `swift test --filter MarkdownDocumentTests`

Expected: PASS, including the paragraph tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/SwiftMindCore/Markdown/MarkdownDocument.swift Tests/SwiftMindCoreTests/MarkdownDocumentTests.swift
git commit -m "feat(markdown): parse ATX headings with marker ranges"
```

---

### Task 3: Lists, checkboxes, nesting

**Files:**
- Modify: `Tests/SwiftMindCoreTests/MarkdownDocumentTests.swift`
- Modify: `Sources/SwiftMindCore/Markdown/MarkdownDocument.swift`

- [ ] **Step 1: Write the failing tests**

```swift
func testBulletMarkerAndText() {
    let source = "- alpha"
    let doc = MarkdownDocument.parse(source)
    XCTAssertEqual(doc.blocks[0].kind, .listItem(ordered: false, checked: nil, indent: 0))
    XCTAssertEqual(String(source[doc.blocks[0].marker]), "- ")
    guard case .text(let range) = doc.blocks[0].inlines.first else {
        return XCTFail("expected item text")
    }
    XCTAssertEqual(String(source[range]), "alpha")
}

func testCheckboxAndNestedItem() {
    let source = "- [x] parent\n  - child\n"
    let doc = MarkdownDocument.parse(source)
    XCTAssertEqual(doc.blocks.count, 1)
    XCTAssertEqual(doc.blocks[0].kind, .listItem(ordered: false, checked: true, indent: 0))
    XCTAssertEqual(doc.blocks[0].children.count, 1)
    XCTAssertEqual(
        doc.blocks[0].children[0].kind,
        .listItem(ordered: false, checked: nil, indent: 2)
    )
}

func testOrderedItem() {
    let source = "1. beta"
    let doc = MarkdownDocument.parse(source)
    XCTAssertEqual(doc.blocks[0].kind, .listItem(ordered: true, checked: nil, indent: 0))
    XCTAssertEqual(String(source[doc.blocks[0].marker]), "1. ")
}
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `swift test --filter MarkdownDocumentTests.testBulletMarkerAndText`

Expected: FAIL, kind is `.paragraph`.

- [ ] **Step 3: Parse list lines, then nest by indent**

Recognize a list line before the paragraph fallback. After the line loop, replace the block array with `nestLists(blocks)`.

```swift
static func listItemBlock(
    _ source: String,
    start: String.Index,
    lineEnd: String.Index,
    blockEnd: String.Index
) -> MarkdownBlock? {
    var i = start
    var indent = 0
    while i < lineEnd, source[i] == " " {
        indent += 1
        i = source.index(after: i)
    }
    guard i < lineEnd else { return nil }
    let markerStart = i
    var ordered = false
    if source[i] == "-" || source[i] == "*" {
        i = source.index(after: i)
        guard i < lineEnd, source[i] == " " else { return nil }
        i = source.index(after: i)
    } else if source[i].isNumber {
        ordered = true
        while i < lineEnd, source[i].isNumber { i = source.index(after: i) }
        guard i < lineEnd, source[i] == "." else { return nil }
        i = source.index(after: i)
        guard i < lineEnd, source[i] == " " else { return nil }
        i = source.index(after: i)
    } else {
        return nil
    }
    var checked: Bool? = nil
    if !ordered, i < lineEnd, source[i] == "[" {
        let box = source[i..<lineEnd]
        if box.hasPrefix("[ ] ") || box.hasPrefix("[x] ") || box.hasPrefix("[X] ") {
            checked = source[source.index(i, offsetBy: 1)] != " "
            i = source.index(i, offsetBy: 4)
        }
    }
    return MarkdownBlock(
        kind: .listItem(ordered: ordered, checked: checked, indent: indent),
        source: start..<blockEnd,
        marker: markerStart..<i,
        inlines: [.text(i..<lineEnd)]
    )
}

static func nestLists(_ blocks: [MarkdownBlock]) -> [MarkdownBlock] {
    func indent(of block: MarkdownBlock) -> Int? {
        guard case .listItem(_, _, let indent) = block.kind else { return nil }
        return indent
    }
    var roots: [MarkdownBlock] = []
    var stack: [(indent: Int, block: MarkdownBlock)] = []
    func close(to indentLimit: Int) {
        while let top = stack.last, top.indent > indentLimit {
            stack.removeLast()
            if var parent = stack.last {
                parent.block.children.append(top.block)
                parent.block.source = parent.block.source.lowerBound..<top.block.source.upperBound
                stack[stack.count - 1] = parent
            } else {
                roots.append(top.block)
            }
        }
    }
    for block in blocks {
        guard let itemIndent = indent(of: block) else {
            close(to: -1)
            roots.append(block)
            continue
        }
        close(to: itemIndent)
        stack.append((itemIndent, block))
    }
    close(to: -1)
    return roots
}
```

Call `listItemBlock` before the paragraph fallback. After the loop, `return MarkdownDocument(blocks: nestLists(blocks))`.

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `swift test --filter MarkdownDocumentTests`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SwiftMindCore/Markdown/MarkdownDocument.swift Tests/SwiftMindCoreTests/MarkdownDocumentTests.swift
git commit -m "feat(markdown): parse nested list items and checkboxes"
```

---

### Task 4: Quotes, fences, math blocks, images

**Files:**
- Modify: `Tests/SwiftMindCoreTests/MarkdownDocumentTests.swift`
- Modify: `Sources/SwiftMindCore/Markdown/MarkdownDocument.swift`

- [ ] **Step 1: Write the failing tests**

```swift
func testQuoteMarker() {
    let source = "> noted"
    let doc = MarkdownDocument.parse(source)
    XCTAssertEqual(doc.blocks[0].kind, .quote)
    XCTAssertEqual(String(source[doc.blocks[0].marker]), "> ")
}

func testFenceHidesInnerMarks() {
    let source = "```\n**nope**\n```\n"
    let doc = MarkdownDocument.parse(source)
    XCTAssertEqual(doc.blocks.count, 1)
    XCTAssertEqual(doc.blocks[0].kind, .codeFence)
    XCTAssertEqual(doc.blocks[0].inlines.count, 1)
    guard case .text(let range) = doc.blocks[0].inlines[0] else {
        return XCTFail("fence body is raw text")
    }
    XCTAssertEqual(String(source[range]), "**nope**")
}

func testMathBlockContentRange() {
    let source = "$$\na = b\n$$\n"
    let doc = MarkdownDocument.parse(source)
    XCTAssertEqual(doc.blocks[0].kind, .mathBlock)
    guard case .text(let range) = doc.blocks[0].inlines.first else {
        return XCTFail("expected latex text")
    }
    XCTAssertEqual(String(source[range]), "a = b")
}

func testImageLine() {
    let source = "![sketch](data:image/png;base64,QQ==)"
    let doc = MarkdownDocument.parse(source)
    guard case .image(let alt, let url) = doc.blocks[0].kind else {
        return XCTFail("expected an image block")
    }
    XCTAssertEqual(String(source[alt]), "sketch")
    XCTAssertTrue(String(source[url]).hasPrefix("data:image/png"))
}

func testDollarAmountIsText() {
    let source = "Costs $5 and $10."
    let doc = MarkdownDocument.parse(source)
    XCTAssertEqual(doc.blocks[0].kind, .paragraph)
    guard case .text = doc.blocks[0].inlines.first else {
        return XCTFail("dollar amounts stay text")
    }
}
```

`testDollarAmountIsText` passes with the paragraph parser. Keep it; Task 5 must not turn those dollars into math.

- [ ] **Step 2: Run the new fence test and confirm it fails**

Run: `swift test --filter MarkdownDocumentTests.testFenceHidesInnerMarks`

Expected: FAIL, more than one block.

- [ ] **Step 3: Parse those blocks before a paragraph line**

Try them in this order at the start of each line: fence, math block, image, heading, list, quote, else paragraph. A fence and a math block consume every line through their closer, so they are not single-line. Implement them as scans from `index` that advance `index` themselves, and skip the single-line loop when they match.

```swift
static func fenceBlock(_ source: String, from index: String.Index) -> (MarkdownBlock, String.Index)? {
    let lineEnd = endOfLine(source, index)
    let line = source[index..<lineEnd]
    let trimmed = line.drop(while: { $0 == " " })
    guard trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") else { return nil }
    let marker = trimmed.hasPrefix("```") ? "```" : "~~~"
    var cursor = lineEnd < source.endIndex ? source.index(after: lineEnd) : lineEnd
    var bodyStart = cursor
    while cursor < source.endIndex {
        let rowEnd = endOfLine(source, cursor)
        let row = source[cursor..<rowEnd].drop(while: { $0 == " " })
        if row.hasPrefix(marker), row.dropFirst(marker.count).allSatisfy({ $0 == " " || $0 == "\t" }) {
            let blockEnd = rowEnd < source.endIndex ? source.index(after: rowEnd) : rowEnd
            return (MarkdownBlock(
                kind: .codeFence,
                source: index..<blockEnd,
                marker: index..<bodyStart,
                inlines: [.text(bodyStart..<cursor)]
            ), blockEnd)
        }
        cursor = rowEnd < source.endIndex ? source.index(after: rowEnd) : rowEnd
    }
    return nil
}

static func mathBlock(_ source: String, from index: String.Index) -> (MarkdownBlock, String.Index)? {
    let lineEnd = endOfLine(source, index)
    guard source[index..<lineEnd].trimmingCharacters(in: .whitespaces) == "$$" else { return nil }
    var cursor = lineEnd < source.endIndex ? source.index(after: lineEnd) : lineEnd
    let bodyStart = cursor
    while cursor < source.endIndex {
        let rowEnd = endOfLine(source, cursor)
        if source[cursor..<rowEnd].trimmingCharacters(in: .whitespaces) == "$$" {
            let blockEnd = rowEnd < source.endIndex ? source.index(after: rowEnd) : rowEnd
            var bodyEnd = cursor
            if bodyEnd > bodyStart, source[source.index(before: bodyEnd)] == "\n" {
                bodyEnd = source.index(before: bodyEnd)
            }
            return (MarkdownBlock(
                kind: .mathBlock,
                source: index..<blockEnd,
                marker: index..<bodyStart,
                inlines: [.text(bodyStart..<bodyEnd)]
            ), blockEnd)
        }
        cursor = rowEnd < source.endIndex ? source.index(after: rowEnd) : rowEnd
    }
    return nil
}

static func imageBlock(
    _ source: String,
    start: String.Index,
    lineEnd: String.Index,
    blockEnd: String.Index
) -> MarkdownBlock? {
    let line = source[start..<lineEnd]
    guard line.hasPrefix("![") else { return nil }
    guard let altEnd = line.range(of: "]("), let close = line.lastIndex(of: ")"), close > altEnd.upperBound else {
        return nil
    }
    let alt = source.index(start, offsetBy: 2)..<source.index(start, offsetBy: line.distance(from: line.startIndex, to: altEnd.lowerBound))
    let urlStart = source.index(start, offsetBy: line.distance(from: line.startIndex, to: altEnd.upperBound))
    let urlEnd = source.index(start, offsetBy: line.distance(from: line.startIndex, to: close))
    return MarkdownBlock(
        kind: .image(alt: alt, url: urlStart..<urlEnd),
        source: start..<blockEnd,
        marker: start..<lineEnd,
        inlines: []
    )
}

static func quoteBlock(
    _ source: String,
    start: String.Index,
    lineEnd: String.Index,
    blockEnd: String.Index
) -> MarkdownBlock? {
    guard source[start..<lineEnd].hasPrefix("> ") else { return nil }
    let markerEnd = source.index(start, offsetBy: 2)
    return MarkdownBlock(
        kind: .quote,
        source: start..<blockEnd,
        marker: start..<markerEnd,
        inlines: [.text(markerEnd..<lineEnd)]
    )
}

static func endOfLine(_ source: String, _ index: String.Index) -> String.Index {
    var end = index
    while end < source.endIndex, source[end] != "\n" { end = source.index(after: end) }
    return end
}
```

`imageBlock` index math is easy to get wrong. Build the alt and url ranges from the line slice instead:

```swift
let alt = source.index(start, offsetBy: 2)..<source.index(start, offsetBy: line.distance(from: line.startIndex, to: altEnd.lowerBound))
```

is correct when `line.startIndex` is `start`. Add `XCTAssertEqual(String(source[alt]), "sketch")` which the test already has, and fix the offsets if that assertion fails before committing.

Unclosed fence or math block returns nil so the lines fall through as paragraphs.

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `swift test --filter MarkdownDocumentTests`

Expected: PASS. `testDollarAmountIsText` still passes.

- [ ] **Step 5: Commit**

```bash
git add Sources/SwiftMindCore/Markdown/MarkdownDocument.swift Tests/SwiftMindCoreTests/MarkdownDocumentTests.swift
git commit -m "feat(markdown): parse quotes, fences, math blocks, and images"
```

---

### Task 5: Inlines

**Files:**
- Modify: `Tests/SwiftMindCoreTests/MarkdownDocumentTests.swift`
- Modify: `Sources/SwiftMindCore/Markdown/MarkdownDocument.swift`

- [ ] **Step 1: Write the failing tests**

```swift
func testStrongMarkerRanges() {
    let source = "Ship **Friday**."
    let doc = MarkdownDocument.parse(source)
    guard case .strong(let open, let content, let close) = doc.blocks[0].inlines[1] else {
        return XCTFail("expected strong as the second inline, got \(doc.blocks[0].inlines)")
    }
    XCTAssertEqual(String(source[open]), "**")
    XCTAssertEqual(content.count, 1)
    guard case .text(let text) = content[0] else { return XCTFail("expected text") }
    XCTAssertEqual(String(source[text]), "Friday")
    XCTAssertEqual(String(source[close]), "**")
}

func testUnmatchedStarsStayText() {
    let source = "a * b"
    let doc = MarkdownDocument.parse(source)
    guard case .text(let range) = doc.blocks[0].inlines.first else {
        return XCTFail("expected one text run")
    }
    XCTAssertEqual(String(source[range]), "a * b")
}

func testInlineCodeHidesInnerStars() {
    let source = "`**x**`"
    let doc = MarkdownDocument.parse(source)
    guard case .code(_, let content, _) = doc.blocks[0].inlines[0] else {
        return XCTFail("expected code")
    }
    XCTAssertEqual(String(source[content]), "**x**")
}

func testLinkRanges() {
    let source = "See [the spec](https://example.com)."
    let doc = MarkdownDocument.parse(source)
    guard case .link(_, let label, _, let url, _) = doc.blocks[0].inlines[1] else {
        return XCTFail("expected a link, got \(doc.blocks[0].inlines)")
    }
    guard case .text(let labelRange) = label[0] else { return XCTFail("expected label text") }
    XCTAssertEqual(String(source[labelRange]), "the spec")
    XCTAssertEqual(String(source[url]), "https://example.com")
}

func testInlineMathNotADollarAmount() {
    let source = "Use $x$ here, not $5."
    let doc = MarkdownDocument.parse(source)
    guard case .math(_, let latex, _) = doc.blocks[0].inlines[1] else {
        return XCTFail("expected math, got \(doc.blocks[0].inlines)")
    }
    XCTAssertEqual(String(source[latex]), "x")
}
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `swift test --filter MarkdownDocumentTests.testStrongMarkerRanges`

Expected: FAIL, the paragraph is one `.text` run.

- [ ] **Step 3: Parse inlines inside paragraph, heading, list, and quote content**

Do not parse inlines inside `codeFence` or `mathBlock`. Replace `.text(content)` for the other kinds with `parseInlines(source, in: content)`.

```swift
static func parseInlines(_ source: String, in range: Range<String.Index>) -> [MarkdownInline] {
    var output: [MarkdownInline] = []
    var index = range.lowerBound
    var textStart = index
    func flushText(to end: String.Index) {
        guard textStart < end else { return }
        output.append(.text(textStart..<end))
        textStart = end
    }
    while index < range.upperBound {
        if source[index] == "`", let found = closedSpan(source, from: index, limit: range.upperBound, marker: "`") {
            flushText(to: index)
            output.append(.code(open: found.open, content: found.content, close: found.close))
            index = found.close.upperBound
            textStart = index
            continue
        }
        if source[index] == "*", let found = wrapped(source, from: index, limit: range.upperBound, marker: "**") {
            flushText(to: index)
            output.append(.strong(
                open: found.open,
                content: parseInlines(source, in: found.content),
                close: found.close
            ))
            index = found.close.upperBound
            textStart = index
            continue
        }
        if source[index] == "*", let found = wrapped(source, from: index, limit: range.upperBound, marker: "*") {
            flushText(to: index)
            output.append(.emphasis(
                open: found.open,
                content: parseInlines(source, in: found.content),
                close: found.close
            ))
            index = found.close.upperBound
            textStart = index
            continue
        }
        if source[index] == "[", let link = parseLink(source, from: index, limit: range.upperBound) {
            flushText(to: index)
            output.append(link.inline)
            index = link.end
            textStart = index
            continue
        }
        if source[index] == "$", isMathOpen(source, at: index, limit: range.upperBound),
           let found = wrapped(source, from: index, limit: range.upperBound, marker: "$") {
            flushText(to: index)
            output.append(.math(open: found.open, latex: found.content, close: found.close))
            index = found.close.upperBound
            textStart = index
            continue
        }
        index = source.index(after: index)
    }
    flushText(to: range.upperBound)
    return output
}
```

`wrapped` finds `marker` at `from`, then the next `marker` that is not the same index. Content must be non-empty and must not contain a newline. `closedSpan` is `wrapped` for a one-character marker, and its content is not scanned again (the caller stores it as `.code` / uses the raw range).

`isMathOpen` copies the segmenter rule: the previous character is the start of the range, whitespace, or one of `([{>-~`; the next character exists, is not whitespace, and is not `$`. The closer from `wrapped` must be preceded by a non-space and followed by the end of the range, whitespace, or one of `)],.;:!?`.

`parseLink` matches `[` ... `](` ... `)` with no newline. `labelOpen` is the `[`, `labelClose` is `](`, `url` is the url range, `close` is the final `)`.

Try `**` before `*` so a strong pair wins.

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `swift test --filter MarkdownDocumentTests`

Expected: PASS, including `testDollarAmountIsText` and `testInlineMathNotADollarAmount`.

- [ ] **Step 5: Commit**

```bash
git add Sources/SwiftMindCore/Markdown/MarkdownDocument.swift Tests/SwiftMindCoreTests/MarkdownDocumentTests.swift
git commit -m "feat(markdown): parse inline strong, code, links, and math"
```

---

### Task 6: Height guess from the AST

**Files:**
- Create: `Tests/SwiftMindCoreTests/MarkdownMeasureTests.swift`
- Create: `Sources/SwiftMindCore/Markdown/MarkdownMeasure.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import SwiftMindCore

final class MarkdownMeasureTests: XCTestCase {
    private let measure = MarkdownMeasure(width: 360, charWidth: 7, lineHeight: 20, imageHeight: 160)

    func testWrappedParagraphIsTallerThanOneLine() {
        let text = String(repeating: "word ", count: 80)
        XCTAssertGreaterThan(measure.height(of: text), 20)
    }

    func testImageUsesImageHeight() {
        XCTAssertEqual(
            measure.height(of: "![a](data:image/png;base64,QQ==)"),
            160
        )
    }

    func testFenceCountsContentLines() {
        XCTAssertEqual(measure.height(of: "```\na\nb\n```"), 40)
    }
}
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `swift test --filter MarkdownMeasureTests.testWrappedParagraphIsTallerThanOneLine`

Expected: FAIL, `cannot find 'MarkdownMeasure' in scope`.

- [ ] **Step 3: Implement the guess**

```swift
import Foundation

public struct MarkdownMeasure: Equatable, Sendable {
    public var width: Double
    public var charWidth: Double
    public var lineHeight: Double
    public var imageHeight: Double

    public init(width: Double, charWidth: Double, lineHeight: Double, imageHeight: Double) {
        self.width = width
        self.charWidth = charWidth
        self.lineHeight = lineHeight
        self.imageHeight = imageHeight
    }

    public func height(of source: String) -> Double {
        MarkdownDocument.parse(source).blocks.reduce(0) { $0 + height(of: $1, in: source) }
    }

    private func height(of block: MarkdownBlock, in source: String) -> Double {
        let own: Double
        switch block.kind {
        case .image:
            own = imageHeight
        case .codeFence, .mathBlock:
            let text = block.inlines.compactMap { inline -> String? in
                guard case .text(let range) = inline else { return nil }
                return String(source[range])
            }.joined()
            let rows = max(1, text.split(separator: "\n", omittingEmptySubsequences: false).count)
            own = Double(rows) * lineHeight
        case .heading(let level):
            let scale = level == 1 ? 1.4 : (level == 2 ? 1.2 : 1.0)
            own = lineHeight * scale
        default:
            own = wrapped(plain(block.inlines, in: source))
        }
        return own + block.children.reduce(0) { $0 + height(of: $1, in: source) }
    }

    private func wrapped(_ text: String) -> Double {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        let perLine = max(1, Int(width / max(charWidth, 1)))
        let rows = trimmed.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) { sum, line in
            sum + max(1, (line.count + perLine - 1) / perLine)
        }
        return Double(rows) * lineHeight
    }

    private func plain(_ inlines: [MarkdownInline], in source: String) -> String {
        inlines.map { inline -> String in
            switch inline {
            case .text(let range), .code(_, let range, _), .math(_, let range, _):
                return String(source[range])
            case .strong(_, let content, _), .emphasis(_, let content, _):
                return plain(content, in: source)
            case .link(_, let label, _, _, _):
                return plain(label, in: source)
            }
        }.joined()
    }
}
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `swift test --filter MarkdownMeasureTests`

Expected: PASS. A fence of two content lines is 40. An 80-word paragraph at 7pt characters in a 360pt width is more than one 20pt row.

- [ ] **Step 5: Commit**

```bash
git add Sources/SwiftMindCore/Markdown/MarkdownMeasure.swift Tests/SwiftMindCoreTests/MarkdownMeasureTests.swift
git commit -m "feat(markdown): estimate note height from the AST"
```

---

### Task 7: Layout override

**Files:**
- Modify: `Sources/SwiftMindCore/Layout/LayoutEngine.swift` (`layout` and `measure`)
- Modify: `Tests/SwiftMindCoreTests/LayoutEngineTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `LayoutEngineTests`. Build a map whose root note is expanded and whose body is one short paragraph. The default expanded height is the guess. Pass `measuredNoteHeights: [root.id: 80]` and assert the root frame height is 80. Pass `900` and assert the height is `LayoutConfig().expandedNoteMaxHeight` (400), not 900.

Use the existing test helpers in that file for `MindMap` construction. Set `root.isNoteExpanded = true` and `root.noteMarkdown = "hello"` before layout. `LayoutEngine.layout` gains a third parameter with a default, so every existing call still compiles.

- [ ] **Step 2: Run the test and confirm it fails**

Run: `swift test --filter LayoutEngineTests.testMeasuredNoteHeightOverridesGuess`

Expected: FAIL, extra argument not accepted, or the height is the guess rather than 80.

- [ ] **Step 3: Honor the override inside `measure`**

```swift
public func layout(
    map: MindMap,
    selection: SelectionState = SelectionState(),
    measuredNoteHeights: [NodeID: Double] = [:]
) -> MapSnapshot {
```

Store `measuredNoteHeights` in a local used by `measure`. Thread it through the private layout methods that call `measure` by reading it from a property set at the start of `layout`:

```swift
private var measuredNoteHeights: [NodeID: Double] = [:]
```

Set it on entry to `layout` and clear nothing on exit (the value is only an input). In the expanded-note branch of `measure`:

```swift
let guess = MarkdownMeasure(
    width: config.expandedNoteWidth,
    charWidth: max(config.charWidth, style.fontSize * 0.55),
    lineHeight: config.expandedNoteLineHeight,
    imageHeight: config.mediaMaxSize
).height(of: node.noteMarkdown) + config.expandedNoteLineHeight + config.paddingX * 2
let raw = measuredNoteHeights[node.id] ?? max(config.nodeHeight, guess)
var h = min(config.expandedNoteMaxHeight, raw)
```

`LayoutConfig` has no `charWidth`. Use `style.fontSize * 0.55` as the only character width. Do not add a `charWidth` property.

Keep the formula-badge addition that already follows this branch.

- [ ] **Step 4: Run layout tests and confirm they pass**

Run: `swift test --filter LayoutEngineTests`

Expected: PASS. Existing layout tests stay on the guess because they pass no override.

- [ ] **Step 5: Commit**

```bash
git add Sources/SwiftMindCore/Layout/LayoutEngine.swift Tests/SwiftMindCoreTests/LayoutEngineTests.swift
git commit -m "feat(layout): override expanded-note height when measured"
```

---

### Task 8: MapStore remembers one measurement

**Files:**
- Modify: `Sources/SwiftMindCore/Store/MapStore.swift`
- Modify: `Tests/SwiftMindCoreTests/MapStoreTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
func testMeasuredNoteHeightRelayoutsOnce() {
    var map = MindMap(title: "t")
    map.root.isNoteExpanded = true
    map.root.noteMarkdown = "hello"
    let store = MapStore(map: map)
    let before = store.snapshot().nodes[0].frame.height
    store.updateMeasuredNoteHeight(80, for: map.root.id)
    let after = store.snapshot().nodes[0].frame.height
    XCTAssertEqual(after, 80)
    XCTAssertNotEqual(after, before)
    let revision = store.contentRevision
    store.updateMeasuredNoteHeight(80.4, for: map.root.id)
    XCTAssertEqual(store.contentRevision, revision)
    XCTAssertEqual(store.snapshot().nodes[0].frame.height, 80)
}
```

Adjust the node lookup if `snapshot().nodes[0]` is not the root. Find the node with `map.root.id`.

- [ ] **Step 2: Run the test and confirm it fails**

Run: `swift test --filter MapStoreTests.testMeasuredNoteHeightRelayoutsOnce`

Expected: FAIL, `updateMeasuredNoteHeight` is missing.

- [ ] **Step 3: Store heights and pass them into layout**

```swift
public private(set) var noteCardHeights: [NodeID: Double] = [:]

public func updateMeasuredNoteHeight(_ height: Double, for id: NodeID) {
    guard height > 0, map.node(id: id) != nil else { return }
    let capped = min(height, layoutEngine.config.expandedNoteMaxHeight)
    if let existing = noteCardHeights[id], abs(existing - capped) <= 1 { return }
    noteCardHeights[id] = capped
    invalidateGeometry()
    contentRevision &+= 1
}
```

`geometrySnapshot` calls:

```swift
layoutEngine.layout(map: map, selection: SelectionState(), measuredNoteHeights: noteCardHeights)
```

Clear `noteCardHeights` at the start of `dispatch` (content changed) and in the `layoutConfig` setter before `invalidateGeometry`. Do not clear it inside `invalidateGeometry`, or the override would erase itself.

- [ ] **Step 4: Run the test and confirm it passes**

Run: `swift test --filter MapStoreTests.testMeasuredNoteHeightRelayoutsOnce`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SwiftMindCore/Store/MapStore.swift Tests/SwiftMindCoreTests/MapStoreTests.swift
git commit -m "feat(store): keep measured note-card heights for one relayout"
```

---

### Task 9: App measures the rendered card

**Files:**
- Create: `Apps/SwiftMindMac/SwiftMindMac/Markdown/NoteCardMeasurer.swift`
- Modify: `Apps/SwiftMindMac/SwiftMindMac/MapCanvasView.swift` (expanded-card branch)

- [ ] **Step 1: Write the measurer**

```swift
import SwiftUI
import SwiftMindCore

enum NoteCardMeasurer {
    /// Height in points of the rendered note at `width`, using the same view
    /// as the card. Zero means the host could not measure.
    @MainActor
    static func height(markdown: String, width: CGFloat, fontSize: CGFloat, maxImageHeight: CGFloat) -> CGFloat {
        let root = MarkdownTextView(markdown: markdown, fontSize: fontSize, maxImageHeight: maxImageHeight)
            .frame(width: width, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
        let host = NSHostingView(rootView: root)
        host.frame.size = CGSize(width: width, height: 1)
        host.layoutSubtreeIfNeeded()
        let fitted = host.fittingSize.height
        return fitted.isFinite && fitted > 0 ? fitted : 0
    }
}
```

- [ ] **Step 2: Call it when an expanded card's document changes**

In `MapCanvasView`, where the expanded note card is built, add `.onAppear` and `.onChange(of: document)` that call `session.store.updateMeasuredNoteHeight(Double(measured), for: visual.id)`. Measure with width `session.store.layoutConfig.expandedNoteWidth` and `maxImageHeight` equal to `mediaImageHeight`. The document string is the one `noteCard` already renders.

A measurement within 1 point of the stored height does not bump `contentRevision` (Task 8), so this cannot loop.

- [ ] **Step 3: Build the app**

Run: `./scripts/rerun-mac.sh --no-test --no-launch`

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add Apps/SwiftMindMac/SwiftMindMac/Markdown/NoteCardMeasurer.swift Apps/SwiftMindMac/SwiftMindMac/MapCanvasView.swift
git commit -m "feat(mac): measure expanded note cards and feed layout"
```

---

### Task 10: Display projection hides markers

**Files:**
- Create: `Tests/SwiftMindCoreTests/MarkdownDisplayTests.swift`
- Create: `Sources/SwiftMindCore/Markdown/MarkdownDisplay.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import SwiftMindCore

final class MarkdownDisplayTests: XCTestCase {
    func testBoldMarkersHidden() {
        let display = MarkdownDisplay.project("Ship **Friday**.", reveal: .none)
        XCTAssertEqual(display.text, "Ship Friday.")
        XCTAssertFalse(display.text.contains("*"))
        XCTAssertEqual(display.sourceUTF16.count, display.text.utf16.count)
    }

    func testHeadingMarkersHidden() {
        let display = MarkdownDisplay.project("## title2\n", reveal: .none)
        XCTAssertEqual(display.text, "title2\n")
    }

    func testImageBecomesObjectCharacter() {
        let display = MarkdownDisplay.project("![sketch](data:image/png;base64,QQ==)", reveal: .none)
        XCTAssertEqual(display.text, "\u{FFFC}")
    }
}
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `swift test --filter MarkdownDisplayTests.testBoldMarkersHidden`

Expected: FAIL, `cannot find 'MarkdownDisplay' in scope`.

- [ ] **Step 3: Project blocks to a display string and a UTF-16 map**

```swift
public struct MarkdownDisplay: Equatable, Sendable {
    public var text: String
    /// Source UTF-16 offset for each UTF-16 unit of `text`.
    public var sourceUTF16: [Int]

    public enum Reveal: Equatable, Sendable {
        case none
        case inline(Range<String.Index>)
        case block(Range<String.Index>)
    }

    public static func project(_ source: String, reveal: Reveal) -> MarkdownDisplay {
        var text = ""
        var map: [Int] = []
        let doc = MarkdownDocument.parse(source)
        for block in doc.blocks {
            project(block, source: source, reveal: reveal, into: &text, map: &map)
        }
        return MarkdownDisplay(text: text, sourceUTF16: map)
    }
}
```

Append helper on `String`: UTF-16 offset of an index via `utf16.distance(from: utf16.startIndex, to: index.samePosition(in: utf16)!)`. When appending a source slice, append each of its UTF-16 units to `text` and the corresponding source offset to `map`.

For `.none`:

- Paragraph, heading, list item, quote: append the plain inline text. Strong, emphasis, and link contribute their inner text. Code contributes its content. Math contributes its latex. Then append `\n` mapped to the block's last source offset if the block's source contains a newline or another block follows.
- Image: append `\u{FFFC}` mapped to the alt range's start.
- Code fence and math block: append the raw body text (the `.text` inline), not the delimiter lines.

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `swift test --filter MarkdownDisplayTests`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SwiftMindCore/Markdown/MarkdownDisplay.swift Tests/SwiftMindCoreTests/MarkdownDisplayTests.swift
git commit -m "feat(markdown): project a rendered display string"
```

---

### Task 11: Reveal and splice

**Files:**
- Modify: `Tests/SwiftMindCoreTests/MarkdownDisplayTests.swift`
- Modify: `Sources/SwiftMindCore/Markdown/MarkdownDisplay.swift`

- [ ] **Step 1: Write the failing tests**

```swift
func testRevealStrongShowsMarkers() {
    let source = "Ship **Friday**."
    let doc = MarkdownDocument.parse(source)
    guard case .strong(_, let content, _) = doc.blocks[0].inlines[1],
          case .text(let range) = content[0] else {
        return XCTFail("missing strong")
    }
    let display = MarkdownDisplay.project(source, reveal: .inline(range))
    XCTAssertEqual(display.text, "Ship **Friday**.")
}

func testRevealHeadingPrefix() {
    let source = "## title2\n"
    let doc = MarkdownDocument.parse(source)
    let display = MarkdownDisplay.project(source, reveal: .block(doc.blocks[0].marker))
    XCTAssertEqual(display.text, "## title2\n")
}

func testSpliceInsertsIntoMarkdown() {
    let source = "Ship Friday."
    let previous = MarkdownDisplay.project(source, reveal: .none)
    let inserted = previous.splicing(source: source, displayReplacement: "X", displayUTF16: 5..<5)
    XCTAssertEqual(inserted, "Ship XFriday.")
}
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `swift test --filter MarkdownDisplayTests.testRevealStrongShowsMarkers`

Expected: FAIL, reveal is ignored.

- [ ] **Step 3: Reveal one span, and splice a display edit back into markdown**

When `reveal` is `.inline(range)` and an inline's content range equals that range, append its open marker, its content, and its close marker from the source instead of the plain text.

When `reveal` is `.block(range)` and `block.marker == range` (or `block.source == range` for an image), append `String(source[block.source])` with a 1:1 UTF-16 map and do not also append the rendered form.

```swift
public func splicing(source: String, displayReplacement: String, displayUTF16: Range<Int>) -> String {
    let start = displayUTF16.lowerBound == 0 ? 0 : sourceUTF16[displayUTF16.lowerBound - 1] + 1
    let end = displayUTF16.upperBound < sourceUTF16.count ? sourceUTF16[displayUTF16.upperBound] : source.utf16.count
    let ns = source as NSString
    return ns.replacingCharacters(
        in: NSRange(location: start, length: end - start),
        with: displayReplacement
    )
}
```

Insertion at the caret uses a zero-length `displayUTF16`. The character lands at the source offset of the unit before the caret, plus one. Deletion uses the source offsets covered by the deleted units.

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `swift test --filter MarkdownDisplayTests`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SwiftMindCore/Markdown/MarkdownDisplay.swift Tests/SwiftMindCoreTests/MarkdownDisplayTests.swift
git commit -m "feat(markdown): reveal one span and splice display edits"
```

---

### Task 12: Editor shows the projection

**Files:**
- Modify: `Apps/SwiftMindMac/SwiftMindMac/Markdown/MarkdownEditorView.swift`

The binding `text` remains the markdown source. The text view's `string` is `MarkdownDisplay.text`. Do not call `MarkdownStyler`.

- [ ] **Step 1: Project on open and on external markdown changes**

In `setText`, when the markdown argument differs from the last markdown the coordinator stored:

```swift
let display = MarkdownDisplay.project(text, reveal: reveal)
textView.string = display.text
sourceMap = display.sourceUTF16
markdown = text
```

`reveal` is `MarkdownDisplay.Reveal`, stored on the coordinator, default `.none`. Place the caret at the end of the display on open.

- [ ] **Step 2: User edits splice back into markdown**

In `textDidChange`, if the change was not programmatic:

```swift
let edited = textView.string
let range = textView.selectedRange()
let updated = MarkdownDisplay(
    text: lastDisplay,
    sourceUTF16: sourceMap
).splicing(
    source: markdown,
    displayReplacement: editedSubstring,
    displayUTF16: changedUTF16
)
markdown = updated
parent.text = updated
let next = MarkdownDisplay.project(updated, reveal: reveal)
textView.string = next.text
sourceMap = next.sourceUTF16
lastDisplay = next.text
```

`changedUTF16` is the range `NSTextView` reports through the coordinator's stored selection from `textViewDidChangeSelection` compared with the new string. Compute it as the first and last UTF-16 units that differ between `lastDisplay` and `edited`, then exclude the common suffix. Set `isProgrammaticUpdate` around the `string` assignment so the splice does not run again.

After the projection, put the caret at the display UTF-16 offset whose `sourceUTF16` entry is the markdown caret. The markdown caret is `start + displayReplacement.utf16.count` from the splice.

- [ ] **Step 3: Reveal follows the caret**

In `textViewDidChangeSelection`, map the caret's display offset through `sourceUTF16` to a source UTF-16 offset, then to a `String.Index`. Walk `MarkdownDocument.parse(markdown)`:

- If the index is inside an inline content range, `reveal = .inline(thatRange)`.
- If the index is inside a block marker, `reveal = .block(marker)`.
- If the index is on an image's object character, `reveal = .block(block.source)`.
- Otherwise `reveal = .none`.

Reproject only when `reveal` changes. Keep the markdown caret stable.

- [ ] **Step 4: Build**

Run: `./scripts/rerun-mac.sh --no-test --no-launch`

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add Apps/SwiftMindMac/SwiftMindMac/Markdown/MarkdownEditorView.swift
git commit -m "feat(notes): editor displays rendered markdown and reveals the caret span"
```

---

### Task 13: Shortcuts edit markdown

**Files:**
- Modify: `Apps/SwiftMindMac/SwiftMindMac/Markdown/MarkdownEditorView.swift` (`keyDown`)
- Modify: `Tests/SwiftMindCoreTests/MarkdownDisplayTests.swift` (wrap helper, if the wrap is pure)

Put the wrap in core so it is tested without AppKit.

- [ ] **Step 1: Write the failing tests**

```swift
func testWrapStrong() {
    XCTAssertEqual(MarkdownDisplay.wrap("Friday", rangeUTF16: 0..<6, marker: "**"), "**Friday**")
}

func testUnwrapStrong() {
    XCTAssertEqual(MarkdownDisplay.wrap("**Friday**", rangeUTF16: 2..<8, marker: "**"), "Friday")
}

func testSetHeadingLevel() {
    XCTAssertEqual(MarkdownDisplay.setHeading("## title2", level: 3), "### title2")
    XCTAssertEqual(MarkdownDisplay.setHeading("title2", level: 3), "### title2")
}
```

`setHeading` finds the block containing UTF-16 offset 0 of the selection the editor will pass. The test passes the whole string and expects the first block's marker rewritten. A paragraph becomes a heading. A heading changes level. The rest of the string is preserved.

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `swift test --filter MarkdownDisplayTests.testWrapStrong`

Expected: FAIL, `wrap` is missing.

- [ ] **Step 3: Implement wrap and heading, and bind the keys**

```swift
public static func wrap(_ source: String, rangeUTF16: Range<Int>, marker: String) -> String {
    let ns = source as NSString
    let range = NSRange(location: rangeUTF16.lowerBound, length: rangeUTF16.count)
    let m = marker as NSString
    if range.location >= m.length,
       range.location + range.length + m.length <= ns.length,
       ns.substring(with: NSRange(location: range.location - m.length, length: m.length)) == marker,
       ns.substring(with: NSRange(location: range.location + range.length, length: m.length)) == marker {
        let outer = NSRange(location: range.location - m.length, length: range.length + m.length * 2)
        return ns.replacingCharacters(in: outer, with: ns.substring(with: range))
    }
    return ns.replacingCharacters(in: range, with: marker + ns.substring(with: range) + marker)
}

public static func setHeading(_ source: String, level: Int) -> String {
    let clamped = min(6, max(1, level))
    let prefix = String(repeating: "#", count: clamped) + " "
    let doc = MarkdownDocument.parse(source)
    guard let block = doc.blocks.first else { return prefix + source }
    let ns = source as NSString
    let marker = NSRange(
        block.marker,
        in: source
    ) ?? NSRange(location: 0, length: 0)
    if case .heading = block.kind {
        return ns.replacingCharacters(in: marker, with: prefix)
    }
    let start = NSRange(block.source, in: source)?.location ?? 0
    return ns.replacingCharacters(in: NSRange(location: start, length: 0), with: prefix)
}
```

`NSRange(_:in:)` needs the range converted from `Range<String.Index>`. Use `NSRange(range, in: source)`.

In `MarkdownSourceTextView.keyDown`, keep Return / Tab / `⌘B` / `⌘I`. `⌘B` and `⌘I` call a new `onFormat: ((String) -> Void)?` with `"**"` or `"*"` instead of `toggleWrap` on the display string. The coordinator wraps `markdown` with `MarkdownDisplay.wrap` over the selection's source range and assigns `parent.text`.

Add `⌘K` (key code 40): wrap the selection as a link by replacing the source selection with `[selection](url)` and set `reveal` to that new link's label range.

Add `⌘⌥1`, `⌘⌥2`, `⌘⌥3` (key codes 18, 19, 20 with command and option): `MarkdownDisplay.setHeading(markdown, level:)` on the block that contains the caret, assign `parent.text`.

- [ ] **Step 4: Run the tests and build**

Run: `swift test --filter MarkdownDisplayTests && ./scripts/rerun-mac.sh --no-test --no-launch`

Expected: tests PASS and `BUILD SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add Sources/SwiftMindCore/Markdown/MarkdownDisplay.swift Tests/SwiftMindCoreTests/MarkdownDisplayTests.swift Apps/SwiftMindMac/SwiftMindMac/Markdown/MarkdownEditorView.swift
git commit -m "feat(notes): bold, italic, link, and heading shortcuts edit markdown"
```

---

### Task 14: Read-only cards use the same document

**Files:**
- Modify: `Apps/SwiftMindMac/SwiftMindMac/Markdown/MarkdownTextView.swift`

- [ ] **Step 1: Build blocks from `MarkdownDocument`**

Replace `MarkdownTextView.blocks(from:)` so it walks `MarkdownDocument.parse(markdown).blocks` instead of its private line scanner.

- Heading → `.header(level:pieces:)`. Pieces come from inlines: `.text` and the plain content of strong, emphasis, code, and link go to `.text`. `.math` goes to `.inlineMath`.
- List item → `.listItem` with marker `•`, `1.`, or `☑` / `☐` from `checked`. Indent is the block's indent.
- Quote, code fence, math block, image map onto the existing `Block` cases.
- Nested list items are emitted after their parent, in order, so the card shows the child under the parent.

Leave `AttributedString(markdown:)` for inline emphasis inside a piece only if the piece still contains markers. After this task the pieces are plain, and strong/emphasis are separate pieces the existing `piecesView` already styles through SwiftUI markdown. Pass strong content wrapped in `**` inside the piece string so the current `AttributedString` path keeps rendering bold without a second styling pass. That keeps one renderer.

- [ ] **Step 2: Build**

Run: `swift test --filter MarkdownDocumentTests && ./scripts/rerun-mac.sh --no-test --no-launch`

Expected: PASS and `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add Apps/SwiftMindMac/SwiftMindMac/Markdown/MarkdownTextView.swift
git commit -m "feat(notes): render read-only cards from the markdown AST"
```

---

### Task 15: UI tests

**Files:**
- Modify: `Apps/SwiftMindMac/SwiftMindMac/MapCanvasView.swift` (card identifier, if the expanded card has none)
- Modify: `Apps/SwiftMindMac/SwiftMindMacUITests/SwiftMindMacUITests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
func testNoteEditorHidesBoldMarkers() throws {
    focusCanvasWithSelection()
    app.typeKey(.init("e"), modifierFlags: [])
    let editor = element("noteEditor")
    XCTAssertTrue(editor.waitForExistence(timeout: 3))
    editor.click()
    app.typeKey(.downArrow, modifierFlags: .command)
    editor.typeText("**x**")
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    let value = (editor.value as? String) ?? ""
    XCTAssertFalse(value.contains("*"), "rendered display hides ** — got \(value)")
    XCTAssertTrue(value.contains("x"))
    app.typeKey(.return, modifierFlags: .command)
    XCTAssertTrue(waitForScratchMap { $0.contains("**x**") }, "file still stores the markers")
}

func testExpandedCardIsTallerThanOneLine() throws {
    focusCanvasWithSelection()
    app.typeKey(.init("e"), modifierFlags: [])
    let editor = element("noteEditor")
    XCTAssertTrue(editor.waitForExistence(timeout: 3))
    editor.click()
    app.typeKey(.downArrow, modifierFlags: .command)
    editor.typeText(String(repeating: "word ", count: 80))
    app.typeKey(.return, modifierFlags: .command)
    app.typeKey(.init("x"), modifierFlags: [])
    let card = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'noteCard-'")).firstMatch
    XCTAssertTrue(card.waitForExistence(timeout: 3))
    RunLoop.current.run(until: Date().addingTimeInterval(1.0))
    XCTAssertGreaterThan(card.frame.height, 40)
    XCTAssertLessThanOrEqual(card.frame.height, 420)
}
```

The card identifier `noteCard-<id>` already exists on the expanded card. Do not add a second one.

- [ ] **Step 2: Run the tests**

Run: `cd Apps/SwiftMindMac && xcodebuild -scheme SwiftMindMac -destination 'platform=macOS' -only-testing:SwiftMindMacUITests/SwiftMindMacUITests/testNoteEditorHidesBoldMarkers -only-testing:SwiftMindMacUITests/SwiftMindMacUITests/testExpandedCardIsTallerThanOneLine CODE_SIGN_IDENTITY=- test`

Expected: both PASS. If the display still shows `**x**`, the editor is still binding the text view to the raw markdown; fix Task 12, do not weaken the assertion.

- [ ] **Step 3: Commit**

```bash
git add Apps/SwiftMindMac/SwiftMindMacUITests/SwiftMindMacUITests.swift
git commit -m "test(notes): rendered bold hides marks; expanded card uses measured height"
```

---

### Task 16: Docs

**Files:**
- Modify: `README.md` (the Markdown note documents bullet)
- Modify: `Apps/SwiftMindMac/SwiftMindMac/Resources/help-map.ops.json` (the `n_help_notes` note)
- Modify: `docs/superpowers/specs/2026-09-21-note-editing-ux-design.md` (delete the three non-goals this spec reverses, and point at `2026-09-21-wysiwyg-notes-design.md`)

- [ ] **Step 1: Update the copy**

README sentence to add after the existing note-editor sentence: the editor shows the formatted note; typing Markdown renders it; the marks for the piece under the caret come back; the file stays Markdown. Expanded cards use the rendered height up to the existing maximum.

Help-map note: one sentence of the same fact. Then run `./scripts/make-help-map.sh`.

- [ ] **Step 2: Regenerate and test**

Run: `./scripts/make-help-map.sh && swift test --filter HelpMapConsistencyTests`

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add README.md Apps/SwiftMindMac/SwiftMindMac/Resources/help-map.ops.json "Apps/SwiftMindMac/SwiftMindMac/Resources/Welcome to SwiftMind.swiftmind.html" docs/superpowers/specs/2026-09-21-note-editing-ux-design.md
git commit -m "docs: WYSIWYG notes keep markdown on disk and measure card height"
```

---

## Spec coverage

| Spec requirement | Task |
|---|---|
| Rendered editor, markdown on disk | 12, 15 |
| Type markdown, marks hide | 10, 12, 15 |
| Reveal inline, link, image, math, fence, line-start | 11, 12 |
| `⌘B` `⌘I` `⌘K` `⌘⌥1..3` | 13 |
| List, Tab, Esc, `⌘Enter`, click-away unchanged | 12 (does not replace those paths) |
| Both hosts | 12 (one `MarkdownEditorView`) |
| AST, source ranges, subset, dollar amounts, unmatched opener | 1–5 |
| Segmenter tests still pass | do not change `MarkdownSegmenter` |
| Parser height guess | 6, 7 |
| In-memory override, cap, one relayout | 7, 8, 9 |
| Read-only card uses the AST | 14 |
| No HTML in the file, virtual H1 kept | 12 commits `parent.text` markdown only |
| No tables, footnotes, image drag, host removal | not tasks |

## Self-review

- Placeholder scan: no TBD, no "handle edge cases", no "similar to Task N".
- `MarkdownDisplay.Reveal`, `sourceUTF16`, `wrap`, `setHeading`, `splicing`, `MarkdownMeasure.height(of:)`, and `MapStore.updateMeasuredNoteHeight` are spelled the same way in every task that uses them.
- `listItem(ordered:checked:indent:)` matches the tests in Task 3 and `nestLists`.
- Image kind carries `alt` and `url` ranges, matching Task 4.
- Layout override is capped with `expandedNoteMaxHeight` in both `LayoutEngine` and `MapStore`.
