import AppKit

/// Hold actual worker results instead of guessing when a background parse ends.
@MainActor
enum NativeControlledAnalysisChecks {
    static func run() throws {
        func expect(_ condition: Bool, _ message: String) throws {
            if !condition {
                throw NSError(domain: "mdwrite.analysis-ordering", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        var deliveries: [(MarkdownAnalysisPhase, @MainActor () -> Void)] = []
        func waitFor(_ predicate: () -> Bool) throws {
            let deadline = Date(timeIntervalSinceNow: 20)
            while !predicate() && Date() < deadline {
                autoreleasepool { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005)) }
            }
            try expect(predicate(), "controlled analysis delivery timed out")
        }
        let document = MarkdownDocument()
        document.recoveryStore = nil
        let source = "# Heading\n\n[remote][far]\n\n" + String(repeating: "ordinary paragraph\n\n", count: 10_000)
            + "[far]: https://example.org\n"
        document.sourceStorage.setAttributedString(NSAttributedString(string: source))
        document.makeWindowControllers()
        let editor = document.editorController!.editor
        editor.setMode(.edit)
        editor.configureAnalysisDelivery { phase, work in deliveries.append((phase, work)) }
        defer { document.close() }
        try waitFor { deliveries.count == 2 }

        editor.setSelectedRange(NSRange(location: 50, length: 0))
        editor.setMarkedText("é👩🏽‍💻", selectedRange: NSRange(location: 0, length: 0),
                             replacementRange: editor.selectedRange())
        editor.setWriterFontSize(24)
        editor.appearance = NSAppearance(named: .darkAqua)
        let markedRange = editor.markedRange()
        let composed = editor.string
        let probes = [0, 12, markedRange.location, markedRange.location + markedRange.length - 1]
        let before = probes.map { NSDictionary(dictionary: document.sourceStorage.attributes(at: $0, effectiveRange: nil)) }
        let obsolete = deliveries
        deliveries.removeAll()
        for (_, work) in obsolete { work() }
        try expect(editor.hasMarkedText() && editor.markedRange() == markedRange && editor.string == composed,
                   "obsolete analysis changed composition or source")
        for (index, offset) in probes.enumerated() {
            try expect(before[index].isEqual(to: document.sourceStorage.attributes(at: offset, effectiveRange: nil)),
                       "analysis or presentation changed attributes during composition")
        }

        editor.unmarkText()
        try waitFor { deliveries.count == 2 }
        let latest = deliveries
        deliveries.removeAll()
        // Complete semantics must win even if its provisional prefix arrives later.
        latest.first { $0.0 == .complete }!.1()
        latest.first { $0.0 == .preview }!.1()
        try waitFor { !editor.stylingIsPending }
        let remote = (editor.string as NSString).range(of: "remote").location
        try expect(document.sourceStorage.attribute(.underlineStyle, at: remote, effectiveRange: nil) as? Int == 1,
                   "late prefix overwrote complete distant-reference semantics")
        let font = document.sourceStorage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
        try expect(abs((font?.pointSize ?? 0) - 43.2) < 0.01, "held result used obsolete font size")

        editor.setSelectedRange(NSRange(location: 2, length: 7))
        editor.apply(.replace("Pending"))
        try waitFor { deliveries.contains { $0.0 == .complete } }
        let pending = deliveries
        deliveries.removeAll()
        let replacement = "# Reloaded\n\n```\n**literal**\n```\n"
        try document.read(from: Data(replacement.utf8), ofType: "net.daringfireball.markdown")
        for (_, work) in pending { work() }
        try expect(editor.string == replacement, "held result replaced reloaded source")
        let literal = (replacement as NSString).range(of: "**literal**").location
        try expect(document.sourceStorage.attribute(.mdwriteCodeBackground, at: literal, effectiveRange: nil) != nil,
                   "held result removed current reload decorations")

        try document.read(from: Data(source.utf8), ofType: "net.daringfireball.markdown")
        try waitFor { deliveries.count == 2 }
        let closing = deliveries
        deliveries.removeAll()
        let retained = editor.string
        document.close()
        for (_, work) in closing { work() }
        try expect(editor.string == retained && !editor.stylingIsPending, "held callback resurrected closed analysis")
        print("PASS: controlled preview/full ordering, composition attributes, presentation, reload, and close")
    }
}
