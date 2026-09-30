# macOS View and Edit Modes

Every opened, untitled, or recovered document starts in **View** mode. Markdown styling, wrapping, selection, copying, Find, printing, and text-size controls remain available.

## Switching modes

- Press **E** while the document has keyboard focus to enter **Edit** mode. The activation key is consumed; it does not insert a character. Once editing, `e` types normally.
- Use the toolbar's **View** and **Edit** buttons in either direction. The selected button and footer show the current mode.
- The **View → View Mode / Edit Mode** menu provides the same controls.

Each document window has its own mode. Typing `e` in the Find field searches normally and does not switch the document. Reopening a document starts in View mode again.

## View-mode protection

View mode makes the native text view selectable but noneditable. Source commands and native text-change approval also reject mutations. Typing, input-method text, Enter, deletion, cut, paste, formatting, replacement, and document undo/redo cannot change the source. The formatting toolbox and modifying menu actions are disabled.

Switching modes does not save, discard, or change the document. Unsaved edits and undo/redo history are retained. Return to Edit mode to continue editing or undo previous changes. An active input composition is finalized before entering View mode; subsequent input is rejected.

## Verification

After building, run:

```sh
./build/mdwrite.app/Contents/MacOS/mdwrite --mode-test
```

The isolated native check covers default modes, blocked mutation paths, all formatting commands, supported native copying, Find, search-field focus, lowercase/uppercase E, toolbar validation/buttons, history preservation, BOM/CRLF bytes, synthetic input composition, recovered documents, and independent windows. Add `--mode-preview` for temporary light/dark window PNGs in both modes. `./bin/test-macos` includes this check and the existing editor/document regressions. Full IME and VoiceOver acceptance remain separate release gates.
