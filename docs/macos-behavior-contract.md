# mdwrite Native Behavior Contract

## Implementation status

The initial planning and rename changes are committed as `cad6942`. The pure editor implementation is committed as `8816ff8`. A native Swift/AppKit development application now builds under `macos/` and has launched successfully; source-derived fixtures and reproducible tests accompany it. M00's Qt runtime validation remains pending; M01's source contract and initial fixtures are implemented, but its runtime parity matrix is not accepted yet.

The installed Swift 6.4 Command Line Tools can compile and run these Swift Testing checks. The SwiftPM-based native bundle also builds with these tools. Full Xcode is required for the future Xcode UI-test pipeline. Qt baseline validation needs Qt 6 and suitable Linux services; installing Qt on macOS alone does not reproduce the D-Bus/portal integration. Source-only checks below let independent contract work proceed without falsely accepting those gates.

## Decisions for initial implementation

- Native app: `mdwrite`; Swift 6; macOS 14 deployment floor. Initial development validation is Apple silicon; Intel remains a release gate rather than a tested claim.
- Provisional development bundle identifier: `dev.mdwrite.prototype`. Choose a publisher-controlled namespace before distribution.
- One document per window in one process. Explicit Save/Save As; autosave in place is disabled by default. The development implementation uses document undo-manager tracking and an atomic app-owned recovery journal; NSDocument autosaving is disabled. The full M03 failure matrix remains a production acceptance gate.
- UTF-8 files only. Reject invalid UTF-8 and UTF-16 inputs with a recoverable error; never silently replace bytes with replacement characters.
- Internal editor text uses LF. Unchanged saves retain the exact original bytes, including UTF-8 BOM, mixed line endings, and trailing newlines. After editing, retain the BOM and the first encountered CR/LF newline style, normalize mixed line endings to that style, and preserve the text's trailing-newline count. New documents use LF without BOM.
- Editing and span interfaces use UTF-16 location/length pairs. Commands reject ranges that overflow or split a composed character, including surrogate pairs, combining marks, and CRLF pairs. IME-specific adapter handling remains an M02/M06 requirement.
- Clipboard URL recognition permits HTTP, HTTPS, FTP, and mailto as in the current backend. Opening links permits only HTTP, HTTPS, and mailto. Local files and executable URL schemes are rejected.
- The original per-line span fixtures remain a Qt reference. Later user feedback authorizes richer native styling through Foundation semantic parsing, plus source decorations for tasks/footnotes. See the [element audit](macos-markdown-coverage.md). Markdown remains editable source; this is not a claim of complete custom-dialect or rendered-preview support.

## Source fixtures and checks

`tests/fixtures/editor-behavior.json` contains 37 source edit examples and 36 utility/span examples. Every range is a UTF-16 `[location, length]` pair. Examples come from existing Qt tests and directly inspected handlers. The fixture file is shared across source checks and native checks.

- `./bin/test-source-fixtures`: execute extracted functions from the real `src/Main.qml` and `src/EditorMutations.js` against 35 edit fixtures with a small in-memory TextEdit adapter. This validates handler logic only; Qt signals, actual layout, caret semantics, and undo are not simulated accurately enough to accept runtime parity.
- `./bin/test-macos-core`: build the dependency-free Swift package and run Swift Testing checks. Its nineteen test groups cover all 73 fixtures, rejected Unicode/overflow ranges, safe filename truncation, source-formatting commands, and byte-preserving encoding round trips/errors.
- `./bin/test`: existing Qt tests; currently blocked by missing qmake. Run in a supported Qt environment before accepting the reference application and its rename.

These are automated outcomes, not screenshots or UI acceptance. Add fixtures when an example exposes a new behavioral branch; do not adjust expected values merely to make an implementation pass.

## Recorded native differences

