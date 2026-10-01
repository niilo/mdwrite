import AppKit
import CoreText
import EditorCore
import Darwin
import CryptoKit

/// Diagnostic only: synthetic text, a separate process, and no recovery or file writes.
@main
@MainActor
struct LargeDocumentBaseline {
    static func main() {
        let fontsBeforeApp = !CommandLine.arguments.contains("--fonts-after-app")
        if !fontsBeforeApp { NSApplication.shared.setActivationPolicy(.prohibited) }
        print("diagnostic_pid=\(getpid())")
        fflush(stdout)
        let kib = Int(CommandLine.arguments[1])!
        let filePath = option("--file", default: "")
        let family = filePath.isEmpty ? option("--fixture", default: "baseline") : "file"
        let source: String
        if !filePath.isEmpty {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
                source = try MarkdownEncoding(data: data).text
                let inputHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                print("input provenance=user_authorized_copy bytes=\(data.count) sha256=\(inputHash) decoded_with_native_encoding=true")
            } catch {
                print("FAIL: input could not be read as UTF-8 Markdown")
                exit(2)
            }
        } else { source = fixture(family, kib: kib) }
        let hash = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        print("fixture family=\(family) sha256=\(hash)")
        print("fixture bytes=\(source.utf8.count) utf16=\(source.utf16.count)")
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        let logicalLines = lines.count - (source.hasSuffix("\n") ? 1 : 0)
        let words = EditorBehavior.wordCount(source)
        print("fixture logical_lines=\(logicalLines) LF_count=\(source.filter { $0 == "\n" }.count) words=\(words) max_line_utf16=\(lines.map { $0.utf16.count }.max() ?? 0) max_line_bytes=\(lines.map { $0.utf8.count }.max() ?? 0)")
        if family == "reported" {
            precondition(logicalLines == 4996 && words == 30558, "Reported-scale fixture counts changed")
            print("fixture provenance=synthetic_reported_counts original_bytes_and_longest_line_unknown size_independent_of_kib=true")
        }
        fflush(stdout)

