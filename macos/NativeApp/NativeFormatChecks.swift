import AppKit
import EditorCore

@MainActor
enum NativeFormatChecks {
    static func run() throws {
        func expect(_ condition: Bool, _ message: String) throws {
            if !condition {
                throw NSError(domain: "mdwrite.toolbox", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        func actions(_ menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { item in
                item.submenu.map(actions) ?? (item.action == #selector(MarkdownTextView.applyMarkdownFormat(_:)) ? [item] : [])
            }
        }
        let mainFormat = NSApp.mainMenu!.items.first { $0.title == "Format" }!.submenu!
        let mainActions = actions(mainFormat)
        try expect(mainActions.map(\.tag) == MarkdownFormat.allCases.map(\.rawValue), "Format menu is missing commands")
        try expect(mainActions.allSatisfy { $0.target == nil }, "Main menu must route to the focused document")

        for format in MarkdownFormat.allCases {
            let content = format == .paragraph ? "# hello" : format == .outdent ? "    hello"
                : format == .escape ? "*hello*" : "hello"
            let source = "before\n\n" + content + "\n\nafter"
            let document = MarkdownDocument()
            document.recoveryStore = nil
            try document.read(from: Data(source.utf8), ofType: "net.daringfireball.markdown")
            document.makeWindowControllers()
            let controller = document.editorController!
            let editor = controller.editor
            editor.enterEditMode(nil)
            let selection = (source as NSString).range(of: content)
            editor.setSelectedRange(selection)
            let command: EditorCommand = format == .link
                ? .link(clipboard: NSPasteboard.general.string(forType: .string) ?? "") : .format(format)
            let expected = try EditorBehavior.edit(command, in: source, selection: selection)!.applying(to: source)
            let popup = controller.window!.toolbar!.items.compactMap { $0.view as? NSPopUpButton }.first!
            let toolboxActions = actions(popup.menu!)
            try expect(toolboxActions.map(\.tag) == mainActions.map(\.tag),
                       "Toolbar and menu commands differ")
            let entry = toolboxActions.first { $0.tag == format.rawValue }!
            try expect(entry.target === editor, "Toolbox command targets the wrong document")
            entry.menu!.update()
            try expect(entry.isEnabled, "\(format.title) is disabled in the toolbox")
            entry.menu!.performActionForItem(at: entry.menu!.index(of: entry))
            try expect(editor.string == expected, "\(format.title) did not apply its source edit")
            try expect(controller.window!.firstResponder === editor, "\(format.title) lost editor focus")
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.001))
            try expect(document.isDocumentEdited, "\(format.title) did not mark the document edited")
            document.undoManager?.undo()
            try expect(editor.string == source && !document.isDocumentEdited, "\(format.title) did not undo in one step")
            document.undoManager?.redo()
            try expect(editor.string == expected, "\(format.title) did not redo")
            document.undoManager?.undo()
            if format == .bold && CommandLine.arguments.contains("--format-preview"),
               let frame = controller.window!.contentView?.superview {
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    let drawingAppearance = NSAppearance(named: appearance)!
                    controller.window!.appearance = drawingAppearance
                    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
                    frame.layoutSubtreeIfNeeded()
                    guard let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else {
                        throw NSError(domain: "mdwrite.toolbox", code: 2)
                    }
                    drawingAppearance.performAsCurrentDrawingAppearance {
                        frame.cacheDisplay(in: frame.bounds, to: bitmap)
                    }
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("mdwrite-toolbox-\(appearance.rawValue)-\(UUID()).png")
                    try bitmap.representation(using: .png, properties: [:])!.write(to: url)
                    print("Format toolbox preview: \(url.path)")
                }
            }
            document.close()
        }
        let unchanged = MarkdownDocument()
        unchanged.recoveryStore = nil
        try unchanged.read(from: Data("plain text".utf8), ofType: "net.daringfireball.markdown")
        unchanged.makeWindowControllers()
        let editor = unchanged.editorController!.editor
        editor.enterEditMode(nil)
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        for format in [MarkdownFormat.paragraph, .outdent, .escape] { editor.apply(.format(format)) }
        try expect(editor.string == "plain text" && !unchanged.isDocumentEdited && unchanged.undoManager?.canUndo != true,
                   "No-op formatting changes dirty or undo state")
        unchanged.close()
        print("PASS: all \(MarkdownFormat.allCases.count) Format menu/toolbox actions, focus, dirty state, undo, and redo")
    }
}
