import AppKit
import EditorCore
import PDFKit

@MainActor
enum NativeMarkdownChecks {
    static func run() throws {
        var failures: [String] = []
        let source = """
        # Heading

        Setext
        ======

        > quote
        >> nestedquote

        - bullet
          - nestedbullet
        2. ordered
        - [ ] todo
        - [x] done

        ---

            **indentedliteral**

        **bold** *italic* ***both*** ~~deleted~~ `**literal**`
        [link](https://example.com) ![image](picture.png)
        <https://example.org> [reference][label]

        [label]: https://example.net

        | Header | Value |
        | --- | --- |
        | Cell | Text |

        See [^note] and \\*escaped* &amp;

        [^note]: Footnote text

        <div>**html literal**</div>
        """
        let document = MarkdownDocument()
        document.recoveryStore = nil
        try document.read(from: Data(source.utf8), ofType: "net.daringfireball.markdown")
        document.makeWindowControllers()
        defer { document.close() }
        let editor = document.editorController!.editor
        editor.restyle()
        func location(_ text: String) -> Int { (source as NSString).range(of: text).location }
        func attribute(_ key: NSAttributedString.Key, _ text: String) -> Any? {
            document.sourceStorage.attribute(key, at: location(text), effectiveRange: nil)
        }
        func font(_ text: String) -> NSFont { attribute(.font, text) as! NSFont }
        func paragraph(_ text: String) -> NSParagraphStyle { attribute(.paragraphStyle, text) as! NSParagraphStyle }
        func expect(_ condition: Bool, _ message: String) { if !condition { failures.append(message) } }
        expect(font("Setext").pointSize > editor.writerFontSize, "Setext heading is not styled")
        expect(NSFontManager.shared.traits(of: font("quote")).contains(.italicFontMask)
               && paragraph("quote").headIndent > 0, "blockquote has no quote styling")
        expect(paragraph("nestedquote").headIndent > paragraph("quote").headIndent, "nested quote has no extra indentation")
        expect(paragraph("bullet").headIndent > 0 && paragraph("ordered").headIndent > 0,
               "unordered/ordered lists have no hanging indentation")
        expect(paragraph("nestedbullet").headIndent > paragraph("bullet").headIndent,
               "nested list has no extra indentation")
        expect((attribute(.strikethroughStyle, "done") as? NSNumber)?.intValue ?? 0 > 0,
               "completed task has no completed styling")
        expect(attribute(NSAttributedString.Key("mdwrite.rule"), "---") != nil, "thematic break has no rule styling")
        expect(attribute(.backgroundColor, "indentedliteral") != nil
               && !NSFontManager.shared.traits(of: font("indentedliteral")).contains(.boldFontMask),
               "indented code is not styled literally")
        let combined = NSFontManager.shared.traits(of: font("both"))
        expect(combined.contains(.boldFontMask) && combined.contains(.italicFontMask), "combined emphasis is not styled")
        expect((attribute(.strikethroughStyle, "deleted") as? NSNumber)?.intValue ?? 0 > 0,
               "strikethrough is not styled")
        expect(attribute(.underlineStyle, "image") != nil, "image source is not styled")
        expect(attribute(.underlineStyle, "https://example.org") != nil, "autolink is not styled")
        expect(attribute(.underlineStyle, "reference") != nil, "reference link is not styled")
        expect(NSFontManager.shared.traits(of: font("Header")).contains(.boldFontMask), "table header is not styled")
        expect(!NSFontManager.shared.traits(of: font("escaped")).contains(.italicFontMask), "escaped syntax is styled as emphasis")
        expect(!NSFontManager.shared.traits(of: font("html literal")).contains(.boldFontMask), "raw HTML source is styled as Markdown")
        expect(font("[^note]").pointSize < editor.writerFontSize, "footnote source label has no styling")
        expect(editor.string == source && !document.isDocumentEdited, "restyling changes source or dirty state")
        if CommandLine.arguments.contains("--style-preview") {
            document.editorController?.window?.contentView?.layoutSubtreeIfNeeded()
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                editor.appearance = NSAppearance(named: appearance)
                editor.restyle()
                if let container = editor.textContainer, let manager = editor.layoutManager {
                    manager.ensureLayout(for: container)
                    editor.setFrameSize(NSSize(width: editor.frame.width,
                        height: max(editor.frame.height, manager.usedRect(for: container).height + 2 * editor.textContainerInset.height)))
                }
                guard let bitmap = editor.bitmapImageRepForCachingDisplay(in: editor.bounds) else {
                    throw NSError(domain: "mdwrite.markdown", code: 2)
                }
                editor.cacheDisplay(in: editor.bounds, to: bitmap)
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("mdwrite-coverage-\(appearance.rawValue)-\(UUID()).png")
                try bitmap.representation(using: .png, properties: [:])!.write(to: url)
                print("Markdown coverage preview: \(url.path)")
            }
            editor.appearance = nil
        }