        if let index = CommandLine.arguments.firstIndex(of: "--fonts") {
            let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            for face in ["Regular", "Bold", "Italic", "BoldItalic"] {
                let url = directory.appendingPathComponent("iAWriterMonoS-\(face).ttf")
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }

        // Match the real application's stable-font opening phase: process the
        // font-set notifications queued by process-local font registration
        // before any large NSTextStorage exists. Live font updates stay enabled.
        print("font-setup application_already_created=\(NSApp != nil) ordering=\(fontsBeforeApp ? "fonts-before-app" : "app-before-fonts")")
        let fontSetupStart = ProcessInfo.processInfo.systemUptime
        if CommandLine.arguments.contains("--fonts") {
            for face in ["Regular", "Bold", "Italic", "BoldItalic"] {
                _ = NSFont(name: "iAWriterMonoS-\(face)", size: 20)
            }
            pump(0.2)
        }
        print("font-setup after_drain_application_created=\(NSApp != nil)")
        if fontsBeforeApp { NSApplication.shared.setActivationPolicy(.prohibited) }
        print("font-registration-notification-setup ms=\(String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - fontSetupStart) * 1000))")
        fflush(stdout)

        if CommandLine.arguments.contains("--stages") {
            var runCount = 0
            var blockCount = 0
            var spanCount = 0
            _ = measure("semantic-parse+source-map") { runCount = MarkdownSyntax.runs(in: source).count }
            _ = measure("block-scan") { blockCount = MarkdownBlocks.parse(source).count }
            _ = measure("inline-scan") { spanCount = MarkdownSpans.inline(in: source).count }
            print("counts runs=\(runCount) blocks=\(blockCount) spans=\(spanCount)")
            let storage = NSTextStorage(string: source)
            _ = measure("semantic-parse+source-map (text-storage-string)") {
                runCount = MarkdownSyntax.runs(in: storage.string).count
            }
            let snapshot = String(decoding: storage.string.utf8, as: UTF8.self)
            guard snapshot == source else { exit(2) }
            _ = measure("semantic-parse+source-map (materialized-UTF8-snapshot)") {
                runCount = MarkdownSyntax.runs(in: snapshot).count
            }
            _ = measure("Foundation-parse-only (text-storage-string)") {
                let parsed = try? AttributedString(markdown: storage.string, options: .init(
                    interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible,
                    appliesSourcePositionAttributes: true))
                runCount = parsed?.runs.count ?? 0
            }
            print("last measured run count=\(runCount)")
            _ = measure("styler-without-layout-manager") {
                _ = MarkdownStyler.apply(to: storage, fontSize: 20)
            }
            _ = measure("smart-Return-analysis") {
                _ = try? EditorBehavior.edit(.insertReturn(soft: false), in: source,
                                             selection: NSRange(location: 15, length: 0))
            }
            return
        }

        let services = CommandLine.arguments.contains("--services")
        let isolatedDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("mdwrite-benchmark-\(UUID().uuidString)", isDirectory: true)
        defer { if services { try? FileManager.default.removeItem(at: isolatedDirectory) } }
        let document = MarkdownDocument()
        var sourceLoadMilliseconds = 0.0
        if services {
            do {
                try FileManager.default.createDirectory(at: isolatedDirectory, withIntermediateDirectories: true)
                let fixtureURL = isolatedDirectory.appendingPathComponent("synthetic.md")
                try Data(source.utf8).write(to: fixtureURL)
                document.recoveryStore = RecoveryStore(directory: isolatedDirectory.appendingPathComponent("Recovery", isDirectory: true))
                sourceLoadMilliseconds = measure("source-load-named-read+decode+storage") {
                    do { try document.read(from: fixtureURL, ofType: "net.daringfireball.markdown") }
                    catch { print("FAIL: source read: \(error)"); exit(2) }
                }
                document.fileURL = fixtureURL
            } catch { print("FAIL: isolated service fixture setup: \(error)"); exit(2) }
        } else {
            document.recoveryStore = nil
            sourceLoadMilliseconds = measure("source-load-storage") {
                document.sourceStorage.setAttributedString(NSAttributedString(string: source))
            }
        }
        let windowMilliseconds = measure("window+initial-style") { document.makeWindowControllers() }
        print("total-source-load+window-ready ms=\(String(format: "%.1f", sourceLoadMilliseconds + windowMilliseconds))")
        let editor = document.editorController!.editor
        editor.setMode(.edit)
        if CommandLine.arguments.contains("--no-background-layout") {
            editor.layoutManager?.backgroundLayoutEnabled = false
            print("diagnostic: native idle background layout disabled")
        }
        if CommandLine.arguments.contains("--interactive") {
            let passed = interactive(document: document, source: source, windowMilliseconds: sourceLoadMilliseconds + windowMilliseconds)
            document.close()
            let drained = flushRecovery(document, timeout: 10)
            memory("after-original-close")
            let cycles = Int(option("--close-cycles", default: "0"))!
            var cyclesSettled = true
            for cycle in 0..<cycles {
                weak var closedDocument: MarkdownDocument?
                weak var closedEditor: MarkdownTextView?
                let completed = autoreleasepool {
                    let fresh = MarkdownDocument()
                    fresh.recoveryStore = nil
                    fresh.sourceStorage.setAttributedString(NSAttributedString(string: source))
                    fresh.makeWindowControllers()
                    closedDocument = fresh
                    closedEditor = fresh.editorController!.editor
                    let ready = settled(fresh.editorController!.editor, timeout: Double(option("--settle-timeout", default: "30"))!)
                    fresh.close()
                    return ready
                }
                let releaseDeadline = ProcessInfo.processInfo.systemUptime + 2
                repeat { pump(0.05) } while (closedDocument != nil || closedEditor != nil)
                    && ProcessInfo.processInfo.systemUptime < releaseDeadline
                let released = closedDocument == nil && closedEditor == nil
                print("close-cycle-\(cycle + 1) document_released=\(closedDocument == nil) editor_released=\(closedEditor == nil)")
                memory("after-close-cycle-\(cycle + 1)")
                cyclesSettled = cyclesSettled && completed && released
            }
            exit(passed && drained && cyclesSettled ? 0 : 1)
        }
        editor.setSelectedRange(NSRange(location: 15, length: 0))
        let elapsed = measure("native-insertText") {
            editor.insertText("x", replacementRange: editor.selectedRange())
        }
        let correct = (editor.string as NSString).substring(with: NSRange(location: 15, length: 1)) == "x"
        document.close()
        if !correct {
            print("FAIL: native insertion did not update the source")
            exit(2)
        }
        let passed = elapsed <= 100
        print("\(passed ? "PASS" : "FAIL"): synchronous typing stall <=100 ms")
        exit(passed ? 0 : 1)
    }

    private static func option(_ name: String, default fallback: String) -> String {
        guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else {
            return fallback
        }
        return CommandLine.arguments[index + 1]
    }

