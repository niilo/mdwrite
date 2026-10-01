import AppKit
import EditorCore

@MainActor
enum NativeAsyncWait {
    static func run(_ work: @escaping @MainActor () async throws -> Void) throws {
        var finished = false
        var failure: Error?
        Task { @MainActor in
            do { try await work() } catch { failure = error }
            finished = true
        }
        let deadline = Date(timeIntervalSinceNow: 30)
        while !finished && Date() < deadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005)) }
        guard finished else { throw NSError(domain: "mdwrite.check", code: 1, userInfo: [NSLocalizedDescriptionKey: "Async check timed out"]) }
        if let failure { throw failure }
    }
}

@MainActor
enum NativePerformanceChecks {
    static func run() throws {
        try NativeStorageChecks.run()
        try NativeStylePlanChecks.run()
        try NativeControlledAnalysisChecks.run()
        func expect(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: "mdwrite.performance", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        let fixture = "# Heading 👩‍💻\n\n***both*** ~~deleted~~ [link](https://example.org) `**literal**`\n\n> > quote\n> - [x] done\n\nTitle\n===\n\n| Head | Second |\n| --- | --- |\n| row | value |\n\n```swift\n# literal\n**literal**\n```\n\n    indented\n\n[ref][label]\n\n[label]: https://example.org\n\n---\n\n![image](image.png) &amp; \\*escape* <b>raw</b> [^note]\n\n[^note]: content\n\n"
        // Differential presentation oracle: compare all managed attributes,
        // including dynamic colors, independently of plan segmentation.
        let reference = NSTextStorage(string: fixture)
        _ = MarkdownStyler.apply(to: reference, fontSize: 20)
        let candidate = NSTextStorage(string: fixture)
        let plan = MarkdownStylePlanBuilder.build(MarkdownAnalysis.analyze(fixture))
        var paragraphs: [Int: StyleParagraphValue] = [:]
        for run in plan.runs {
            let paragraph = (fixture as NSString).paragraphRange(for: run.range)
            if let previous = paragraphs[paragraph.location] {
                try expect(previous == run.style.paragraph, "a paragraph contains conflicting style geometry")
            }
            paragraphs[paragraph.location] = run.style.paragraph
        }
        for run in plan.runs {
            MarkdownStyler.applyChanged(MarkdownStyler.attributes(for: run.style, fontSize: 20), to: candidate, range: run.range)
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            var discrepancy: String?
            NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                for index in 0..<reference.length {
                    for key in MarkdownStyler.ownedKeys {
                        let a = reference.attribute(key, at: index, effectiveRange: nil)
                        let b = candidate.attribute(key, at: index, effectiveRange: nil)
                        let equal: Bool
                        if let a = a as? NSColor, let b = b as? NSColor {
                            equal = a.usingColorSpace(.deviceRGB) == b.usingColorSpace(.deviceRGB)
                        } else { equal = a == nil && b == nil || (a as? NSObject)?.isEqual(b) == true }
                        if !equal { discrepancy = "style mismatch at \(index) for \(key.rawValue) in \(appearance.rawValue)"; return }
                    }
                }
            }
            try expect(discrepancy == nil, discrepancy ?? "")
        }

        let document = MarkdownDocument()
        document.recoveryStore = nil
        let source = String(repeating: fixture, count: 100)
        document.sourceStorage.setAttributedString(NSAttributedString(string: source))
        let captured = document.sourceStorage.string
        document.sourceStorage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "!")
        try expect(captured == source, "text storage mutation changed an immutable Swift snapshot")
        document.sourceStorage.setAttributedString(NSAttributedString(string: source))
        document.makeWindowControllers()
        let editor = document.editorController!.editor
        editor.setMode(.edit)
        func settle() throws {
            let deadline = Date(timeIntervalSinceNow: 20)
            while editor.stylingIsPending && Date() < deadline {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))
            }
            try expect(!editor.stylingIsPending, "background styles never settled (\(editor.pendingAnalysisDescription), revision \(editor.analysisRevision), stages \(editor.mainThreadStageMaxima), background \(editor.backgroundPhaseMaxima))")
        }
        try settle()
        let original = editor.string
        editor.setSelectedRange(NSRange(location: 2, length: 7))
        editor.apply(.replace("New"))
        editor.setSelectedRange(NSRange(location: 2, length: 3))
        editor.apply(.replace("Current"))
        try settle()
        try expect(editor.string.hasPrefix("# Current"), "background analysis changed source or installed an old revision")
        let font = document.sourceStorage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
        try expect(font?.pointSize == 36, "current heading styling failed to converge")
        let edited = editor.string
        let dirty = document.isDocumentEdited
        let selection = editor.selectedRange()
        let foreign = NSAttributedString.Key("mdwrite.check.foreign-decoration")
        document.sourceStorage.addAttribute(foreign, value: "preserve", range: NSRange(location: 2, length: 3))
        let findHighlight = NSColor.systemYellow
        editor.layoutManager?.addTemporaryAttribute(.backgroundColor, value: findHighlight,
                                                   forCharacterRange: NSRange(location: 2, length: 3))
        editor.setWriterFontSize(24)
        editor.appearance = NSAppearance(named: .darkAqua)
        try settle()
        try expect(editor.string == edited && editor.selectedRange() == selection && document.isDocumentEdited == dirty,
                   "presentation changed source/selection/dirty state")
        try expect(document.sourceStorage.attribute(foreign, at: 2, effectiveRange: nil) as? String == "preserve",
                   "styling removed an unmanaged source decoration")
        try expect((editor.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: 2,
                                                            effectiveRange: nil) as? NSColor)?.isEqual(findHighlight) == true,
                   "presentation removed a native temporary Find highlight")
        editor.undo(nil); editor.undo(nil)
        try settle()
        try expect(editor.string == original, "background styles corrupted native undo")
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        editor.setMarkedText("compose", selectedRange: NSRange(location: 7, length: 0), replacementRange: editor.selectedRange())
        let composed = editor.string
        editor.restyle()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        try expect(editor.hasMarkedText() && editor.string == composed, "pending styles disturbed marked text")
        editor.unmarkText()
        try settle()
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.apply(.replace("pending"))
        document.close()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        try expect(!editor.stylingIsPending, "closed document retained pending styling")

        // Supersede an already-running full parse with a load, then close a
        // second active worker. Neither result may resurrect old attributes.
        let loading = MarkdownDocument()
        loading.recoveryStore = nil
        let large = "# Obsolete\n\n" + String(repeating: "ordinary prose line\n\n", count: 60000)
        loading.sourceStorage.setAttributedString(NSAttributedString(string: large))
        loading.makeWindowControllers()
        let loadingEditor = loading.editorController!.editor
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        try loading.read(from: Data("# Current\n\n````\n# literal\n````\n".utf8), ofType: "net.daringfireball.markdown")
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
        try expect(loadingEditor.string == "# Current\n\n````\n# literal\n````\n", "stale parse changed reloaded source")
        let literal = (loadingEditor.string as NSString).range(of: "# literal").location
        try expect(loading.sourceStorage.attribute(.mdwriteCodeBackground, at: literal, effectiveRange: nil) != nil,
                   "stale large parse replaced reloaded code styling")
        loading.sourceStorage.setAttributedString(NSAttributedString(string: large))
        loadingEditor.restyle()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        loading.close()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        try expect(!loadingEditor.stylingIsPending, "closed active worker remained pending")
        try NativeAsyncWait.run { try await NativeServiceChecks.run() }
        print("PASS: style-plan parity, revision-safe background styling, undo, composition, close, and service ordering")
    }
}
