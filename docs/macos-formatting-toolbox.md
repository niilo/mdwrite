# macOS Formatting Toolbox

Open **Format** in the window toolbar or the macOS menu bar. Both expose the same 37 actions, grouped by purpose.

| Group | Options |
| --- | --- |
| Inline | Bold, italic, bold and italic, strikethrough, inline code. |
| Headings | Paragraph, headings 1–6, Setext headings 1–2. |
| Lists | Bulleted list, numbered list, task list, completed task, indent/nest, outdent/unnest. |
| Blocks | Blockquote, fenced code, indented code, horizontal rule, table. |
| Links and Images | Link, image, reference link, reference image, automatic link, reference definition. |
| Other | Footnote, hard line break, escaped Markdown, HTML entity, HTML block, HTML comment. |

## Applying formatting

Select text for inline formatting. Without a selection, these actions insert an editable placeholder. Headings, lists, quotes, and indentation apply to the current line or all selected lines. A selection ending at the next line's start leaves that next line untouched. Heading conversion replaces existing heading markers, including Setext underlines.

Code blocks use the current/selected lines and stay separate from surrounding paragraphs. Backtick delimiters grow when necessary to contain literal backticks. Rule/table/HTML templates replace the selection, with blank lines separating them from surrounding text. Table headers and image paths are editable placeholders. Indent/outdent changes up to four spaces per level; choose list lines to nest them.

Reference links/images insert a matching definition at the document's end and select its destination. Footnotes also append their definition. Generated labels avoid existing labels; use the standalone reference-definition action for a custom label. Inline Link continues to use a recognized clipboard URL.

Each source change supports one-step Undo/Redo and restores focus to the editor. Actions that leave the source unchanged do not create undo entries or mark the document edited. Existing Bold, Italic, and Link shortcuts remain **⌘B**, **⌘I**, and **⌘K**; **⌘⌥1–6** apply heading levels.

These controls insert editable Markdown source. See the [presentation coverage](macos-markdown-coverage.md) for image, HTML, footnote, and dialect limits.

## Verification

Run `./bin/test-macos-core` for source-edit regressions and `./bin/test-macos` for integration checks. After building, `./build/mdwrite.app/Contents/MacOS/mdwrite --format-test` checks every toolbox action, document targeting, focus, dirty state, and Undo/Redo. Add `--format-preview` to export light/dark window PNGs using independent test documents.