| Case | Existing behavior | Native expectation and reason |
| --- | --- | --- |
| Default editing mode | Qt opens an editable source document. | User-requested native View mode is read-only by default. E in the document or the Edit button enables changes; View locks them again. Modes preserve unsaved source/history and are independent per window. See [the mode contract](macos-view-edit-modes.md). |
| Empty list item with an active selection | Smart Return removes the prefix only; selected source can remain behind. | Consume the active selection while exiting the list. Fixture `return-empty-list-with-selection` captures this correctness change; source oracle intentionally excludes it. |
| Ordinary Enter and Backspace | Qt inserts two paragraph newlines and can delete a pair together. | User-requested native behavior inserts one newline and deletes one newline. Shared fixtures keep Qt expectations and separate native expectations. |
| Return with a directional selection | QML computes context at the active caret, so selection direction can change list continuation. | Compute context at the replacement start in both directions. Whole-list selection becomes one newline consistently; forward selection fixture records this difference. |
| Clipboard URL serialization | QUrl uses its own pretty-decoding policy. | Use Foundation absolute URL serialization, with percent-encoded Unicode paths and spaces. This is a deliberate serialization choice, not byte-for-byte QUrl parity. |
| Selection or edit splits Unicode text | Qt/JS range code clamps integer offsets; its handler does not validate composed characters. | Reject invalid ranges before mutation. Leave IME text composition to the native text view. |
| Filename limit ends inside an emoji/combining sequence | Qt truncates to 120 UTF-16 units directly. | Stop at the last intact grapheme within 120 units so suggested filenames contain valid text. |
| Encoding and line endings | Qt text reading/writing may normalize line endings and is not a strict UTF-8 error policy. | Apply the explicit byte-preserving unchanged-save policy above; reject undecodable files. |
| Linux desktop integration | Portal/GNOME scale, Omarchy color file, custom wheel animation. | AppKit colors/appearance, app text size, native scrolling; no Linux service dependency. |
| Keyboard commands | Primarily Control shortcuts; Control-H is Replace. | Command shortcuts through native menus; Command-H remains Hide. Native find/replace mapping is selected during integration. |

URLs are compared using Foundation's URL serialization in native tests. Fixtures cover standard URLs and encoded Unicode/spaces; cross-library normalization for international hosts, malformed percent escapes, and unusual authority syntax remains an explicit comparison task rather than a claim of complete Qt URL parity.

## Runtime acceptance matrix

Rows remain pending full native UI acceptance unless a narrower automated result is explicitly listed. Run these scripts in temporary locations and record OS, hardware, build identifier, and results. Each script corresponds to a migration-plan parity row.

Native scripts that modify a document must first press E in the focused document or choose Edit. Read-only checks remain in the default View mode.

| Area | Acceptance script and evidence |
| --- | --- |
| Open/save, filenames, last directory | Open LF/CRLF/BOM/no-trailing-newline files, save unchanged and compare bytes; edit/save and compare with the encoding policy. Reject invalid bytes without changing files. Try denied permission and read-only destination, cancel Save As, reopen the last directory, and open through Finder/recent items. Core encoding/name cases pass; native smoke verified unchanged bytes, edited BOM/CRLF Save, and clean-state completion. Panel cancellation and access-denial tests remain pending. |
| Dirty close/open/quit | Edit two windows, quit, cancel a save panel, then cancel quit. Both drafts remain. Retry with successful save and explicit discard. Failed save must prevent close; undo to saved baseline clears dirty state. |
| Recovery | Create one unnamed and two named dirty drafts, wait for a committed recovery write, forcibly terminate, and relaunch. Recover separately; retain local and external text if disk changed. Test corrupt/old-version snapshots and interruption during cleanup. |
| External changes | Use a second process for direct write, atomic replacement, same-content write, move/delete/recreate, and write during Save As. Confirm explicit reload/keep/save-copy behavior; retain conflict evidence and suppress own-save prompts. |
| Markdown rendering | Type/paste headings, bold, italic, links, lists, quotes, rules, inline and fenced code. Check wrapping and concealed markers without changing source. Compare current heuristic examples and record any intentional divergence. Source span fixtures pass; layout is pending. |
| Hidden marker editing | Arrow/word/page navigation, selection in both directions, mouse hit testing, delete/backspace across markers, clipboard source copy, IME, and VoiceOver must remain coherent. Restyling must not add undo or dirty state. |
| Editing commands | Run each fixture through the native text view; one undo restores source and selection. Validate smart Return, Shift-Return, list/quote exit, paired-break delete, paste URL over selection, and escaped link labels/destinations. Pure command fixtures pass; native bold/undo/redo and undo-to-clean checks passed. Native Enter/Shift-Enter/Backspace and list/task/quote/code continuation now pass; IME and the remaining commands still require complete acceptance. |
| Find and replace | Find source text and hidden URL syntax, reveal/select the result, next/previous wrap, replace one and all, undo once, then switch documents. Check Unicode case folding and selection boundaries. |
| Word count and filename | Compare fixture outputs, then type/delete rapidly and verify no stale count or incorrect dirty state. Large-file latency is measured separately. Pure utility fixtures pass. |
| Printing | Print representative headings, paragraphs, lists, quotes, inline/fenced code, and links to PDF. Inspect pagination, paper colors, missing glyphs, and clipping. Cancel printing and verify source, dirty state, and undo stay unchanged. |
| Appearance and scrolling | Switch light/dark/accent while typing, resize and cross Retina/multiple displays, increase text size, and enable increased contrast/Reduce Motion. Check footer/scrollbar separation and keyboard/VoiceOver reachability. |
| Window lifecycle and commands | New/Open/Save/Save As/Print/Find/Hide/Quit target the correct focused window. Close the last window without losing app menus, reopen a document, restore frames after display removal, and use fullscreen. |

