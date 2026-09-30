import AppKit
import EditorCore
import PDFKit

@MainActor
enum NativeSmoke {
    static func run() throws {
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
        document.undoManager?.undo()
        try check(!document.isDocumentEdited, "undo after recovery returns to clean")
        document.writeRecovery()
        let cleanedRecords = try document.recoveryStore!.records()
        try check(cleanedRecords.isEmpty, "undo to clean removes stale recovery")
        document.undoManager?.redo()
        document.writeRecovery()
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