        let keyCases: [(String, NSRange?, NSEvent.ModifierFlags, String)] = [
            ("hello", nil, [], "hello\n"), ("", nil, [], "\n"),
            ("hello\n", nil, [], "hello\n\n"), ("# heading", nil, [], "# heading\n"),
            ("hello world", NSRange(location: 5, length: 6), [], "hello\n"),
            ("- item", nil, [], "- item\n- "), ("9. item", nil, [], "9. item\n10. "),
            ("- ", nil, [], "\n"), ("- [x] done", nil, [], "- [x] done\n- [ ] "),
            ("- [ ] ", nil, [], "\n"), ("> > nested", nil, [], "> > nested\n> > "),
            ("~~~\n- literal", nil, [], "~~~\n- literal\n"),
            ("> - item", nil, [], "> - item\n> - "),
            ("    code", nil, [], "    code\n    "),
            ("- item", nil, .shift, "- item\n")
        ]
        for (initial, selection, modifiers, expected) in keyCases {
            let input = MarkdownDocument()
            input.recoveryStore = nil
            try input.read(from: Data(initial.utf8), ofType: "net.daringfireball.markdown")
            input.makeWindowControllers()
            let inputEditor = input.editorController!.editor
            inputEditor.enterEditMode(nil)
            inputEditor.setSelectedRange(selection ?? NSRange(location: initial.utf16.count, length: 0))
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                        windowNumber: input.editorController!.window!.windowNumber, context: nil,
                                        characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
            inputEditor.keyDown(with: event)
            expect(inputEditor.string == expected,
                   "Enter for \(initial.debugDescription): \(inputEditor.string.debugDescription), expected \(expected.debugDescription)")
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.001))
            input.undoManager?.undo()
            expect(inputEditor.string == initial && !input.isDocumentEdited, "Enter undo does not restore clean source")
            input.close()
        }
        let input = MarkdownDocument()
        input.recoveryStore = nil
        try input.read(from: Data("hello\r\nworld".utf8), ofType: "net.daringfireball.markdown")
        input.makeWindowControllers()
        let inputEditor = input.editorController!.editor
        inputEditor.enterEditMode(nil)
        inputEditor.setSelectedRange(NSRange(location: inputEditor.string.utf16.count, length: 0))
        inputEditor.insertNewline(nil)
        expect(try input.data(ofType: "net.daringfireball.markdown") == Data("hello\r\nworld\r\n".utf8),
               "one Enter does not serialize as exactly one CRLF")
        inputEditor.insertNewline(nil)
        inputEditor.deleteBackward(nil)
        expect(inputEditor.string == "hello\nworld\n", "Backspace removes more than one explicit newline")
        input.close()

        let printView = MarkdownPrintRenderer.makeView(source: source, width: 500)
        let printText = printView.string as NSString
        let printStorage = printView.textStorage!
        func printed(_ key: NSAttributedString.Key, _ word: String) -> Any? {
            let range = printText.range(of: word)
            guard range.location != NSNotFound else { return nil }
            return printStorage.attribute(key, at: range.location, effectiveRange: nil)
        }
        let printedTitleFont = printed(.font, "Setext") as? NSFont
        expect((printedTitleFont?.pointSize ?? 0) > 12, "print renderer loses Setext heading styling")
        expect((printed(.strikethroughStyle, "deleted") as? NSNumber)?.intValue ?? 0 > 0,
               "print renderer loses strikethrough")
        expect((printed(.paragraphStyle, "quote") as? NSParagraphStyle)?.headIndent ?? 0 > 0,
               "print renderer loses blockquote indentation")
        expect(printView.string.contains("**indentedliteral**") && !printView.string.contains("***both***"),
               "print renderer confuses code and emphasis")
        expect(printView.string.contains("Footnote text\n<div>"), "printed raw HTML loses its block boundary")
        expect((printed(.font, "Header") as? NSFont).map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false,
               "print renderer loses table header styling")
        if CommandLine.arguments.contains("--style-preview") {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("mdwrite-print-\(UUID()).pdf")
            let info = NSPrintInfo()
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
            info.paperSize = NSSize(width: 612, height: 792)
            info.topMargin = 24
            info.bottomMargin = 24
            info.leftMargin = 24
            info.rightMargin = 24
            info.horizontalPagination = .fit
            info.isHorizontallyCentered = false
            info.isVerticallyCentered = false
            let operation = NSPrintOperation(view: printView, printInfo: info)
            operation.showsPrintPanel = false
            operation.showsProgressPanel = false
            expect(operation.run(), "native Save-to-PDF operation fails")
            expect(PDFDocument(url: url)?.string?.contains("Header") == true, "native PDF omits table content")
            print("Markdown print preview: \(url.path)")
        }
        if !failures.isEmpty {
            throw NSError(domain: "mdwrite.markdown", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "; ")])
        }
        print("PASS: Markdown element styling and native Enter key")
    }
}
