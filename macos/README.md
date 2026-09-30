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

Native menus provide New/Open/Save/Save As, Print, undo/redo, find/replace, bold/italic/link, text size, and fullscreen. Markdown source remains editable, with dimmed markers. Save is explicit; drafts use a separate atomic recovery journal. After an abnormal exit, records reopen as untitled copies. Recovery is debounced by 500 ms, so the most recent edits can be absent from a crash snapshot. External changes are polled each second and rechecked against the baseline during coordinated Save. Noncooperating writers can still race a save.

## Checks

```sh
./bin/test-source-fixtures
./bin/test-macos-core
./bin/test-macos
```

The source checker requires Node.js. Core tests use Swift Testing with workspace-local caches; the script supplies the installed CLT macro-plugin path when needed. The full test script builds the bundle and runs a separate AppKit smoke process using temporary files. Run it from a normal macOS terminal in a logged-in graphical session. It never sends a physical printer job.

Seven core test groups and 35 source-handler examples pass. A previous native smoke revision passed opening, byte preservation, formatting, dirty state, undo/redo, Save, recovery/cleanup, rendered PDF, and conflict protection. The expanded smoke assertions for exact permissions, failed Save As, and distant-range styling, plus recent presentation refinements, have not yet run: automatic approval review was unavailable because workspace credits were exhausted.

## Organization and remaining gates

`EditorCore/` owns pure checked UTF-16 edits, spans, utilities, and UTF-8 serialization. `NativeApp/` owns documents, windows, editing adapters, recovery, printing, and the smoke harness. A document-owned text storage supports loading before a window exists; its undo manager supplies dirty tracking.

Full syntax elision, IME/VoiceOver validation, multi-window close/quit failures, forced-termination recovery, large-file measurements, minimum-OS/Intel coverage, relocation, and distribution signing remain pending. Full Xcode is needed for a future XCTest/UI-test pipeline, not for this local app bundle. See [the task ledger](../docs/macos-port-tasks.md) and [behavior contract](../docs/macos-behavior-contract.md).
