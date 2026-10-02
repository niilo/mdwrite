# Markdown table presentation plan

## Goal and current behavior

Prioritize readable tables in **View mode**; preserve predictable source editing in **Edit mode**. This is a proposed implementation plan, not an implemented feature.

Both modes currently share `MarkdownTextView` and the document's source storage. `MarkdownStylePlan` bolds table headers and shades source rows; `MarkdownLayoutManager` draws backgrounds behind wrapped lines. Neither calculates cell widths, so arbitrary spaces and wrapped pipe-delimited rows remain visually disorganized. `MarkdownPrintRenderer` uses tab stops, which is not a complete cell-layout solution.

## View mode: intended appearance

- Render recognized tables as a grid with shared column widths. Hide structural pipes, alignment markers, and the delimiter row.
- Use semibold headers, a subtle header background, light row separators, approximately 10-point horizontal/6-point vertical cell padding, and top-aligned multiline cells. Scale padding with text size; support light/dark appearance and increased contrast.
- Honor Markdown left/center/right column alignment. Render emphasis, inline code, and link labels inside cells. Keep images as alt text and raw HTML as text, matching existing limitations.
- Fit within the document's existing equal side padding and any enclosing quote/list indentation. Allocate capped, content-aware column widths; wrap long prose and unbroken URLs without truncation or shrinking the font.
- When too many columns cannot remain readable at the available width, show each data row as stacked header/value pairs. Preserve column order and empty cells; use “Column N” for an empty header. No document-wide horizontal scrolling.
- Keep column widths stable while scrolling. Measure width policy once per table/source/font/viewport generation rather than once per visible row.

Initial sizing policy: minimum grid column width `max(64 pt, 4 × body font size)`, including padding; switch to stacked rows when those minima exceed available width. Validate this starting value visually before freezing it.

## Edit mode: smaller follow-up

Keep literal pipe-delimited source, the current monospaced typography, visible syntax, native selection, and undo. Do not change spaces or insert alignment padding while typing.

Add an explicit **Align Table Source** action: calculate source column padding for the current valid table, preserve cell content/alignment markers/newline convention, and apply one checked `SourceEdit` with one undo step. Preserve selection through inserted whitespace. Disable it for malformed or unsupported tables. Tab navigation and automatic row insertion are later enhancements; existing Return/Shift-Return behavior remains the first implementation's contract.

## Source, selection, and mode contract

`MarkdownDocument.sourceStorage` remains authoritative for Save, recovery, dirty tracking, word count, and undo. A separate read-only presentation storage replaces only table ranges; surrounding text retains its current source styling. Rendering must never rewrite the document or attach its native table attributes to the editable source storage.

Build a UTF-16 source/presentation map for unchanged text, cell content, hidden syntax, and generated separators/labels. It must cover empty cells, escaped characters, inline markup, and Unicode graphemes. All selection, copy, Find, and mode-switch conversion uses this single map.

- **E / Edit button:** map the focused cell or selection to the original source; consume E, restore focus, and keep that location visible. View → Edit → View preserves the logical scroll anchor and unsaved history.
- **Copy:** retain the existing source-copy contract. Map the selection to its source span; full-table copy returns exact original Markdown, including its delimiter row. Generated labels alone copy nothing. Offer **Copy Table as TSV** separately for spreadsheet use, with a tested quoting policy for tabs/newlines/quotes inside values.
- **Find:** search the visible presentation in View mode and highlight actual cell text. Hidden table syntax remains searchable in Edit mode. Translate the current match when switching modes and refresh cached Find ranges after presentation replacement.
- **Read-only protection:** both the viewer and document command routing reject cut/paste/replace/formatting/undo mutations in View mode. Find-field E still types normally.
- **Accessibility:** verify cell reading order, header association, empty cells, keyboard selection, and mode announcements with VoiceOver; native table drawing alone does not establish accessibility acceptance.

## Implementation design