    private static func fixture(_ family: String, kib: Int) -> String {
        if family == "reported" { return reportedFixture() }
        let baseline = "# Heading\n\nA paragraph with **bold**, *italic*, and [link](https://example.org).\n\n> A quote\n\n- list item\n\n```swift\nlet value = 1\n```\n\n"
        let unit: String
        switch family {
        case "prose": unit = "A plain paragraph contains words and sentences, with room to wrap naturally.\n\n"
        case "dense": unit = "**bold** *italic* ~~strike~~ `literal` [link](https://example.org) ![image](asset.png)\n\n| a | b |\n|---|---|\n| c | d |\n\n> > quote\n> - list\n>   - child\n\n"
        case "fences": unit = "```swift\nlet value = 1 // **literal**\n```\n\n~~~\n# literal heading\n~~~\n\n"
        case "unicode": unit = "A 👩🏽‍💻 paragraph with e\u{301}, 日本語, **tärkeä**, *κόσμος*, and [🚀](https://example.org).\n\n"
        case "longline": unit = "unbroken"
        default: unit = baseline
        }
        let target = kib * 1024
        if family == "baseline" {
            return String(repeating: unit, count: (target + unit.utf8.count - 1) / unit.utf8.count)
        }
        // Common sentinels test real heading/code styling at both ends, plus a
        // reference use whose definition is distant from the first viewport.
        let prefix = "# Heading\n\n[remote][reference]\n\n```swift\nlet sentinel = 1\n```\n\n"
        let suffix = "\n\n# Final heading\n\n[reference]: https://example.org\n\n```swift\nlet finalSentinel = 2\n```\n"
        return prefix + String(repeating: unit, count: max(1, (target - prefix.utf8.count - suffix.utf8.count + unit.utf8.count - 1) / unit.utf8.count)) + suffix
    }

    /// Fixed reported counts, not a reconstruction of the user's document.
    /// Each array entry is one LF-terminated logical line, including blanks.
    private static func reportedFixture() -> String {
        let prefix = ["# Heading", "", "[remote][reference]", "", "```swift", "let sentinel = 1", "```", ""]
        let suffix = ["", "# Final heading", "", "[reference]: https://example.org", "", "```swift", "let finalSentinel = 2", "```"]
        var lines = prefix
        for section in 0..<180 {
            lines += ["## Section \(section)", "",
                      "**bold** *italic* ~~strike~~ `literal` [link](https://example.org) ![image](asset.png)", "",
                      "> > nested quote text", "> - listed quote item", ">   - child item", "",
                      "- [x] completed task", "1. ordered list item", "",
                      "| First | Second |", "| --- | --- |", "| cell | value |", "",
                      "```swift", "let value = 1 // literal content", "```", ""]
            if section == 59 || section == 119 || section == 179 {
                let length = section == 59 ? 10 * 1024 : section == 119 ? 20 * 1024 : 32 * 1024
                let unit = "paragraph "
                lines.append(String(repeating: unit, count: length / unit.utf16.count)
                             + String(unit.prefix(length % unit.utf16.count)))
            }
        }
        let fillerStart = lines.count
        let fillerCount = 4996 - lines.count - suffix.count
        precondition(fillerCount > 0)
        lines += Array(repeating: "", count: fillerCount)
        lines += suffix
        let initial = lines.joined(separator: "\n") + "\n"
        let remaining = 30558 - EditorBehavior.wordCount(initial)
        precondition(remaining >= 0)
        for index in 0..<fillerCount {
            let extra = remaining / fillerCount + (index < remaining % fillerCount ? 1 : 0)
            lines[fillerStart + index] = String(String(repeating: "word ", count: extra).dropLast())
        }
        let source = lines.joined(separator: "\n") + "\n"
        precondition(lines.count == 4996 && EditorBehavior.wordCount(source) == 30558)
        return source
    }

    private static func pump(_ seconds: TimeInterval = 0.015) {
        let deadline = Date(timeIntervalSinceNow: seconds)
        repeat {
            autoreleasepool { _ = RunLoop.main.run(mode: .default, before: deadline) }
        } while Date() < deadline
    }

    private static func settled(_ editor: MarkdownTextView, timeout: TimeInterval) -> Bool {
        let end = ProcessInfo.processInfo.systemUptime + timeout
        repeat {
            pump()
            if !editor.stylingIsPending { return true }
        } while ProcessInfo.processInfo.systemUptime < end
        return false
    }