## Native development evidence and next gates

On 2026-09-30, the SwiftPM app bundle built, plist validation and local sandbox signature verification passed, and its Mach-O dependencies contained no Qt. The app launched with native menus, editor, and footer. A saved document window was observed; this is limited UI evidence, not the full lifecycle matrix.

An earlier separate native smoke process passed headless load/byte preservation, bold editing, native dirty tracking, undo/redo, undo-to-clean recovery cleanup, explicit document Save with BOM/CRLF preservation, recovery as an untitled copy, external-save rejection without overwrite, and rendered PDF text. No physical print job was submitted. Those expanded exact-permission, failed-Save-As, and distant-range styling checks subsequently passed in the native smoke after approval review became available. The autosave-disable refinement is included in that tested build.

The current source mode dims markers without eliding them. ATX headings have six sizes with proportional text-size scaling. Fenced backtick/tilde code uses a monospaced font and a paragraph-width light/dark background, including blank lines and unfinished blocks. Inline code is shaded; Markdown syntax inside code is literal. This heading-size hierarchy and fenced-block styling are recorded native presentation improvements. Printing uses a separate Foundation semantic renderer for the documented Markdown profile; pagination and visual acceptance remain pending. Recovery schema version 1 skips and preserves malformed/unknown records; forced-termination, multiple-process ownership, and denied-access behavior are not yet accepted.

Nineteen Swift test groups and 35 extracted QML/JS handler examples pass. These checks do not prove IME, VoiceOver, full search/replace acceptance, hidden-marker editing, all lifecycle failures, or performance. Obtain Qt runtime evidence in its supported environment; finish M02/M03 and the integrated hardening matrix before declaring the complete port accepted. The later launchable-app directive permits this development milestone while preserving release gates.

The native formatting regression first reproduced equal 20-point heading sizes, absent fence backgrounds, and bold formatting inside fenced code. After adding block context and presentation rules, the same check passes, along with font scaling, removal of stale code styling after fence edits, source-preserving undo, and editor PDF drawing. Parser tests cover UTF-16/emoji ranges, heading levels, delimiter type/length, and incomplete fences.

The subsequent element/Enter audit reproduced `hello\n\n` from one real Return key event and missing quote/list/rule/table/inline styles. The native audit now passes after single-newline editing and semantic source styling were introduced. UTF-8 source-position conversion has regressions for full emoji/combining spans and code blocks ending at column zero. Light/dark full-editor PNGs were inspected. See [the coverage record](macos-markdown-coverage.md) for exact supported presentations and printing limits.