1. **Table model in `EditorCore`.** Extend existing immutable analysis with table/row/cell source ranges, alignment, rendered inline content, and mapping segments. Reuse Foundation table identities and whole-document reference resolution; source scanning fills empty-cell and delimiter information. Do not introduce a second whole-document parser.
2. **Native table adapter.** First prove `NSTextTable`/`NSTextTableBlock` in an isolated read-only `NSTextView`, with actual wrapping, mouse selection, Find, copy, and surrounding text. Use macOS 14-compatible interfaces; newer SDK-only methods need availability guards. Keep existing TextKit 1 ownership.
3. **Presentation owner.** Add a window-owned module that builds/installs mapped read-only snapshots, routes mode-dependent actions, and preserves source anchors. Keep table layout details inside the native adapter. The existing source editor and analysis coordinator continue to own editing and revision tracking. Audit `editor.string` callers: footer/counts, persistence, and recovery must always use source, not rendered text. Give the coordinator a mapped visible source range when the viewer is active; do not query the hidden source editor's viewport or apply source offsets to presentation storage.
4. **Bound work.** Reuse background analysis and its one-active/latest-pending scheduling. Reject results after source revision, reload/close epoch, or font/theme/width changes. Resolve AppKit attributes and install presentation in bounded main-actor work. Cache width measurements; avoid whole-document `ensureLayout` calls and synchronous reparsing on resize or mode changes.

Native tables are the first feasibility candidate, not an assumed solution. If selection, width constraints, accessibility, or large-table layout fails, stop integration and record the failed probe. Evaluate a selectable virtualized table adapter with the same model/map; a painted image or web view is not a shortcut around those contracts.

## Task list and acceptance

| Task | Depends on | Deliverable and exit check |
| --- | --- | --- |
| T01 Freeze fixtures | First | Uneven source spacing; 1/3/12 columns; long cells/URLs; empty/header-only tables; alignment; optional outer pipes; escaped pipes including inline code; CRLF/Unicode; malformed rows; code-block exclusions; adjacent prose and tables in quotes/lists. |
| T02 Model and mapping | T01 | Pure parser/map tests with exact source spans, grapheme-safe round trips, whole-table copy, inline references, and generated-label behavior. Match the existing semantic table profile. |
| T03 Native feasibility | T02 | Grid and stacked-row previews at 560/800/1200-point windows, 12/20/40-point text, light/dark appearance; native interaction and layout timing pass before integration. |
| T04 Integrate View mode | T03 | Read-only presentation, E/buttons/menus, selection/scroll restoration, Find routing, source-copy/TSV, stale-result rejection, reload/close and independent windows. No source/dirty/undo changes from rendering. |
| T05 Acceptance | T04 | Existing core/native suites plus isolated table interaction checks; visual inspection, VoiceOver, and serial performance measurements. Document results and unresolved failures. |
| T06 Edit assistance | T05 | Explicit Align Table Source, exact content/newline preservation, selection restoration, one-step undo/redo, and no automatic mutation. |

Performance fixtures include many small tables, a 10,000-row table, wide tables, and 1/10 MiB mixed documents. Record first-visible rendering, mode-switch latency, resize/scroll heartbeat, peak memory, and close release. Proposed gates: p95 ordinary editing below 16 ms; p95 event-loop delay below 50 ms and no steady stall above 100 ms; first readable viewport within 1 second at 1 MiB. Keep existing failure records and budgets; do not hide a giant-table stall behind a fast explicit callback. Continue showing current styled source while a new presentation is pending rather than showing an obsolete snapshot.

Run `./bin/test-macos-core` and `./bin/test-macos` after implementation. Add planned table fixtures/interaction checks to those suites; no table-specific command exists yet. Update coverage and View/Edit documentation only when behavior is implemented and verified.

## Review and revisions

1. **Appearance review:** source padding alone cannot align independently wrapped cells. Revised the preferred approach to native cell layout in a separate read-only presentation, with an explicit narrow-window policy.
2. **Behavior review:** hiding syntax changes offsets and native Find/copy behavior. Added one mapping owner, exact Markdown copy, empty/generated-cell handling, Find semantics, and source anchors across mode changes.
3. **Performance/platform review:** rendering an entire table synchronously can recreate recent freezes, and current SDK interfaces may exceed macOS 14. Added a feasibility gate, revision/generation rejection, large-table timings, and minimum-OS verification. Native accessibility remains a manual gate.
4. **Integration review:** two presentations can misroute word counts, menus, and visible-first styling. Added an authoritative-source audit and a mapped-viewport interface; account for quote/list indentation when fitting tables. Keep these integration checks ahead of optional editing tools.

## References

Table grammar and fixtures follow the [GFM table specification](https://github.github.com/gfm/#tables-extension-). The native feasibility candidate uses Apple's [NSTextTable](https://developer.apple.com/documentation/appkit/nstexttable) and [NSTextTableBlock](https://developer.apple.com/documentation/appkit/nstexttableblock); their interfaces were also checked against the installed AppKit headers. Existing contracts: [View/Edit modes](macos-view-edit-modes.md), [Markdown coverage](macos-markdown-coverage.md), and [performance plan](macos-performance-plan.md).
