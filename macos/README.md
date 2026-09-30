# mdwrite Native Development

This directory currently contains the Foundation-only editor module and its behavior tests. The native document application and Xcode project are still planned.

Run from the repository root:

```sh
./bin/test-source-fixtures
./bin/test-macos-core
```

The source fixture checker requires Node.js. The native core requires Swift 6 and macOS 14 or later; it has no third-party package dependencies. Swift Testing is used so the core can run with compatible Apple Command Line Tools installations, independently of XCTest. The test script keeps build caches inside `macos/.build/` and supplies the Swift Testing macro plugin path for the installed CLT layout when needed.

`EditorCore/` exposes source edit commands, inline Markdown spans, word counts, suggested filenames, URL policy, and UTF-8 serialization. It owns no UI, file I/O, or undo stack. Callers provide canonical LF text and checked UTF-16 ranges. Apply returned edits through the native text view's editing protocol and document undo manager; do not replace the whole editor buffer on every keystroke.

Tests consume [shared behavior fixtures](../tests/fixtures/editor-behavior.json). See [the behavior contract](../docs/macos-behavior-contract.md) for intentional native differences, verified checks, and pending runtime acceptance. No current test proves syntax elision, IME integration, sandbox access, or crash recovery.
