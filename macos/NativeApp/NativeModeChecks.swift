import AppKit
import EditorCore

@MainActor
enum NativeModeChecks {
    static func run() throws {
        func expect(_ condition: Bool, _ message: String) throws {
            if !condition {
                throw NSError(domain: "mdwrite.mode", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        let original = Data([0xef, 0xbb, 0xbf]) + Data("# View and edit\r\n\r\nhello **Markdown** 👩‍💻\r\n".utf8)
        let document = MarkdownDocument()
        document.recoveryStore = nil
        try document.read(from: original, ofType: "net.daringfireball.markdown")
        document.makeWindowControllers()
        defer { document.close() }
        let controller = document.editorController!
        let window = controller.window!
        let editor = controller.editor
        let source = editor.string
        let selection = (source as NSString).range(of: "hello")
        let buttons = window.toolbar!.items.compactMap { $0.view as? NSSegmentedControl }.first!
        let format = window.toolbar!.items.compactMap { $0.view as? NSPopUpButton }.first!
        func choose(_ segment: Int) {
            buttons.selectedSegment = segment
            _ = NSApp.sendAction(buttons.action!, to: buttons.target, from: buttons)
        }
        func key(_ character: String, code: UInt16, flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                            windowNumber: window.windowNumber, context: nil, characters: character,
                            charactersIgnoringModifiers: character, isARepeat: false, keyCode: code)!
        }
        func sourceUnchanged() throws {
            try expect(editor.string == source && !document.isDocumentEdited, "View mode changed source or dirty state")
            try expect(try document.data(ofType: "net.daringfireball.markdown") == original,
                       "View mode changed BOM or CRLF serialization")
        }
        try expect(editor.mode == .view && !editor.isEditable && editor.isSelectable,
                   "Opened document must be selectable and read-only by default")
        window.toolbar!.validateVisibleItems()
        try expect(buttons.isEnabled && buttons.selectedSegment == 0 && !format.isEnabled,
                   "View controls are disabled or incorrectly initialized after toolbar validation")
        editor.setSelectedRange(selection)
        editor.keyDown(with: key("x", code: 7))
        editor.insertText("blocked", replacementRange: selection)
        editor.setMarkedText("blocked", selectedRange: NSRange(location: 0, length: 0), replacementRange: selection)
        editor.insertNewline(nil)
        editor.insertLineBreak(nil)
        editor.deleteBackward(nil)
        editor.deleteForward(nil)
        editor.cut(nil)
        editor.paste(nil)
        editor.apply(.replace("blocked"))
        editor.apply(SourceEdit(range: selection, replacement: "blocked", selection: NSRange(location: 0, length: 0)), name: "Blocked")
        for option in MarkdownFormat.allCases {
            let entry = NSMenuItem(title: option.title, action: #selector(MarkdownTextView.applyMarkdownFormat(_:)), keyEquivalent: "")
            entry.tag = option.rawValue
            try expect(!editor.validateMenuItem(entry), "\(option.title) is enabled in View mode")
            editor.applyMarkdownFormat(entry)
            editor.apply(.format(option))
        }
        try expect(!editor.shouldChangeText(in: selection, replacementString: "blocked"), "Single-range edit bypasses View mode")
        try expect(!editor.shouldChangeText(inRanges: [NSValue(range: selection)], replacementStrings: ["blocked"]),
                   "Multiple-range replacement bypasses View mode")
        for action in [NSTextFinder.Action.showReplaceInterface, .replace, .replaceAll, .replaceAllInSelection, .replaceAndFind] {
            let item = NSMenuItem(title: "Replace", action: #selector(NSTextView.performTextFinderAction(_:)), keyEquivalent: "")
            item.tag = action.rawValue
            try expect(!editor.validateMenuItem(item), "Replace action is enabled in View mode")
            editor.performTextFinderAction(item)
        }
        try sourceUnchanged()
        try expect(document.undoManager?.canUndo != true && !editor.hasMarkedText(), "Blocked input left undo or marked text")

        editor.setSelectedRange(selection)
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        let copied = editor.writeSelection(to: clipboard, types: editor.writablePasteboardTypes)
        try expect(copied && clipboard.string(forType: .string) == "hello",
                   "View mode cannot copy selected source")
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        _ = editor.readSelection(from: clipboard, type: NSPasteboard.PasteboardType("NSStringPboardType"))
        try sourceUnchanged()
        let find = NSMenuItem(title: "Find", action: #selector(NSTextView.performTextFinderAction(_:)), keyEquivalent: "")
        let findClipboard = NSPasteboard(name: .find)
        let savedFindContents = (findClipboard.types ?? []).compactMap { type in
            findClipboard.data(forType: type).map { (type, $0) }
        }
        defer {
            findClipboard.clearContents()
            findClipboard.declareTypes(savedFindContents.map { $0.0 }, owner: nil)
            for (type, data) in savedFindContents { findClipboard.setData(data, forType: type) }
        }
        find.tag = NSTextFinder.Action.showFindInterface.rawValue
        try expect(editor.validateMenuItem(find), "Find is disabled in View mode")
        editor.performTextFinderAction(find)
        try expect(editor.enclosingScrollView!.isFindBarVisible, "Find bar does not open in View mode")
        func searchFields(in view: NSView) -> [NSTextField] {
            (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(searchFields)
        }
        if let bar = editor.enclosingScrollView!.findBarView,
           let field = searchFields(in: bar).first(where: { $0.isEditable }) {
            window.makeFirstResponder(field)
            let query = try expectFieldEditor(window.firstResponder)
            query.insertText("e", replacementRange: NSRange(location: NSNotFound, length: 0))
            try expect(editor.mode == .view, "E in the search field changes the document mode")
            try sourceUnchanged()
        } else {
            throw NSError(domain: "mdwrite.mode", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Find bar has no editable search field"])
        }
        find.tag = NSTextFinder.Action.hideFindInterface.rawValue
        editor.performTextFinderAction(find)
        window.makeFirstResponder(editor)

        editor.setSelectedRange(NSRange(location: source.utf16.count, length: 0))
        editor.keyDown(with: key("e", code: 14))
        try expect(editor.mode == .edit && editor.isEditable && buttons.selectedSegment == 1 && format.isEnabled,
                   "E does not enable Edit mode and update buttons/toolbox")
        try sourceUnchanged()
        editor.keyDown(with: key("e", code: 14))
        try expect(editor.string == source + "e", "E in Edit mode is not normal typing")
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        editor.undo(nil)
        try sourceUnchanged()

        editor.setSelectedRange(selection)
        editor.apply(.replace("changed"))
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        let edited = editor.string
        try expect(document.isDocumentEdited, "Editing does not change dirty state")
        choose(0)
        try expect(editor.mode == .view && !editor.isEditable && buttons.selectedSegment == 0 && !format.isEnabled,
                   "View button does not lock the document")
        editor.undo(nil)
        controller.undo(nil)
        editor.doCommand(by: #selector(MarkdownTextView.undo(_:)))
        try expect(editor.string == edited && document.isDocumentEdited, "Undo changes a View-mode document")
        try expect(!editor.validateMenuItem(NSMenuItem(title: "Undo", action: #selector(MarkdownTextView.undo(_:)), keyEquivalent: "z")),
                   "Undo is enabled in View mode")
        choose(1)
        try expect(window.firstResponder === editor && editor.mode == .edit, "Edit button does not restore editor focus")
        editor.undo(nil)
        try sourceUnchanged()
        choose(0)
        editor.redo(nil)
        controller.redo(nil)
        editor.doCommand(by: #selector(MarkdownTextView.redo(_:)))
        try sourceUnchanged()
        choose(1)
        editor.redo(nil)
        try expect(editor.string == edited, "Mode switching lost redo history")
        editor.undo(nil)
        choose(0)
        try sourceUnchanged()

        let other = MarkdownDocument()
        other.recoveryStore = nil
        other.makeWindowControllers()
        defer { other.close() }
        try expect(other.editorController!.editor.mode == .view && !other.editorController!.editor.isEditable,
                   "Untitled documents are not read-only by default")
        choose(1)
        try expect(other.editorController!.editor.mode == .view, "Changing one window's mode changes another window")
        choose(0)
        let otherEditor = other.editorController!.editor
        let uppercase = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0,
            windowNumber: other.editorController!.window!.windowNumber, context: nil,
            characters: "E", charactersIgnoringModifiers: "E", isARepeat: false, keyCode: 14)!
        otherEditor.keyDown(with: uppercase)
        try expect(otherEditor.mode == .edit && otherEditor.string.isEmpty && editor.mode == .view,
                   "Uppercase E must enter editing without inserting text or changing another window")
        otherEditor.setMarkedText("composing", selectedRange: NSRange(location: 9, length: 0),
                                  replacementRange: NSRange(location: NSNotFound, length: 0))
        let composition = otherEditor.string
        otherEditor.enterViewMode(nil)
        otherEditor.insertText("late input", replacementRange: NSRange(location: NSNotFound, length: 0))
        try expect(!otherEditor.hasMarkedText() && otherEditor.string == composition && !otherEditor.isEditable,
                   "Entering View mode loses composition or accepts late input")

        let recovered = MarkdownDocument()
        recovered.recoveryStore = nil
        recovered.restore(RecoveryRecord(version: 1, id: UUID(), text: source, sourceURL: nil,
                                         sourceBaseline: nil, updated: Date()))
        recovered.makeWindowControllers()
        defer { recovered.close() }
        try expect(recovered.editorController!.editor.mode == .view && recovered.isDocumentEdited,
                   "Recovered documents must open in View mode and retain unsaved state")

        if CommandLine.arguments.contains("--mode-preview") {
            for mode in [EditorMode.view, .edit] {
                editor.setMode(mode)
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    let drawing = NSAppearance(named: appearance)!
                    window.appearance = drawing
                    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
                    let frame = window.contentView!.superview!
                    frame.layoutSubtreeIfNeeded()
                    guard let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { continue }
                    drawing.performAsCurrentDrawingAppearance { frame.cacheDisplay(in: frame.bounds, to: bitmap) }
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("mdwrite-mode-\(mode)-\(appearance.rawValue)-\(UUID()).png")
                    try bitmap.representation(using: .png, properties: [:])!.write(to: url)
                    print("Mode preview: \(url.path)")
                }
            }
        }
        print("PASS: default View mode, mutation blocking, E shortcut, mode buttons, copy/find, undo/redo, and window isolation")
    }

    private static func expectFieldEditor(_ responder: NSResponder?) throws -> NSTextView {
        guard let editor = responder as? NSTextView else {
            throw NSError(domain: "mdwrite.mode", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Search field did not receive keyboard focus"])
        }
        return editor
    }
}
