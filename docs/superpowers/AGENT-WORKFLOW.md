# Agent workflow (SwiftMind)

## After any code change that affects the Mac app

**Do not ask the user to stop Xcode and re-run.** Always:

```bash
./scripts/rerun-mac.sh
```

Or after core-only changes with no UI:

```bash
swift test
```

## Automated testing (what exists)

| Layer | Command | Coverage |
|-------|---------|----------|
| Unit / domain / layout / HTML | `swift test` | Model, commands, layout, codec, search, E2E map workflows (~40 tests) |
| Compile gate | `./scripts/verify.sh` | Tests + xcodebuild |
| Launch smoke | `./scripts/rerun-mac.sh` | App starts (Open panel is system DocumentGroup) |

## Not fully automated yet

- Pixel-perfect canvas UI (hover, drag feel)
- Full XCUITest click paths

Prefer expanding `Tests/SwiftMindCoreTests` for logic; use `rerun-mac.sh` for visual confirmation when the human is present.
