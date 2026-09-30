# Native Markdown Styling and Enter Coverage

The native editor styles standard Markdown and common GitHub-style extensions while retaining the original source. This is an editing view: images, tables, HTML, and footnotes keep their editable source syntax. It does not fetch images, execute HTML, or implement every custom Markdown dialect.

## Element audit

| Element | Implemented presentation |
| --- | --- |
| ATX H1–H6 and Setext headings | Six scaled heading sizes, bold titles, spacing, muted markers/underlines. |
| Paragraphs, soft breaks, hard breaks | Normal text and explicit line spacing; hard-break source markers have a subtle cue. No automatic empty paragraph is inserted. |
| Blockquotes, including nested quotes | Italic secondary text, indentation, and one vertical rail per quote level. |
| Unordered, ordered, and nested lists | Muted source markers with hanging indentation for wrapping and deeper nesting. |
| Task lists | Muted checkbox source; checked items are dimmed and struck through. |
| Thematic breaks | Muted source plus a horizontal rule, distinguished from Setext/table separators. |
| Backtick/tilde fenced code | Literal monospaced text, full-width shading, blank-line coverage, and matching delimiter type/length; unfinished fences remain code. |
| Indented code | Literal monospaced text and shading. |
| Inline code | Shaded monospaced content; nested Markdown remains literal. |
| Strong, emphasis, combined/nested emphasis | Bold, italic, or both from semantic parsing. |
| Strikethrough | Source-preserving strike styling. |
| Inline/reference/automatic links | Colored, underlined labels/URLs; source definitions and delimiters are distinguished. |
| Inline/reference images | Styled alt-text source; no embedded image loading. |
| Tables | Bold headers, shaded rows, and muted pipes/alignment separators; source column spacing is retained. |
| Escapes and entities | Muted source cues; escaped emphasis stays literal. |
| Raw HTML/comments | Distinct monospaced source styling; HTML is not executed. |
| Footnote source extension | Smaller colored labels and distinguished definitions; footnote layout/renumbering is not implemented. |

Printing now uses Foundation's semantic parsing for headings, quotes, lists/tasks, code, emphasis, references, and tables rather than a separate collection of line regexes. It renders a separate snapshot with paper colors; image alt text and raw HTML remain textual. Table pagination and the full print acceptance matrix remain release gates.

The [formatting toolbox](macos-formatting-toolbox.md) exposes source-insertion actions for the audited elements in both the toolbar and Format menu.

## Enter and Backspace

Enter inserts exactly one LF in ordinary text. A second press inserts another explicit newline. Existing CRLF documents serialize each inserted LF as exactly one CRLF. Nonempty lists continue their marker (and increment ordered numbers); tasks continue unchecked. Nested quote prefixes and quoted lists continue. Empty list/task/quote items exit their structure. Code preserves indentation and quote context without interpreting literal list/quote text as structure.

Shift-Enter inserts one newline without continuation. Backspace removes one newline through native editing. Each tested Enter operation undoes back to clean source.

## Verification

`./bin/test-macos-core` passes 14 test groups. `./bin/test-source-fixtures` retains 35 Qt-source examples; shared fixtures record separate native expectations for the intentional single-newline change. `./bin/test-macos` includes actual native key-event, styling, printing, and document smoke regressions. The focused command is `./build/mdwrite.app/Contents/MacOS/mdwrite --markdown-test`; add `--style-preview` for temporary light/dark PNGs of the editor. Both appearances were visually inspected. Preview mode also saves a separate native print operation to a temporary PDF, with print/progress panels disabled; this PDF was rendered on a white canvas and inspected. No physical printer job is submitted.

Foundation [source-position attributes](https://developer.apple.com/documentation/foundation/nsattributedstringmarkdownparsingoptions/appliessourcepositionattributes) map semantic runs onto untouched Markdown. The adapter validates UTF-8-column to UTF-16 conversion, including emoji, combining marks, and zero-column code-block endpoints. Full-document restyling keeps references and distant block edits consistent; large-file profiling, IME, VoiceOver, and minimum-OS acceptance remain pending.
