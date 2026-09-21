# Note-editing UX revamp — design (2026-09-21)

User-approved scope: all of P0, all of P1, P2 item 8 (on-card editing as an
*additional* mode — current editor stays so both can be compared; user will
later decide which to keep), P2 item 9 (insertion helpers).

## Phase 1 — P0: commit/cancel semantics, honest ⌘E, card overflow

### 1a. Esc cancels, ⌘Enter commits, click-away commits & closes

Current behavior: Esc commits; every close path commits; clicking other
nodes leaves the editor open.

New behavior for the note-editor overlay (`MapCanvasView`):

- `Esc` = **cancel**: close the editor and revert the node to the
  last-committed document at editor-open time (the "session baseline").
  Because the debounced commit may already have dispatched intermediate
  ops, cancel dispatches a reverting `CompositeAgentCommand`
  (setText/setNote back to baseline) when the model diverged — this keeps
  the revert itself undoable and never touches unrelated edits.
- `⌘Enter` = commit & close (discoverable shortcut, standard in macOS
  notes/mail compose).
- Clicking blank canvas or another node = commit & close (the editor was
  the only surface that ignored click-away).
- Editor title bar / existing Done affordance unchanged (commits).

### 1b. Honest ⌘E

`beginEdit(nodeID:)` currently opens the note editor only when a Markdown
body already exists, else falls back to title editing. New: ⌘E / "Edit
Note at Node" **always** opens the note editor in place (empty body shows
title-only virtual document). Plain title editing stays on Return and
double-click-on-title. Sketch nodes still route to the sketch editor.

### 1c. Expanded card overflow

Card height stays estimated in layout (core stays UI-free), but the card
view becomes scrollable when the rendered content exceeds the frame
instead of hard-clipping. Estimator accuracy improved for code fences and
images (image lines cost one media-size row). True two-pass measured
heights are explicitly out of scope (would require feeding AppKit text
measurement back into the core layout).

## Phase 2 — P1: styled editor, typing aids, undo coalescing

### 2a. Live-styled editor

Replace the plain SwiftUI `TextEditor` with a thin `NSViewRepresentable`
wrapper around `NSTextView` (`MarkdownEditorView`) that applies *styling
only* (not layout changes): headings larger/bold, bold/italic spans,
inline code in monospace with subtle background, list markers dimmed,
code fences monospace block background. Styling recomputed per text change
from `MarkdownSegmenter` spans + a lightweight inline pass; text storage
stays the plain Markdown source — what you type is what persists.

### 2b. Typing aids

In `MarkdownEditorView`:

- Return inside a `- ` / `* ` / `1. ` list line continues the marker;
  Return on an empty marker line removes it (standard outliner behavior).
- `⌘B` / `⌘I` toggle `**` / `*` around the selection (or place markers
  when nothing selected).
- `Tab` / `⇧Tab` indent / outdent list lines instead of moving focus.

### 2c. Undo coalescing per editing session

All debounced commits during one editor-open session dispatch through a
single coalescing command: the first commit of the session records the
baseline; later bursts update the same undo step (redo stack unaffected —
closing the editor ends the coalescing group). Map-level ⌘Z then reverts
the *whole* editing session in one step. Text-level ⌘Z while focused is
unchanged (NSTextView's own undo manager).

## Phase 3 — P2: on-card editing mode + insertion helpers

### 3a. On-card editing (second mode, for UX comparison)

New Settings key `swiftmind.noteEditMode`: `panel` (default, current
floating/in-place editor) | `onCard`.

- When `onCard`: double-clicking an expanded note card (or pressing
  ⌘E/`e` on a node with expanded note) turns the card itself into the
  editor — the `MarkdownEditorView` hosted at the card's frame, styled as
  the card, committing to the same note pipeline (debounce, coalesced
  undo, Esc cancel, ⌘Enter commit).
- Cards of non-expanded nodes behave as today; `x` still toggles
  expansion. Both modes share the commit machinery from Phase 1/2 — only
  the host view differs.
- Settings UI: a picker under a new "Notes" section. Default stays
  `panel`; the user compares and decides later whether to keep both.

### 3b. Insertion helpers

A small toolbar row on the note editor (both modes): insert image (file
picker → data-URI Markdown line), insert inline/block math template
(`$…$` / `$$…$$`), insert link (`[title](url)` with selected text as
title). All insertions are plain Markdown text at the caret — no new
model concepts.

## Testing

- Core: no model changes; existing codec/segmenter tests keep passing.
- App: UI tests for — Esc cancels (note unchanged), ⌘Enter commits,
  click-away commits & closes, ⌘E opens note editor on a noteless node,
  card scrolls instead of clipping, typing aids (list continuation,
  ⌘B toggle), undo coalescing (one ⌘Z reverts a session), on-card mode
  opens/commits, insert helpers write Markdown at caret.
- `./scripts/verify.sh` green per phase before commit.

## Non-goals

- True WYSIWYG persistence (rendered HTML in the file) — notes stay raw
  Markdown.
- Measured two-pass card heights (see 1c).
- Syntax-aware Markdown parsing beyond the existing segmenter/inline pass.
