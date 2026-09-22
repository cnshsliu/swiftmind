# WYSIWYG notes, measured cards, Markdown AST — design (2026-09-21)

Status: approved interaction, pending spec review.

Reverses three non-goals in `2026-09-21-note-editing-ux-design.md`. Both
editor hosts stay (Settings `swiftmind.noteEditMode`: `panel` | `onCard`).

## Approved interaction

The editor shows the rendered note. The file still stores Markdown
(`Node.text` + `Node.noteMarkdown`, virtual H1 via `NoteDocument`).

- Typing the Markdown creates the format. A closing pair or a line-start
  marker plus a space renders immediately and the marks leave the screen.
  Undo restores the keystrokes.
- The marks come back only for the piece the caret is inside.
  - Inline (`**` / `*` / `` ` ``): caret inside that span.
  - Link: caret inside the link, or `⌘K`.
  - Image, inline/block math: click the object; that block's source is editable.
  - Code fence: the inside stays raw.
  - Heading, list, quote: caret at the start of the line shows `##`, `-`,
    `>`, or `1.`.
- Shortcuts keep working and never require the marks to be visible:
  `⌘B`, `⌘I`, `⌘K`, `⌘⌥1` / `⌘⌥2` / `⌘⌥3`. List continuation, Tab indent,
  Esc cancel, `⌘Enter` commit, and click-away commit stay as they are.
- Both hosts (floating/in-place panel and on-card) use this editor.

## 1. Markdown AST (core)

`MarkdownSegmenter` stays a facade for math/image splits used by today's
renderer until the new renderer reads the AST. New types in
`Sources/SwiftMindCore/Markdown/`:

- `MarkdownDocument`: ordered blocks, parsed from one string.
- `MarkdownBlock`: `heading(level)` (1...6; the editor's shortcut row is
  1...3), `paragraph`, `listItem(ordered:checked:indent)`, `quote`,
  `codeFence`, `mathBlock`, `image`. A list is a run of items. An item's
  body may contain nested items; each item has its own marker range.
  Each block stores a `Range<String.Index>` into the original string.
  The editor converts that to an `NSRange` with `utf16`.
- `MarkdownInline`: `text`, `strong`, `emphasis`, `code`, `link(title:url)`,
  `image`, `math`. Each inline stores the range of its opening marker, its
  content, and its closing marker. Marker ranges are empty when the
  construct has no delimiter (plain text).

Parser rules match what the app already renders, and nothing more:

- ATX headings, paragraphs, `-` / `*` / `1.` lists (including one or
  more nested levels and `- [ ]` / `- [x]`), block quotes, fenced code
  (`` ``` `` / `~~~`), links, standalone-line images, `$…$` and `$$…$$`.
- Dollar-amount rules from `MarkdownSegmenter` stay: `$5 and $10` is text.
- Marks inside a fence or an inline code span are literal.
- An unmatched opener stays literal text. The parser does not invent a close.

`MarkdownDocument.parse(_:)` is pure and total: it never throws. Unknown
or partial syntax is a paragraph or text run whose source range covers
those characters.

Tests live in `Tests/SwiftMindCoreTests/MarkdownDocumentTests.swift`.
Each case asserts both the kind and the source ranges, including the
marker ranges that the editor reveals.

## 2. Measured card height

Core stays free of AppKit. `LayoutEngine.measure` keeps a parser-based
first guess so a layout exists before any view is on screen. The guess
uses the AST: a heading is one line at its level's line height, a
paragraph wraps at `expandedNoteWidth`, an image is one `mediaMaxSize`
row, a math block is its content rows, a fence is its line count.

The app then measures the real card.

- `MapStore` holds `noteCardHeights: [NodeID: Double]`, not persisted,
  not in the HTML. Cleared when that node's composed document, the media
  size, or `expandedNoteWidth` changes.
- After a card is laid out, the Mac app measures the rendered document at
  `expandedNoteWidth` with the same fonts the card uses and writes the
  height in map points.
- `LayoutEngine.measure` uses the stored height when present, otherwise
  the parser guess. Height is still capped at
  `LayoutConfig.expandedNoteMaxHeight`. Taller notes scroll inside the
  card, as they do today.
- A measurement that differs from the height used for the current layout
  by more than 1 point schedules one more layout. A second measurement
  of the same document does not schedule again.

Core tests cover the guess and the override. The Mac measurement is
covered by a UI test: a wrapped paragraph and an image produce a card
taller than a one-line estimate and shorter than or equal to the cap.

## 3. WYSIWYG editor (app)

`MarkdownEditorView` keeps an `NSTextView`, but the text storage shown
to the user is the rendered document plus the one revealed span or
block. A source map on the coordinator translates display ranges to
markdown ranges and back.

- On each edit, the coordinator rewrites the markdown string, reparses,
  and rebuilds the display. The caret stays on the same markdown offset.
- Reveal: if the caret's markdown offset lies inside an inline's content
  range, that inline's markers are inserted into the display. If it lies
  in a block's marker range (line-start prefix, image line, math
  delimiters), that block is shown as source. Leaving the range removes
  the markers.
- Shortcuts edit the markdown, not the display attributes. `⌘B` wraps or
  unwraps the selection's markdown range in `**`. `⌘⌥3` sets the block's
  heading level to 3. `⌘K` wraps the selection as `[selection](url)` and
  reveals it.
- Image insertion from the existing toolbar still inserts a Markdown
  image line. The picture renders; click reveals `![alt](url)`.
- Commit path is unchanged: debounced `NoteDocument.split` →
  `setText` / `setNote` in one coalesced undo step. Esc reverts to the
  session baseline. The markdown string is what gets committed, never
  the display string.
- `MarkdownStyler` (attributes on the raw source) is removed once the
  display string is the rendered form. Read-only cards
  (`MarkdownTextView`) render from the same `MarkdownDocument` so the
  card and the editor cannot disagree.

## Persistence and non-goals

- HTML schema unchanged. Notes stay Markdown. No rendered HTML in the file.
- Title remains the virtual H1. Deleting the H1 in the editor still does
  not erase `Node.text` (`NoteDocument.split` already returns a nil title).
- No tables, footnotes, raw HTML blocks, or reference-style links.
- No dragging to resize an image. Size stays the Settings media box.
- No removal of either editor host.

## Build order

1. AST parser and range tests. Segmenter tests keep passing.
2. Layout guess from the AST, then the measured-height override.
3. WYSIWYG display, reveal, and shortcuts on both hosts. Read-only cards
   switch to the AST. UI tests for reveal (type `**x**`, marks hide;
   caret inside shows them) and for a measured card taller than one line.
