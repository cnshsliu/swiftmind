# SwiftMind M4 Implementation Plan (Computation / 1.x)

> **For agentic workers:** Use subagent-driven-development or execute task-by-task. Checkboxes track progress.

**Goal:** Ship live computation on maps: **L0 built-in aggregates** (sum, count, completion %) and **L1 safe node formulas** (restricted expression DSL), with dependency-aware recomputation and inspector UX. Results are *derived data* — they never mutate the model and never execute arbitrary code. L2 rules and L3 scripts stay out of scope (M5).

**Architecture (follows spec §7):** a `Formula/` layer in `SwiftMindCore` — tokenizer + recursive-descent parser producing an AST, an evaluator that reads nodes/attributes/children, and a result cache keyed by `contentRevision`. Formulas are stored on nodes (`Node.formula: String?`) and persist via an additive HTML `data-formula` attr (schema stays **1**). All user edits still go through commands (`SetFormulaCommand`); evaluation happens lazily off the store, like layout.

**Tech Stack:** Existing Swift 5.10 / SPM / SwiftUI / XCTest / XCUITest. No external dependencies (hand-rolled parser, no regex-eval hacks).

**Out of scope:** L2 declarative rules, L3 sandboxed JS, cross-map references, formula-driven styles/filters, scripting API.

---

## Design decisions

- **Formulas are strings on nodes, results are derived.** `Node.formula` is the only model change; computed values live in a `FormulaResults` cache inside `MapStore` (invalidated on `contentRevision` bump, same seam as the geometry cache).
- **Aggregates roll up, so dependencies are ancestors.** When a node changes, only formulas on its ancestor path (plus its own) can be affected — recompute that path, not the whole map.
- **Errors are values.** Any parse/eval failure yields `.error(String)` shown as e.g. `#ERR: unknown attribute "cost"` — never a crash, never a hidden stale value.
- **L0 is syntax sugar over the same evaluator.** `=sum(children, attr: cost)`, `=count(children)`, `=progress()` are L1 function calls; "L0" is the UI affordance (one-click aggregate picker) that writes them.
- **Completion %** convention: `=progress()` counts descendants whose icon is a checkmark (existing icon vocabulary) — document the exact rule in README when implemented.

## DSL v1 (L1)

```text
literals      42  3.14  "text"  true false
attribute     attr("cost")            → number|string|bool, error if missing
aggregates    sum(children, attr: "cost")
              count(children)
              avg|min|max(children, attr: "cost")
              progress()
arithmetic    + - * / %  (unary -)
comparison    == != < <= > >=
boolean       and or not
conditional   if(cond, then, else)
parentheses   ( )
```

No variables, no loops, no node-by-id lookup, no string concatenation in v1 (add only if a real map needs it).

---

## File map (M4)

```text
Sources/SwiftMindCore/
  Formula/
    FormulaLexer.swift           # NEW — tokens
    FormulaParser.swift          # NEW — recursive descent → FormulaAST
    FormulaAST.swift             # NEW — expression tree, Equatable
    FormulaEvaluator.swift       # NEW — AST + EvalContext → FormulaValue
    FormulaValue.swift           # NEW — number|string|bool|error
    FormulaEngine.swift          # NEW — cache + ancestor-path invalidation
  Model/
    Node.swift                   # + formula: String?
  Commands/
    SetFormulaCommand.swift      # NEW (set/clear, undoable)
  HTML/HTMLCodec.swift           # data-formula encode/decode (schema 1 additive)
  Store/MapStore.swift           # + formulaResults view, recompute on contentRevision

Apps/SwiftMindMac/SwiftMindMac/
  InspectorView.swift            # formula field + live result / #ERR display
  AggregatePicker.swift          # NEW — L0 one-click sum/count/progress
  MapCanvasView.swift            # computed badge on node (e.g. "Σ 1,240")
  OutlineMapView.swift           # same badge in outline

Tests/SwiftMindCoreTests/
  FormulaLexerTests.swift
  FormulaParserTests.swift
  FormulaEvaluatorTests.swift
  FormulaEngineTests.swift       # invalidation, undo, cycles-impossible proof
  HTMLCodecTests.swift           # + formula round-trip
```

---

### Task 1: Lexer + parser + AST

- [x] `FormulaLexer` — numbers, strings, identifiers, operators, keywords (`attr`, `children`, `and`, `or`, `not`, `if`, `true`, `false`)
- [x] `FormulaAST` — expression tree with correct precedence (`or` < `and` < comparison < additive < multiplicative < unary < call/atom)
- [x] `FormulaParser` — recursive descent; position-annotated errors (`unexpected ")" at 12`)
- [x] Lexer/parser unit tests incl. malformed input

### Task 2: Evaluator

- [x] `FormulaValue` with numeric coercion rules (string→number only if parseable, else error)
- [x] `FormulaEvaluator.evaluate(ast, node)` — attribute lookup, aggregates over `children`, arithmetic/comparison/boolean, `if`
- [x] Division by zero, unknown attribute, wrong arity, type mismatch → `.error`
- [x] Unit tests for every DSL production + error case

### Task 3: Model + command + HTML persistence

- [ ] `Node.formula: String?`
- [ ] `SetFormulaCommand` (set / clear via nil), undoable
- [ ] HTML: `data-formula="..."` escaped on encode; decode tolerant of missing attr (legacy files unaffected)
- [ ] Round-trip test against golden fixture (extended or new fixture node)
- [ ] Note: encode stores the *source string*, not the computed value — the browser skin shows the formula text, never executes anything (spec §5 security posture)

### Task 4: Engine — cache + invalidation

- [ ] `FormulaEngine` in `MapStore`: `results: [NodeID: FormulaValue]`, recomputed lazily
- [ ] On `contentRevision` bump: recompute formulas on the changed node's ancestor path only; aggregates guarantee no other node can depend on the change (assert with a test: sibling edits don't invalidate)
- [ ] `snapshot()` exposes computed values alongside `NodeVisual` (badge text)
- [ ] Depth-guarded recursion (map is a tree, so cycles are structurally impossible — add a test proving ancestor-only dependencies)

### Task 5: Mac UI — inspector

- [ ] Formula section: text field (monospaced), live result, `#ERR` inline with message
- [ ] Editing dispatches `SetFormulaCommand` (undoable), not direct mutation
- [ ] Clear button

### Task 6: Mac UI — L0 aggregate picker + badges

- [ ] Aggregate picker (menu/button in inspector): Sum of attr / Count children / Progress % → inserts the corresponding L1 formula
- [ ] Canvas + outline badge with formatted result (number formatting, e.g. `Σ 1,240` / `75%`)
- [ ] XCUITest smoke: set formula via inspector, badge appears, undo removes it

### Task 7: Verify + docs

- [ ] `swift test` green; `./scripts/verify.sh` green
- [ ] README M4 section: DSL reference + progress() convention
- [ ] AGENTS.md layout/test-count updates if structure changed
- [ ] Tag `m4-complete` when exit criteria met

**M4 exit:** In a real project map, the user puts `=sum(children, attr: "cost")` on a parent, sees a live total badge that updates as children are edited/added/undone, survives save → quit → relaunch, and a broken formula shows a clear `#ERR` instead of corrupting anything.

---

## Implementation order (dependency)

```text
T1 Lexer/Parser → T2 Evaluator
T3 Model/Command/HTML (parallel after T1 — storage only)
T4 Engine (after T2 + T3)
T5 Inspector (after T4)
T6 Aggregate picker + badges (after T5)
T7 Verify + docs
```