    private static func key(_ editor: MarkdownTextView, characters: String, code: UInt16) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                    timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: editor.window?.windowNumber ?? 0, context: nil,
                                    characters: characters, charactersIgnoringModifiers: characters,
                                    isARepeat: false, keyCode: code)!
        editor.keyDown(with: event)
    }

    private static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * fraction)) - 1))]
    }

    private static func report(_ label: String, _ samples: [Double]) {
        print("\(label) samples=\(samples.count) p50_ms=\(String(format: "%.2f", percentile(samples, 0.5))) p95_ms=\(String(format: "%.2f", percentile(samples, 0.95))) max_ms=\(String(format: "%.2f", samples.max() ?? 0))")
        fflush(stdout)
    }

    private static func memory(_ label: String) {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        print("memory \(label) resident_MiB=\(result == KERN_SUCCESS ? String(format: "%.1f", Double(info.resident_size) / 1048576) : "unavailable") peak_MiB=\(String(format: "%.1f", Double(usage.ru_maxrss) / 1048576))")
        fflush(stdout)
    }

    private static var usesFile: Bool { !option("--file", default: "").isEmpty }

    /// Pure semantic oracle runs after the performance interval, never in a
    /// timed input/open callback. Inspect all managed keys without source output.
    private static func verifyFileStyles(_ editor: MarkdownTextView) -> Bool {
        guard let storage = editor.textStorage else { return false }
        let started = ProcessInfo.processInfo.systemUptime
        let plan = MarkdownStylePlanBuilder.build(MarkdownAnalysis.analyze(editor.string))
        var cache: [MarkdownStyle: [NSAttributedString.Key: Any]] = [:]
        let reference = MarkdownTextStorage(string: editor.string)
        // Native eager fixing supplies Unicode fallback and paragraph rules;
        // compare its result, not raw descriptor fonts, with the real editor.
        for run in plan.runs {
            let desired: [NSAttributedString.Key: Any]
            if let attributes = cache[run.style] { desired = attributes }
            else {
                desired = MarkdownStyler.attributes(for: run.style, fontSize: editor.writerFontSize)
                cache[run.style] = desired
            }
            reference.beginEditing()
            MarkdownStyler.applyChanged(desired, to: reference, range: run.range)
            reference.endEditing()
        }
        var matches = plan.length == storage.length
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { actual, part, stop in
            reference.enumerateAttributes(in: part) { desired, expectedPart, expectedStop in
                for key in MarkdownStyler.ownedKeys {
                    let left = actual[key] as? NSObject
                    let right = desired[key] as? NSObject
                    if !(left == nil && right == nil || left?.isEqual(right) == true) {
                        matches = false
                        print("file-style-oracle mismatch_utf16=\(expectedPart.location) managed_key=\(key.rawValue)")
                        expectedStop.pointee = true
                        break
                    }
                }
            }
            if !matches { stop.pointee = true }
        }
        print("file-style-oracle full_managed_attributes=\(matches) runs=\(plan.runs.count) validation_ms=\(String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - started) * 1000)) outside_performance_interval=true")
        return matches
    }

    private static func verifyStyles(_ editor: MarkdownTextView) -> Bool {
        guard let storage = editor.textStorage else { return false }
        let text = storage.string as NSString
        var headings = 0
        var code = 0
        // Include distant matches: a deferred fix cannot pass by styling only
        // the first viewport. Sentinels may move but are never edited below.
        for heading in ["Heading", "Final heading"] {
            let range = text.range(of: heading)
            if range.location != NSNotFound {
                guard let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont,
                      font.pointSize > editor.writerFontSize else { return false }
                headings += 1
            }
        }
        for literal in ["let sentinel", "let finalSentinel", "let value"] {
            let range = text.range(of: literal)
            if range.location != NSNotFound {
                guard storage.attribute(.mdwriteCodeBackground, at: range.location, effectiveRange: nil) != nil else { return false }
                code += 1
            }
        }
        let reference = text.range(of: "remote")
        if reference.location != NSNotFound,
           storage.attribute(.underlineStyle, at: reference.location, effectiveRange: nil) as? Int != NSUnderlineStyle.single.rawValue {
            return false
        }
        return headings > 0 && code > 0
    }

    private static func flushRecovery(_ document: MarkdownDocument, timeout: TimeInterval) -> Bool {
        var finished = false
        Task { @MainActor in
            await document.flushRecovery()
            finished = true
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !finished && ProcessInfo.processInfo.systemUptime < deadline { pump() }
        if !finished { print("FAIL: recovery owner did not drain before cleanup") }
        return finished
    }

    private static func verifyVisibleStyles(_ editor: MarkdownTextView) -> Bool {
        guard let storage = editor.textStorage, storage.length > 0 else { return false }
        let text = storage.string as NSString
        let viewportSentinels = NSRange(location: 0, length: min(8192, text.length))
        let heading = text.range(of: "Heading", options: [], range: viewportSentinels)
        let code = text.range(of: "let ", options: [], range: viewportSentinels)
        guard heading.location != NSNotFound, code.location != NSNotFound,
              let font = storage.attribute(.font, at: heading.location, effectiveRange: nil) as? NSFont else { return false }
        return font.pointSize > editor.writerFontSize
            && storage.attribute(.mdwriteCodeBackground, at: code.location, effectiveRange: nil) != nil
    }

    private static func verifyVisibleSemantics(_ editor: MarkdownTextView) -> Bool {
        guard verifyVisibleStyles(editor), let storage = editor.textStorage else { return false }
        let text = storage.string as NSString
        let visibleSentinels = NSRange(location: 0, length: min(8192, text.length))
        let reference = text.range(of: "remote", options: [], range: visibleSentinels)
        return reference.location == NSNotFound
            || storage.attribute(.underlineStyle, at: reference.location, effectiveRange: nil) as? Int == NSUnderlineStyle.single.rawValue
    }

    private static func interactive(document: MarkdownDocument, source: String, windowMilliseconds: Double) -> Bool {
        let editor = document.editorController!.editor
        let timeout = Double(option("--settle-timeout", default: "30"))!
        let count = Int(option("--edits", default: "100"))!
        let operation = option("--operation", default: "typing")
        let readySetupStart = ProcessInfo.processInfo.systemUptime
        document.editorController?.window?.contentView?.layoutSubtreeIfNeeded()
        document.editorController?.window?.makeFirstResponder(editor)
        let initialStart = ProcessInfo.processInfo.systemUptime
        let totalReadyMilliseconds = windowMilliseconds + (initialStart - readySetupStart) * 1000
        print("total-open-ready ms=\(String(format: "%.1f", totalReadyMilliseconds))")
        var heartbeat: [Double] = []
        var initialHeartbeat: [Double] = []
        var initialDraws: [Double] = []
        var isInitial = true
        var lastBeat = initialStart
        // Sample deferred work from initial styling through final convergence.
        let timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in
            MainActor.assumeIsolated {
                let now = ProcessInfo.processInfo.systemUptime
                let delay = max(0, (now - lastBeat - 0.01) * 1000)
                if isInitial { initialHeartbeat.append(delay) } else { heartbeat.append(delay) }
                lastBeat = now
            }
        }
        defer { timer.invalidate() }
        let proposedVisibleBudget = usesFile || option("--fixture", default: "baseline") == "reported" || Int(CommandLine.arguments[1])! <= 1024 ? 1000.0 : 2000.0
        let visibleBudget = Double(option("--visible-budget-ms", default: String(proposedVisibleBudget)))!
        var initialProvisionalMilliseconds: Double?
        var initialVisibleMilliseconds: Double?
        let initialDeadline = initialStart + timeout
        var nextInitialProgress = initialStart + 5
        repeat {
            pump()
            if !usesFile, initialProvisionalMilliseconds == nil, verifyVisibleStyles(editor) {
                initialProvisionalMilliseconds = totalReadyMilliseconds + (ProcessInfo.processInfo.systemUptime - initialStart) * 1000
            }
            if initialVisibleMilliseconds == nil, usesFile ? !editor.stylingIsPending : verifyVisibleSemantics(editor) {
                initialVisibleMilliseconds = totalReadyMilliseconds + (ProcessInfo.processInfo.systemUptime - initialStart) * 1000
            }
            let drawStart = ProcessInfo.processInfo.systemUptime
            editor.setNeedsDisplay(editor.visibleRect)
            editor.displayIfNeeded()
            let drawMilliseconds = (ProcessInfo.processInfo.systemUptime - drawStart) * 1000
            initialDraws.append(drawMilliseconds)
            if drawMilliseconds > 100 {
                print("initial-slow-display ms=\(String(format: "%.2f", drawMilliseconds)) elapsed_ms=\(String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - initialStart) * 1000)) stages=\(editor.mainThreadStageMaxima) background=\(editor.backgroundPhaseMaxima)")
                fflush(stdout)
            }
            if ProcessInfo.processInfo.systemUptime >= nextInitialProgress {
                print("initial-progress elapsed_ms=\(String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - initialStart) * 1000)) pending=\(editor.pendingAnalysisDescription) stages=\(editor.mainThreadStageMaxima) background=\(editor.backgroundPhaseMaxima)")
                memory("initial-progress")
                fflush(stdout)
                nextInitialProgress = ProcessInfo.processInfo.systemUptime + 5
            }
        } while editor.stylingIsPending && ProcessInfo.processInfo.systemUptime < initialDeadline
        pump()
        report("initial-heartbeat-delay", initialHeartbeat)
        report("initial-visible-display-call", initialDraws)
        print("initial-provisional-heading-code ms=\(initialProvisionalMilliseconds.map { String(format: "%.1f", $0) } ?? (usesFile ? "not_applicable" : "unsettled")) proposed_budget_ms=\(Int(proposedVisibleBudget))")
        print("initial-complete-visible-semantics ms=\(initialVisibleMilliseconds.map { String(format: "%.1f", $0) } ?? "unsettled") budget_ms=\(Int(visibleBudget))")
        print("initial-styling-settle ms=\(String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - initialStart) * 1000))")
        for (stage, maximum) in editor.mainThreadStageMaxima.sorted(by: { $0.key < $1.key }) {
            print("initial-main-thread-stage \(stage) max_ms=\(String(format: "%.2f", maximum))")
        }
        for (stage, maximum) in editor.backgroundPhaseMaxima.sorted(by: { $0.key < $1.key }) {
            print("initial-background-phase \(stage) max_ms=\(String(format: "%.2f", maximum))")
        }
        memory("initial")
        guard !editor.stylingIsPending, editor.string == source, usesFile || verifyStyles(editor) else {
            print("FAIL: initial full styling/source did not settle correctly")
            return false
        }
        if usesFile {
            // No fixed synthetic heading/code exists in an arbitrary file.
            // Pause heartbeats only for the explicitly excluded oracle work.
            timer.fireDate = .distantFuture
            guard verifyFileStyles(editor) else { return false }
            timer.fireDate = Date(timeIntervalSinceNow: 0.01)
        }
        isInitial = false
        lastBeat = ProcessInfo.processInfo.systemUptime
        var handling: [Double] = []
        var draws: [Double] = []
        var queued: [Double] = []
        var selectionSetup: [Double] = []
        var sourceVerification: [Double] = []
        var setupStages: [String: [Double]] = [:]
        func setupMeasure<Value>(_ label: String, _ body: () -> Value) -> Value {
            let start = ProcessInfo.processInfo.systemUptime
            let value = body()
            setupStages[label, default: []].append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            return value
        }
        let protectedReportedCommands = option("--fixture", default: "baseline") == "reported" && operation != "typing"
        let expectedFileSource = usesFile ? NSMutableString(string: source) : nil
        var expectedDelta = 0
        var insertionCount = 0
        for index in 0..<(count + 3) {
            let eventPassed = autoreleasepool { () -> Bool in
                let selectionStart = ProcessInfo.processInfo.systemUptime
                let location: Int
                switch index % 3 {
                case 0:
                    if protectedReportedCommands {
                        let text = editor.string as NSString
                        let body = text.range(of: "**bold**")
                        precondition(body.location != NSNotFound)
                        location = body.location + 3
                    } else { location = min(10, setupMeasure("utf16-count") { editor.string.utf16.count }) }
                case 1:
                    let text = setupMeasure("NSString-acquisition-middle") { editor.string as NSString }
                    var candidate = setupMeasure("composed-helper") { EditorBehavior.composedCharacterRange(at: text.length / 2, in: text).location }
                    var line = setupMeasure("lineRange-middle") { text.lineRange(for: NSRange(location: candidate, length: 0)) }
                    while true {
                        let contents = setupMeasure("substring-middle") { text.substring(with: line) }
                        let trimmed = setupMeasure("trim-middle") { contents.trimmingCharacters(in: .whitespacesAndNewlines) }
                        guard trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") else { break }
                        candidate = NSMaxRange(line)
                        if candidate >= text.length { candidate = max(0, text.length - 1); break }
                        line = setupMeasure("lineRange-middle") { text.lineRange(for: NSRange(location: candidate, length: 0)) }
                    }
                    location = candidate
                default:
                    let text = setupMeasure("NSString-acquisition-end") { editor.string as NSString }
                    if usesFile {
                        location = EditorBehavior.composedCharacterRange(at: max(0, text.length - 1), in: text).location
                    } else if protectedReportedCommands {
                        let suffix = text.range(of: "\n# Final heading", options: .backwards)
                        precondition(suffix.location > 2 && suffix.location != NSNotFound)
                        let filler = text.lineRange(for: NSRange(location: suffix.location - 2, length: 0))
                        location = filler.location + min(8, max(0, filler.length - 2))
                    } else {
                        let lastFence = setupMeasure("backwards-fence-query") { text.range(of: "\n```", options: .backwards) }
                        location = lastFence.location == NSNotFound ? max(0, text.length - 1) : lastFence.location
                    }
                }
                setupMeasure("native-setSelectedRange") { editor.setSelectedRange(NSRange(location: location, length: 0)) }
                setupMeasure("navigation-scroll") { editor.scrollRangeToVisible(editor.selectedRange()) }
                let before = setupMeasure("utf16-count") { editor.string.utf16.count }
                let expectedCommand: (String, NSRange)? = protectedReportedCommands && ["return", "paste", "delete"].contains(operation)
                    ? setupMeasure("expected-command-source") {
                        let original = editor.string
                        let selection = editor.selectedRange()
                        let edit: SourceEdit
                        if operation == "delete" {
                            let previous = EditorBehavior.composedCharacterRange(at: selection.location - 1, in: original as NSString)
                            edit = SourceEdit(range: previous, replacement: "", selection: NSRange(location: previous.location, length: 0))
                        } else {
                            let command: EditorCommand = operation == "return" ? .insertReturn(soft: false) : .paste("pasted **text**\n")
                            edit = try! EditorBehavior.edit(command, in: original, selection: selection)!
                        }
                        return (try! edit.applying(to: original), edit.selection)
                    } : nil
                let expectedUndo = protectedReportedCommands && operation == "undo" ? editor.string : nil
                if index >= 3 { selectionSetup.append((ProcessInfo.processInfo.systemUptime - selectionStart) * 1000) }
                // Blocks enqueued before the key must return to the event loop.
                let enqueued = ProcessInfo.processInfo.systemUptime
                var eventRan = false
                DispatchQueue.main.async {
                    queued.append((ProcessInfo.processInfo.systemUptime - enqueued) * 1000)
                    eventRan = true
                }
                let start = ProcessInfo.processInfo.systemUptime
                switch operation {
                case "return": key(editor, characters: "\r", code: 36)
                case "delete": key(editor, characters: "\u{7f}", code: 51)
                case "paste": editor.apply(.paste("pasted **text**\n"))
                case "undo":
                    editor.undoManager?.beginUndoGrouping()
                    key(editor, characters: "y", code: 16)
                    editor.undoManager?.endUndoGrouping()
                    editor.undo(nil)
                default: key(editor, characters: "y", code: 16)
                }
                let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
                let verificationStart = ProcessInfo.processInfo.systemUptime
                let delta = editor.string.utf16.count - before
                if let expectedCommand, editor.string != expectedCommand.0 || editor.selectedRange() != expectedCommand.1 {
                    print("FAIL: native \(operation) differs from exact SourceEdit source/selection")
                    return false
                }
                if let expectedUndo, editor.string != expectedUndo {
                    print("FAIL: native undo failed exact source restoration")
                    return false
                }
                if operation == "typing" {
                    if let expectedFileSource {
                        expectedFileSource.insert("y", at: location)
                        guard editor.string == expectedFileSource as String else {
                            print("FAIL: native insertion differs from exact input-copy source")
                            return false
                        }
                    }
                    guard delta == 1, (editor.string as NSString).substring(with: NSRange(location: location, length: 1)) == "y" else {
                        print("FAIL: native key lost or changed source incorrectly")
                        return false
                    }
                    insertionCount += 1
                }
                if operation == "undo", delta != 0 { print("FAIL: undo did not restore original length"); return false }
                if operation == "return", delta < 1 { print("FAIL: Return inserted no newline"); return false }
                if operation == "delete", delta >= 0 { print("FAIL: Delete removed no text"); return false }
                if operation == "paste", delta < 1 { print("FAIL: paste inserted no source"); return false }
                expectedDelta += delta
                if index >= 3 { sourceVerification.append((ProcessInfo.processInfo.systemUptime - verificationStart) * 1000) }
                if index >= 3 { handling.append(elapsed) }
                while !eventRan { pump() }
                let drawStart = ProcessInfo.processInfo.systemUptime
                editor.setNeedsDisplay(editor.visibleRect)
                editor.displayIfNeeded()
                if index >= 3 { draws.append((ProcessInfo.processInfo.systemUptime - drawStart) * 1000) }
                pump(0.03)
                return true
            }
            if !eventPassed { return false }
        }
        let convergeStart = ProcessInfo.processInfo.systemUptime
        var finalVisibleMilliseconds: Double?
        let finalDeadline = convergeStart + timeout
        repeat {
            pump()
            if finalVisibleMilliseconds == nil, usesFile ? !editor.stylingIsPending : verifyVisibleSemantics(editor) {
                finalVisibleMilliseconds = (ProcessInfo.processInfo.systemUptime - convergeStart) * 1000
            }
        } while editor.stylingIsPending && ProcessInfo.processInfo.systemUptime < finalDeadline
        let convergence = !editor.stylingIsPending
        pump(0.05)
        timer.invalidate()
        let settledMilliseconds = (ProcessInfo.processInfo.systemUptime - convergeStart) * 1000
        report("native-\(operation)", handling)
        report("selection-setup", selectionSetup)
        report("source-verification", sourceVerification)
        for (stage, samples) in setupStages.sorted(by: { $0.key < $1.key }) { report("selection-substep-\(stage)", samples) }
        report("queued-event-delay", queued)
        report("heartbeat-delay", heartbeat)
        report("visible-viewport-display-call", draws)
        print("final-styling-settle ms=\(String(format: "%.1f", settledMilliseconds))")
        print("final-complete-visible-semantics ms=\(finalVisibleMilliseconds.map { String(format: "%.1f", $0) } ?? "unsettled") budget_ms=\(Int(visibleBudget))")
        for (stage, maximum) in editor.mainThreadStageMaxima.sorted(by: { $0.key < $1.key }) {
            print("main-thread-stage \(stage) max_ms=\(String(format: "%.2f", maximum))")
        }
        for (stage, maximum) in editor.backgroundPhaseMaxima.sorted(by: { $0.key < $1.key }) {
            print("background-phase \(stage) max_ms=\(String(format: "%.2f", maximum))")
        }
        memory("final")
        let openResponsive = totalReadyMilliseconds < 2000
        let visibleTimely = (initialVisibleMilliseconds ?? .infinity) <= visibleBudget
            && (finalVisibleMilliseconds ?? .infinity) <= visibleBudget
        let correct = editor.string.utf16.count == source.utf16.count + expectedDelta
            && (operation != "typing" || insertionCount == count + 3)
        // Edits are deliberately outside sentinel words, but deletion/Return
        // can change block context near an end sentinel. Style correctness gate
        // is strict for the canonical ordinary-typing acceptance workload.
        let styles = convergence && (usesFile ? verifyFileStyles(editor) : operation != "typing" && !protectedReportedCommands || verifyStyles(editor))
        let initialResponsive = percentile(initialHeartbeat, 0.95) < 50 && (initialHeartbeat.max() ?? 0) <= 100
        let responsive = initialResponsive && (operation != "typing" || percentile(handling, 0.95) < 16) && percentile(heartbeat, 0.95) < 50
            && (handling.max() ?? 0) <= 100 && (heartbeat.max() ?? 0) <= 100
        print("\(correct && styles && responsive && openResponsive && visibleTimely ? "PASS" : "FAIL"): source_correct=\(correct) full_styles=\(styles) responsive=\(responsive) interactive_open=\(openResponsive) visible_style_deadline=\(visibleTimely)")
        if CommandLine.arguments.contains("--services") {
            // Force the newest journal after the trailing idle interval, verify
            // the real writer persisted exactly the synthetic edited source.
            document.writeRecovery()
            let drained = flushRecovery(document, timeout: 10)
            let recovered = try? document.recoveryStore?.records()
            let record = recovered?.first { $0.id == document.recoveryID }
            let journalCorrect = operation == "undo" ? true : record?.text == editor.string
            print("service-recovery exact_latest_source=\(journalCorrect) drained=\(drained)")
            print("note: services include isolated real recovery/footer/external polling; compositor presentation remains outside offscreen draw-call timing")
            return correct && styles && responsive && openResponsive && visibleTimely && drained && journalCorrect
        }
        print("note: display-call timing is native offscreen viewport drawing, not compositor presentation; recovery and named-file polling are excluded")
        return correct && styles && responsive && openResponsive && visibleTimely
    }

    private static func measure(_ name: String, _ body: () -> Void) -> Double {
        let start = ProcessInfo.processInfo.systemUptime
        body()
        let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
        print("\(name) ms=\(String(format: "%.1f", elapsed))")
        fflush(stdout)
        return elapsed
    }
}
