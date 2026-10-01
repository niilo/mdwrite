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

        let gate = AnalysisCheckpointGate()
        let cancellationDocument = MarkdownDocument()
        cancellationDocument.recoveryStore = nil
        cancellationDocument.sourceStorage.setAttributedString(NSAttributedString(string: source))
        cancellationDocument.makeWindowControllers()
        let cancellationEditor = cancellationDocument.editorController!.editor
        cancellationEditor.setMode(.edit)
        var cancelledDeliveries: [(MarkdownAnalysisPhase, @MainActor () -> Void)] = []
        cancellationEditor.configureAnalysisDelivery(afterAnalysis: { gate.checkpoint() },
                                                     afterWorkerCompletion: { gate.finish() }) { phase, work in
            cancelledDeliveries.append((phase, work))
        }
        defer { gate.release(); cancellationDocument.close() }
        try waitFor { gate.analysisCount == 1 }
        cancellationEditor.setSelectedRange(NSRange(location: 2, length: 7))
        cancellationEditor.apply(.replace("Current"))
        let currentSource = cancellationEditor.string
        gate.release()
        // No obsolete complete delivery is needed to release the cancelled
        // worker. Its successor must run while result callbacks are still held.
        do {
            try waitFor { gate.analysisCount >= 2 && cancelledDeliveries.contains { $0.0 == .complete } }
        } catch {
            throw NSError(domain: "mdwrite.analysis-ordering", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Cancelled worker blocked its successor (analyses=\(gate.analysisCount))"])
        }
        try expect(!gate.timedOut && cancelledDeliveries.filter { $0.0 == .complete }.count == 1,
                   "cancelled snapshot built or delivered an obsolete complete style plan")
        let currentDeliveries = cancelledDeliveries
        cancelledDeliveries.removeAll()
        currentDeliveries.first { $0.0 == .complete }!.1()
        for (phase, work) in currentDeliveries where phase == .preview { work() }
        try waitFor { !cancellationEditor.stylingIsPending }
        try expect(cancellationEditor.string == currentSource && currentSource.hasPrefix("# Current\n"),
                   "cancelled worker changed the latest source")
        try expect((cancellationDocument.sourceStorage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)?.pointSize == 36,
                   "successor analysis did not install current heading styling")
        cancellationEditor.setSelectedRange(NSRange(location: 2, length: 7))
        cancellationEditor.apply(.replace("Held"))
        try waitFor { gate.completionCount >= 3 && cancelledDeliveries.contains { $0.0 == .complete } }
        let heldFinished = cancelledDeliveries
        cancelledDeliveries.removeAll()
        cancellationEditor.setSelectedRange(NSRange(location: 2, length: 4))
        cancellationEditor.apply(.replace("Latest\n\n```swift\nliteral\n```\n\n"))
        do {
            try waitFor { gate.completionCount >= 4 && cancelledDeliveries.contains { $0.0 == .complete } }
        } catch {
            throw NSError(domain: "mdwrite.analysis-ordering", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Finished obsolete delivery blocked its successor"])
        }
        let finalDeliveries = cancelledDeliveries
        cancelledDeliveries.removeAll()
        // These late callbacks must not clear the newer worker or styling cursor.
        for (_, work) in heldFinished { work() }
        for (_, work) in finalDeliveries { work() }
        try waitFor { !cancellationEditor.stylingIsPending }
        try expect(cancellationEditor.string.hasPrefix("# Latest\n"),
                   "finished obsolete result replaced the latest revision")
        let currentLiteral = (cancellationEditor.string as NSString).range(of: "literal").location
        try expect(cancellationDocument.sourceStorage.attribute(.mdwriteCodeBackground, at: currentLiteral,
                                                               effectiveRange: nil) != nil,
                   "finished obsolete result removed the latest code styling")
        print("PASS: controlled preview/full ordering, composition attributes, presentation, reload, and close")
    }
}

/// Only the worker waits. The main actor polls protected state and keeps
/// delivering events, including the edit that cancels the first snapshot.
private final class AnalysisCheckpointGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var count = 0
    private var completions = 0
    private var released = false
    private var expired = false
    var analysisCount: Int {
        condition.lock(); defer { condition.unlock() }
        return count
    }
    var timedOut: Bool {
        condition.lock(); defer { condition.unlock() }
        return expired
    }
    var completionCount: Int {
        condition.lock(); defer { condition.unlock() }
        return completions
    }
    func finish() {
        condition.lock(); defer { condition.unlock() }
        completions += 1
    }
    func checkpoint() {
        condition.lock(); defer { condition.unlock() }
        count += 1
        guard count == 1 else { return }
        let deadline = Date(timeIntervalSinceNow: 20)
        while !released {
            if !condition.wait(until: deadline) { expired = true; return }
        }
    }
    func release() {
        condition.lock(); defer { condition.unlock() }
        released = true
        condition.broadcast()
    }
}
