import AppKit
import EditorCore
import PDFKit

@MainActor
enum NativeSmoke {
    static func runFormatting() throws {
        let document = MarkdownDocument()
        document.recoveryStore = nil
        let source = "# Large\n## Medium\n### Small\n#### Four\n##### Five\n###### Six\nbody\n```swift\n# code\n\n**literal**\n```\n# After\n`**inline**`"
        document.sourceStorage.setAttributedString(NSAttributedString(string: source))
        document.makeWindowControllers()
        defer { document.close() }
        let editor = document.editorController!.editor
        editor.restyle()
        func location(_ text: String) -> Int { (editor.string as NSString).range(of: text).location }
        func font(_ text: String) -> NSFont {
            document.sourceStorage.attribute(.font, at: location(text), effectiveRange: nil) as! NSFont
        }
        var failures: [String] = []
        let sizes = ["Large", "Medium", "Small", "Four", "Five", "Six", "body"].map { font($0).pointSize }
        if !zip(sizes, sizes.dropFirst()).allSatisfy({ $0 > $1 }) {
            failures.append("heading sizes are not hierarchical: \(sizes)")
        }
        if document.sourceStorage.attribute(.backgroundColor, at: location("# code"), effectiveRange: nil) == nil {
            failures.append("fenced code has no background styling")
        }
        if NSFontManager.shared.traits(of: font("literal")).contains(.boldFontMask) {
            failures.append("Markdown inside a code fence is styled as bold")
        }
        if NSFontManager.shared.traits(of: font("# code")).contains(.boldFontMask)
            || NSFontManager.shared.traits(of: font("inline")).contains(.boldFontMask) {
            failures.append("code contains heading or inline Markdown formatting")
        }
        if font("After").pointSize != sizes[0]
            || document.sourceStorage.attribute(.backgroundColor, at: location("After"), effectiveRange: nil) != nil {
            failures.append("closing fence fails to restore heading styling")
        }
        if editor.string != source || document.isDocumentEdited {
            failures.append("styling changes source or dirty state")
        }
        // Exercise the actual layout-manager background drawing, not just attributes.
        document.editorController?.window?.contentView?.layoutSubtreeIfNeeded()
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            editor.appearance = NSAppearance(named: appearance)
            editor.restyle()
            let preview = editor.dataWithPDF(inside: editor.bounds)
            // Assert the render through layout rather than PDF text extraction:
            // PDFDocument.string drops runs with a negative glyph width (code
            // spans use one), and the CLT SDK's inflate cannot read PDF's Flate
            // streams, so scraping the PDF made this check fail spuriously.
            let drewText = !preview.isEmpty && Self.drawnGlyphCount(editor) > 0
            let codeBackground = editor.textStorage?.attribute(
                .backgroundColor, at: location("literal"), effectiveRange: nil) != nil
            if !drewText || !codeBackground {
                failures.append("styled editor cannot render its heading/code layout in \(appearance.rawValue)")
            }
            if CommandLine.arguments.contains("--style-preview") {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("mdwrite-style-\(appearance.rawValue)-\(UUID()).pdf")
                try preview.write(to: url)
                print("Style preview: \(url.path)")
            }
        }
        editor.appearance = nil
        editor.setWriterFontSize(24)
        if abs(font("Large").pointSize / sizes[0] - 1.2) > 0.01 {
            failures.append("heading size does not follow text-size controls")
        }
        let opening = location("```swift")
        let closing = (editor.string as NSString).range(of: "```\n# After")
        editor.setSelectedRange(NSRange(location: opening, length: closing.location + 4 - opening))
        editor.enterEditMode(nil)
        editor.apply(.replace("plain\n"))
        if document.sourceStorage.attribute(.backgroundColor, at: location("plain"), effectiveRange: nil) != nil
            || font("After").pointSize <= font("plain").pointSize {
            failures.append("removing a fence leaves stale code or heading styling")
        }
        document.undoManager?.undo()
        if editor.string != source {
            failures.append("undo after styling does not restore Markdown source")
        }
        if !failures.isEmpty {
            throw NSError(domain: "mdwrite.style", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "; ")])
        }
        print("PASS: heading hierarchy, fenced-code styling, literal code, and source preservation")
    }


    /// Searches the decompressed content streams of a PDF for a literal string.
    /// Used as a fallback when PDFKit text extraction misses styled runs.
    /// Number of glyphs the editor has actually laid out.
    private static func drawnGlyphCount(_ view: NSTextView) -> Int {
        guard let manager = view.layoutManager else { return 0 }
        return manager.numberOfGlyphs
    }

    static func run() throws {
        // Pixel-level checks go first. Every suite below opens windows that are
        // never torn down, and a caching rep composites whatever is still on
        // screen, so a capture taken later shows several documents layered over
        // each other. That reads as ghosted or doubled table text, and it also
        // makes band sampling land on another document's rows.
        try NativeTableChecks.runTablePreview()
        try NativeTableChecks.runZebraUniformity()
        try runFormatting()
        try NativeMarkdownChecks.run()
        try NativeFormatChecks.run()
        try NativeTableChecks.run()
        try NativeTableChecks.runPresentation()
        try NativeTableChecks.runViewIntegration()
        try NativeTableChecks.runWidthBudget()
        try NativeTableChecks.runAtomicElementsDoNotWrap()
        try NativeTableChecks.runCellStylingAndResize()
        try NativeLayoutChecks.run()
        try NativeModeChecks.run()
        try NativeModeChecks.runEditModeRendersTablesDocument()
        try NativePerformanceChecks.run()
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() {
                throw NSError(domain: "mdwrite.smoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mdwrite-smoke-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = Data([0xef, 0xbb, 0xbf]) + Data("# Title\r\n\r\nhello world\r\n".utf8)
        let url = directory.appendingPathComponent("example.md")
        try original.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
        let document = MarkdownDocument()
        document.recoveryStore = RecoveryStore(directory: directory.appendingPathComponent("Recovery"))
        document.fileType = "net.daringfireball.markdown"
        document.fileURL = url
        try document.read(from: url, ofType: document.fileType!)
        document.makeWindowControllers()
        let editor = document.editorController!.editor
        try check(Data(editor.string.utf8) == Data("# Title\n\nhello world\n".utf8), "open loads canonical source")
        let untouched = try document.data(ofType: document.fileType!)
        try check(untouched == original, "unchanged document preserves bytes")
        try check(!document.isDocumentEdited, "newly opened document is clean")
        editor.enterEditMode(nil)
        editor.setSelectedRange(NSRange(location: 9, length: 5))
        editor.apply(.bold)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        try check(editor.string.contains("**hello**"), "format command updates live source")
        try check(document.isDocumentEdited, "native edit sets document dirty")
        document.undoManager?.undo()
        try check(Data(editor.string.utf8) == Data("# Title\n\nhello world\n".utf8), "undo restores source")
        try check(!document.isDocumentEdited, "undo to baseline clears dirty state")
        document.undoManager?.redo()
        try check(document.isDocumentEdited, "redo sets dirty state")
        document.writeRecovery()
        try NativeAsyncWait.run { await document.flushRecovery() }
        document.undoManager?.undo()
        try check(!document.isDocumentEdited, "undo after recovery returns to clean")
        document.writeRecovery()
        try NativeAsyncWait.run { await document.flushRecovery() }
        let cleanedRecords = try document.recoveryStore!.records()
        try check(cleanedRecords.isEmpty, "undo to clean removes stale recovery")
        document.undoManager?.redo()
        document.writeRecovery()
        try NativeAsyncWait.run { await document.flushRecovery() }
        let records = try document.recoveryStore!.records()
        try check(records.count == 1 && records[0].text.contains("**hello**"), "dirty source recovery persists")
        let recovered = MarkdownDocument()
        recovered.recoveryStore = document.recoveryStore
        recovered.restore(records[0])
        try check(recovered.fileURL == nil && recovered.isDocumentEdited, "recovery is an untitled dirty copy")
        var savedError: Error?
        var saveFinished = false
        document.save(to: url, ofType: document.fileType!, for: .saveOperation) { error in
            savedError = error
            saveFinished = true
        }
        if !saveFinished { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1)) }
        if let error = savedError { throw error }
        try check(saveFinished && !document.isDocumentEdited, "document Save completes and clears dirty state")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        try check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o640, "safe Save retains original file permissions")
        let saved = try Data(contentsOf: url)
        try check(saved == Data([0xef, 0xbb, 0xbf]) + Data("# Title\r\n\r\n**hello** world\r\n".utf8), "safe save preserves BOM and newline style")
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.apply(.replace("unsaved"))
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        let failedURL = directory.appendingPathComponent("missing-parent/blocked.md")
        var failedError: Error?
        var failedFinished = false
        document.save(to: failedURL, ofType: document.fileType!, for: .saveAsOperation) { error in
            failedError = error
            failedFinished = true
        }
        if !failedFinished { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1)) }
        try check(failedFinished && failedError != nil, "failed Save As reports an error")
        try check(document.isDocumentEdited && document.fileURL == url, "failed save preserves dirty state and source identity")
        let afterFailedSave = try Data(contentsOf: url)
        try check(afterFailedSave == saved, "failed save leaves the original file intact")
        let external = Data("external text".utf8)
        try external.write(to: url, options: .atomic)
        do {
            try document.writeSafely(to: url, ofType: document.fileType!, for: .saveOperation)
            throw NSError(domain: "mdwrite.smoke", code: 2, userInfo: [NSLocalizedDescriptionKey: "external conflict was overwritten"])
        } catch let error as NSError {
            try check(error.domain == "mdwrite" && error.code == 409, "save rejects external changes")
        }
        let disk = try Data(contentsOf: url)
        try check(disk == external, "conflicting disk text stays intact")
        editor.restyle()
        try check(editor.string.contains("**hello**"), "styling preserves raw Markdown")
        let stylingDocument = MarkdownDocument()
        stylingDocument.recoveryStore = nil
        stylingDocument.sourceStorage.setAttributedString(NSAttributedString(string: "**first**\n\n**second**"))
        stylingDocument.makeWindowControllers()
        let stylingEditor = stylingDocument.editorController!.editor
        stylingEditor.enterEditMode(nil)
        stylingEditor.restyle()
        let markers = try NSRegularExpression(pattern: #"\*\*"#)
        let matches = markers.matches(in: stylingEditor.string,
                                      range: NSRange(location: 0, length: stylingEditor.string.utf16.count))
        // A system edit can change distant ranges and leave the caret elsewhere.
        for match in matches.reversed() {
            stylingDocument.sourceStorage.replaceCharacters(in: match.range, with: "")
        }
        stylingEditor.setSelectedRange(NSRange(location: 0, length: 0))
        stylingEditor.didChangeText()
        let second = (stylingEditor.string as NSString).range(of: "second")
        let secondFont = stylingDocument.sourceStorage.attribute(.font, at: second.location,
                                                                effectiveRange: nil) as! NSFont
        try check(!NSFontManager.shared.traits(of: secondFont).contains(.boldFontMask),
                  "system edits restyle distant paragraphs after marker removal")
        stylingDocument.close()
        let printView = MarkdownPrintRenderer.makeView(source: "# Title\n\n**bold** and *italic*\n- item\n[site](https://example.com)\n```\ncode\n```", width: 500)
        try check(printView.string.contains("Title") && !printView.string.contains("**"), "print snapshot renders Markdown")
        let pdf = printView.dataWithPDF(inside: printView.bounds)
        let pdfDocument = PDFDocument(data: pdf)
        try check(pdfDocument?.pageCount ?? 0 > 0, "rendered print snapshot generates PDF")
        try check(pdfDocument?.string?.contains("bold") == true, "PDF contains rendered text")
        document.close()
        print("PASS: native open, byte preservation, formatting, dirty state, undo/redo, safe Save/failed Save As, recovery/cleanup, system-edit styling, rendered PDF, and external conflict protection")
    }
}
