# mdwrite Native Development

The native app uses Swift 6, AppKit, NSDocument, and an explicitly constructed TextKit 1 editor. It requires macOS 14 or later and compatible Apple Command Line Tools or Xcode; no Qt or third-party package is linked.

## Build and launch

Run from the repository root:

```sh
./bin/build-macos
./bin/run-macos
MDWRITE_CONFIGURATION=release ./bin/build-macos
```

The bundle is `build/mdwrite.app`. It contains Markdown/plain-text document declarations, sandbox entitlements, iA Writer Mono fonts, and license notices. Signing is local and ad-hoc, with provisional identifier `dev.mdwrite.prototype`; this is not a notarized distribution. Rebuilding stages a fresh bundle and preserves the previous bundle so an already running app is not overwritten.

Native menus provide New/Open/Save/Save As, Print, undo/redo, find/replace, text size, and fullscreen. The toolbar and Format menu share a [37-action Markdown toolbox](../docs/macos-formatting-toolbox.md), including headings, lists/tasks, quotes, code, tables, links/images, footnotes, and HTML source. Markdown source remains editable, with heading hierarchy, quotes/lists/tasks, rules, tables, emphasis/links, and literal shaded code. See the [element coverage audit](../docs/macos-markdown-coverage.md) for source presentations and limits. Enter inserts one newline, preserving list/quote continuation; Shift-Enter skips continuation. Save is explicit; drafts use a separate atomic recovery journal. After an abnormal exit, records reopen as untitled copies. Recovery is debounced by 500 ms, so the most recent edits can be absent from a crash snapshot. External changes are polled each second and rechecked against the baseline during coordinated Save. Noncooperating writers can still race a save.

## Checks

```sh
./bin/test-source-fixtures
./bin/test-macos-core
./bin/test-macos
```

The source checker requires Node.js. Core tests use Swift Testing with workspace-local caches; the script supplies the installed CLT macro-plugin path when needed. The full test script builds the bundle and runs a separate AppKit smoke process using temporary files. Run it from a normal macOS terminal in a logged-in graphical session. It never sends a physical printer job.

Nineteen core test groups and 35 source-handler examples pass. The native smoke passes opening, byte preservation, formatting, dirty state, undo/redo, Save with exact permissions, failed Save As, recovery/cleanup, distant-range styling, rendered PDF, and conflict protection. Native heading/code regression checks cover hierarchy, literal code, font scaling, fence removal, source preservation, and undo. Native Markdown coverage also checks blockquotes, nested lists/tasks, Setext headings, tables, references, combined emphasis, strikethrough, indented code, escaped text, raw HTML, native Enter/Shift-Enter/Backspace, CRLF serialization, and rendered printing. The toolbox checks exercise every menu/toolbar action, editor focus, no-op cleanliness, and one-step undo/redo. Formatting uses Foundation semantic source spans and AppKit display attributes. Full-document styling maintains distant block/reference context; large-file performance remains a gate.

For a focused formatting check after building:

```sh
./build/mdwrite.app/Contents/MacOS/mdwrite --style-test
```

Use `--markdown-test` for the complete element/key audit and add `--style-preview` to export temporary light/dark PNGs from the real editor. The smaller `--style-test` also exports PDF previews. The check uses its own document and does not edit open user documents.

Use `--format-test` for all Format/toolbox commands, with `--format-preview` for temporary light/dark window PNGs.

The editor wraps to the scroll viewport with equal side insets, including after window resizing. `--layout-test` checks viewport sizing, symmetric padding, long paragraph/quote/list/code wrapping, resize reflow, and source/undo preservation at 560, 800, and 1200 points. Add `--layout-preview` to export light/dark window PNGs.

## Organization and remaining gates

`EditorCore/` owns pure checked UTF-16 edits, spans, utilities, and UTF-8 serialization. `NativeApp/` owns documents, windows, editing adapters, recovery, printing, and the smoke harness. A document-owned text storage supports loading before a window exists; its undo manager supplies dirty tracking.

Full syntax elision, IME/VoiceOver validation, multi-window close/quit failures, forced-termination recovery, large-file measurements, minimum-OS/Intel coverage, relocation, and distribution signing remain pending. Full Xcode is needed for a future XCTest/UI-test pipeline, not for this local app bundle. See [the task ledger](../docs/macos-port-tasks.md) and [behavior contract](../docs/macos-behavior-contract.md).
