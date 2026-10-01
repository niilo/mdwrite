import AppKit
import CoreText
import Darwin

/// Disposable P07 A/B: native editing/layout only, no semantic styling, services,
/// files, or compatibility-mode API accesses in the TextKit 2 branch.
@main
@MainActor
struct TextKitEngineProbe {
    static func option(_ name: String, _ fallback: String) -> String {
        guard let index = CommandLine.arguments.firstIndex(of: name),
              index + 1 < CommandLine.arguments.count else { return fallback }
        return CommandLine.arguments[index + 1]
    }

    static func pump(_ seconds: Double = 0.03) {
        let deadline = Date(timeIntervalSinceNow: seconds)
        repeat {
            autoreleasepool { _ = RunLoop.main.run(mode: .default, before: deadline) }
        } while Date() < deadline
    }

    static func report(_ name: String, _ values: [Double]) {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return }
        func percentile(_ p: Double) -> Double {
            sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * p)) - 1)]
        }
        print("\(name) count=\(sorted.count) p50_ms=\(percentile(0.5)) p95_ms=\(percentile(0.95)) max_ms=\(sorted.last!)")
    }

    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let engine = option("--engine", "1")
        let family = option("--fixture", "longline")
        let kib = Int(option("--kib", "1024"))!
        let edits = Int(option("--edits", "100"))!
        let fixedHeight = CommandLine.arguments.contains("--fixed-height")
        let asciiNoBidi = CommandLine.arguments.contains("--ascii-no-bidi")
        let lineCap = Int(option("--line-cap", "0"))!
        let elementChunk = Int(option("--element-chunk", "0"))!
        guard ["1", "2"].contains(engine), ["longline", "prose"].contains(family),
              (1...10240).contains(kib), (1...1000).contains(edits), lineCap >= 0,
              lineCap == 0 || engine == "1", elementChunk >= 0,
              elementChunk == 0 || engine == "2" else { exit(2) }
        print("probe_pid=\(getpid()) engine=\(engine) fixture=\(family) kib=\(kib) fixed_height=\(fixedHeight) ascii_no_bidi=\(asciiNoBidi) line_cap=\(lineCap) element_chunk=\(elementChunk)")
        fflush(stdout)

        if CommandLine.arguments.contains("--fonts") {
            let directory = URL(fileURLWithPath: option("--fonts", "fonts"))
            for face in ["Regular", "Bold", "Italic", "BoldItalic"] {
                let url = directory.appendingPathComponent("iAWriterMonoS-\(face).ttf")
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
                _ = NSFont(name: "iAWriterMonoS-\(face)", size: 20)
            }
            pump(0.2) // Drain registration notifications before a large storage exists.
        }
        let prefix = "# Heading\n\n[remote][reference]\n\n```swift\nlet sentinel = 1\n```\n\n"
        let suffix = "\n\n# Final heading\n\n[reference]: https://example.org\n\n```swift\nlet finalSentinel = 2\n```\n"
        let unit = family == "longline" ? option("--body-unit", "unbroken") : "A plain paragraph contains words and sentences, with room to wrap naturally.\n\n"
        let source = prefix + String(repeating: unit, count: max(1,
            (kib * 1024 - prefix.utf8.count - suffix.utf8.count + unit.utf8.count - 1) / unit.utf8.count)) + suffix
        guard !asciiNoBidi || (engine == "1" && source.utf8.allSatisfy({ $0 < 128 })) else { exit(2) }
        let expected = NSMutableString(string: source)
        let geometryOracle = CommandLine.arguments.contains("--geometry-oracle")
        if geometryOracle {
            for index in 0..<(edits + 3) {
                let length = expected.length
                let location = index % 3 == 0 ? min(10, length) : index % 3 == 1 ? length / 2 : max(0, length - 20)
                expected.insert("y", at: location)
            }
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        if CommandLine.arguments.contains("--char-wrap") { paragraph.lineBreakMode = .byCharWrapping }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont(name: "iAWriterMonoS-Regular", size: 20)
                ?? NSFont.monospacedSystemFont(ofSize: 20, weight: .regular),
            .paragraphStyle: paragraph, .foregroundColor: NSColor.textColor
        ]
        let started = ProcessInfo.processInfo.systemUptime
        let storage = MarkdownTextStorage(string: geometryOracle ? expected as String : source, attributes: attributes)
        let container = NSTextContainer(size: NSSize(width: 780, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        // Keep both network owners in scope; do not ask the TK2 editor for layoutManager.
        let asyncDelegate = CommandLine.arguments.contains("--native-layout-queue") || CommandLine.arguments.contains("--exact-frame") ? QueuedLayoutDelegate(concurrency: Int(option("--native-layout-queue", "1")) ?? 1) : nil
        let legacy: NSLayoutManager?
        let content: NSTextContentStorage?
        let modern: NSTextLayoutManager?
        let paragraphCap = Int(option("--paragraph-cap", "0")) ?? 0
        let cappedTypesetter = lineCap > 0 ? LineCappedTypesetter(cap: lineCap) : nil
        let paragraphTypesetter = paragraphCap > 0 ? ParagraphCappedTypesetter(cap: paragraphCap, maxLines: Int(option("--paragraph-line-cap", "0")) ?? 0) : nil
        if engine == "1" {
            let manager: NSLayoutManager = CommandLine.arguments.contains("--trace-edits") ? EditingTraceLayoutManager() : NSLayoutManager()
            manager.allowsNonContiguousLayout = true
            if let cappedTypesetter { manager.typesetter = cappedTypesetter }
            if let paragraphTypesetter { manager.typesetter = paragraphTypesetter }
            if asciiNoBidi {
                guard let typesetter = manager.typesetter as? NSATSTypesetter else { exit(2) }
                typesetter.bidiProcessingEnabled = false
            }
            if CommandLine.arguments.contains("--no-background") { manager.backgroundLayoutEnabled = false }
            storage.addLayoutManager(manager)
            manager.addTextContainer(container)
            legacy = manager; content = nil; modern = nil
        } else {
            let manager: NSTextLayoutManager = CommandLine.arguments.contains("--logical-enumeration")
                ? LogicalTextLayoutManager() : NSTextLayoutManager()
            let owner: NSTextContentStorage = elementChunk > 0 ? ChunkedContentStorage(chunkLength: elementChunk,
                aligned: CommandLine.arguments.contains("--aligned-chunks")) : NSTextContentStorage()
            owner.textStorage = storage
            owner.addTextLayoutManager(manager)
            owner.primaryTextLayoutManager = manager
            manager.textContainer = container
            manager.delegate = asyncDelegate
            legacy = nil; content = owner; modern = manager
        }
        let editor: NSTextView = CommandLine.arguments.contains("--mapped-view")
            ? MappedGeometryTextView(frame: NSRect(x: 0, y: 0, width: 860, height: 700), textContainer: container)
            : CommandLine.arguments.contains("--aligned-chunks") && !CommandLine.arguments.contains("--logical-enumeration")
            ? LogicalParagraphTextView(frame: NSRect(x: 0, y: 0, width: 860, height: 700), textContainer: container)
            : NSTextView(frame: NSRect(x: 0, y: 0, width: 860, height: 700), textContainer: container)
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = true
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.minSize = NSSize(width: 0, height: 700)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainerInset = NSSize(width: 66, height: 45)
        editor.typingAttributes = attributes
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 860, height: 700))
        scroll.hasVerticalScroller = true
        scroll.documentView = editor
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.makeFirstResponder(editor)
        scroll.layoutSubtreeIfNeeded()
        if let chunked = content as? ChunkedContentStorage {
            // Capture AppKit geometry on MainActor and pass only the scalar to
            // content enumeration, whose base API is nonisolated.
            chunked.viewportWidth = Double(min(editor.bounds.width, scroll.contentSize.width) - 2 * editor.textContainerInset.width - 2 * container.lineFragmentPadding)
            print("viewport_width=\(scroll.contentSize.width) editor_width=\(editor.bounds.width) usable_width=\(chunked.viewportWidth!)")
            modern?.invalidateLayout(for: chunked.documentRange)
        }
        print("setup_ms=\((ProcessInfo.processInfo.systemUptime - started) * 1000) native_tk2=\(editor.textLayoutManager != nil)")
        fflush(stdout)
        guard (editor.textLayoutManager != nil) == (engine == "2") else { exit(2) }
        pump(0.2)
        if CommandLine.arguments.contains("--geometry-trace") { print("post_layout_container_width=\(container.size.width) padding=\(container.lineFragmentPadding) inset=\(editor.textContainerInset.width) editor_width=\(editor.bounds.width) clip_width=\(scroll.contentSize.width)") }
        if let chunked = content as? ChunkedContentStorage {
            chunked.viewportWidth = Double(container.size.width - 2 * container.lineFragmentPadding)
            modern?.invalidateLayout(for: chunked.documentRange)
        }
        if family == "longline", let chunked = content as? ChunkedContentStorage, chunked.aligned, let modern,
           let body = chunked.location(chunked.documentRange.location, offsetBy: prefix.utf16.count),
           let next = chunked.location(body, offsetBy: 1), let requested = NSTextRange(location: body, end: next) {
            modern.ensureLayout(for: requested)
            if let fragment = modern.textLayoutFragment(for: body),
               let line = fragment.textLineFragments.first(where: { $0.characterRange.length > 0 }) {
                let measuredLines = fragment.textLineFragments.filter { $0.characterRange.length > 0 }
                let rowHeight = measuredLines.count > 1
                    ? Double(measuredLines[1].typographicBounds.minY - measuredLines[0].typographicBounds.minY) : 30
                chunked.calibrateUniformLineLength(line.characterRange.length, rowHeight: rowHeight)
                modern.invalidateLayout(for: chunked.documentRange)
                print("native_uniform_line_length=\(line.characterRange.length) row_height=\(rowHeight)")
            }
        }
        if fixedHeight {
            let sizingStarted = ProcessInfo.processInfo.systemUptime
            // Keep the original infinite-height container and wrapping width.
            // Finish initial native sizing, then suppress only automatic view
            // resizing; subsequent editing/notifications/layout remain native.
            if let legacy { legacy.ensureLayout(for: container) }
            if let modern, let content { modern.ensureLayout(for: content.documentRange) }
            editor.sizeToFit()
            editor.isVerticallyResizable = false
            print("fixed_height_initial_frame=\(editor.frame.height) sizing_ms=\((ProcessInfo.processInfo.systemUptime - sizingStarted) * 1000)")
            fflush(stdout)
        }

        var keys: [Double] = [], selections: [Double] = [], navigation: [Double] = [], draws: [Double] = [], beats: [Double] = []
        var lastBeat = ProcessInfo.processInfo.systemUptime
        let timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in
            MainActor.assumeIsolated {
                let now = ProcessInfo.processInfo.systemUptime
                beats.append(max(0, (now - lastBeat - 0.01) * 1000)); lastBeat = now
            }
        }
        for index in 0..<(geometryOracle ? 0 : edits + 3) {
            autoreleasepool {
                let length = (editor.string as NSString).length
                let location = index % 3 == 0 ? min(10, length) : index % 3 == 1 ? length / 2 : max(0, length - 20)
                var start = ProcessInfo.processInfo.systemUptime
                editor.setSelectedRange(NSRange(location: location, length: 0))
                if index >= 3 { selections.append((ProcessInfo.processInfo.systemUptime - start) * 1000) }
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, characters: "y", charactersIgnoringModifiers: "y", isARepeat: false, keyCode: 16)!
                start = ProcessInfo.processInfo.systemUptime
                editor.keyDown(with: event)
                if index >= 3 { keys.append((ProcessInfo.processInfo.systemUptime - start) * 1000) }
                expected.insert("y", at: location)
                guard (editor.string as NSString).length == length + 1,
                      (editor.string as NSString).character(at: location) == 0x79 else { exit(3) }
                start = ProcessInfo.processInfo.systemUptime
                editor.scrollRangeToVisible(editor.selectedRange())
                if index >= 3 { navigation.append((ProcessInfo.processInfo.systemUptime - start) * 1000) }
                start = ProcessInfo.processInfo.systemUptime
                editor.setNeedsDisplay(editor.visibleRect)
                editor.displayIfNeeded()
                if index >= 3 { draws.append((ProcessInfo.processInfo.systemUptime - start) * 1000) }
                pump()
            }
        }
        pump(0.1)
        timer.invalidate()
        report("key", keys); report("selection", selections); report("scroll", navigation)
        report("display", draws); report("heartbeat", beats)
        let navigationLocation = (editor.string as NSString).length / 2
        var paragraphStart = 0, paragraphEnd = 0, paragraphContentEnd = 0
        (editor.string as NSString).getParagraphStart(&paragraphStart, end: &paragraphEnd, contentsEnd: &paragraphContentEnd,
                                                    for: NSRange(location: navigationLocation, length: 0))
        editor.setSelectedRange(NSRange(location: navigationLocation, length: 0))
        editor.moveToBeginningOfParagraph(nil)
        let actualParagraphStart = editor.selectedRange().location
        editor.setSelectedRange(NSRange(location: navigationLocation, length: 0))
        editor.moveToEndOfParagraph(nil)
        let actualParagraphEnd = editor.selectedRange().location
        let paragraphNavigationCorrect = actualParagraphStart == paragraphStart && actualParagraphEnd == paragraphContentEnd
        print("paragraph_navigation_correct=\(paragraphNavigationCorrect) expected_start=\(paragraphStart) actual_start=\(actualParagraphStart) expected_end=\(paragraphContentEnd) actual_end=\(actualParagraphEnd)")
        editor.setSelectedRange(NSRange(location: navigationLocation, length: 0))
        editor.moveWordBackward(nil)
        let actualWordStart = editor.selectedRange().location
        editor.setSelectedRange(NSRange(location: navigationLocation, length: 0))
        editor.moveWordForward(nil)
        let actualWordEnd = editor.selectedRange().location
        let wordNavigationCorrect = actualWordStart == paragraphStart && actualWordEnd == paragraphContentEnd
        print("word_navigation_correct=\(wordNavigationCorrect) actual_start=\(actualWordStart) actual_end=\(actualWordEnd)")
        var scrollingCorrect = true
        let finalLength = (editor.string as NSString).length
        var hitTestingCorrect = true
        var positions = [min(10, finalLength), finalLength / 2, max(0, finalLength - 1)]
        if CommandLine.arguments.contains("--hit-test") {
            if let chunked = content as? ChunkedContentStorage {
                positions += chunked.diagnosticBoundaries.flatMap { [$0 - 1, $0, $0 + 1] }
            }
            positions += [finalLength / 2, min(10, finalLength)]
        }
        for location in positions where location >= 0 && location <= finalLength {
            editor.setSelectedRange(NSRange(location: location, length: 0))
            editor.scrollRangeToVisible(editor.selectedRange())
            pump(0.03)
            let screenRect = editor.firstRect(forCharacterRange: editor.selectedRange(), actualRange: nil)
            let localRect = editor.convert(window.convertFromScreen(screenRect), from: nil)
            let visible = editor.visibleRect.insetBy(dx: -2, dy: -2)
            if CommandLine.arguments.contains("--render-prefix"),
               let bitmap = editor.bitmapImageRepForCachingDisplay(in: editor.visibleRect) {
                editor.cacheDisplay(in: editor.visibleRect, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    let path = option("--render-prefix", "/private/tmp/mdwrite-render") + "-\(location).png"
                    try! png.write(to: URL(fileURLWithPath: path))
                    print("render_snapshot_utf16=\(location) bytes=\(png.count) path=\(path)")
                }
            }
            // Insertion caret rectangles have zero width, so rectangular
            // intersection is empty even when the caret is fully visible.
            let intersects = localRect.height > 0 && visible.contains(NSPoint(x: localRect.midX, y: localRect.midY))
            scrollingCorrect = scrollingCorrect && intersects
            if CommandLine.arguments.contains("--hit-test") {
                let found = editor.characterIndexForInsertion(at: NSPoint(x: localRect.midX, y: localRect.midY))
                hitTestingCorrect = hitTestingCorrect && found == location
                print("hit_test_utf16=\(location) actual=\(found) correct=\(found == location)")
                if CommandLine.arguments.contains("--mouse-test") {
                    let point = editor.convert(NSPoint(x: localRect.midX, y: localRect.midY), to: nil)
                    let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
                    let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0)!
                    NSApplication.shared.postEvent(up, atStart: false)
                    editor.mouseDown(with: down)
                    let actual = editor.selectedRange().location
                    hitTestingCorrect = hitTestingCorrect && actual == location
                    print("mouse_test_utf16=\(location) actual=\(actual) correct=\(actual == location)")
                }
            }
            print("scroll_check_utf16=\(location) caret_visible=\(intersects) caret_y=\(localRect.minY) visible_y=\(visible.minY) frame_height=\(editor.frame.height)")
        }
        if let legacy {
            legacy.ensureLayout(for: container)
            var digest: UInt64 = 14_695_981_039_346_656_037
            var rangeDigest = digest
            var lines = 0
            func mix(_ value: UInt64) { digest = (digest ^ value) &* 1_099_511_628_211 }
            legacy.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: legacy.numberOfGlyphs)) { rect, used, _, range, _ in
                lines += 1
                mix(UInt64(range.location)); mix(UInt64(range.length))
                let characters = legacy.characterRange(forGlyphRange: range, actualGlyphRange: nil)
                rangeDigest = (rangeDigest ^ UInt64(characters.location)) &* 1_099_511_628_211
                rangeDigest = (rangeDigest ^ UInt64(characters.length)) &* 1_099_511_628_211
                for number in [rect.minX, rect.minY, rect.width, rect.height, used.minX, used.minY, used.width, used.height] {
                    mix(Double(number).bitPattern)
                }
            }
            print("layout_lines=\(lines) layout_digest=\(String(digest, radix: 16)) visual_ranges_digest=\(String(rangeDigest, radix: 16))")
        }
        if let traced = legacy as? EditingTraceLayoutManager {
            for entry in traced.events { print(entry) }
        }
        if let modern, let content {
            print("native_usage_height=\(modern.usageBoundsForTextContainer.height) document_height=\(editor.frame.height)")
            var digest: UInt64 = 14_695_981_039_346_656_037
            var rangeDigest = digest
            var lines = 0
            func mix(_ value: UInt64) { digest = (digest ^ value) &* 1_099_511_628_211 }
            if CommandLine.arguments.contains("--rebuild-geometry") { modern.invalidateLayout(for: content.documentRange) }
            _ = modern.textViewportLayoutController.relocateViewport(to: content.documentRange.location)
            modern.textViewportLayoutController.layoutViewport()
            modern.ensureLayout(for: content.documentRange)
            var geometryRows: [String] = []
            modern.enumerateTextLayoutFragments(from: content.documentRange.location, options: [.ensuresLayout, .estimatesSize]) { fragment in
                guard let elementRange = fragment.textElement?.elementRange else { return true }
                let base = content.offset(from: content.documentRange.location, to: elementRange.location)
                for line in fragment.textLineFragments where line.characterRange.length > 0 {
                    lines += 1
                    let location = UInt64(base + line.characterRange.location)
                    let length = UInt64(line.characterRange.length)
                    if location > 64 && location < 300 { print("visual_row location=\(location) length=\(length) width=\(line.typographicBounds.width) fragment_width=\(fragment.layoutFragmentFrame.width) leading=\(fragment.leadingPadding) trailing=\(fragment.trailingPadding)") }
                    if CommandLine.arguments.contains("--dump-rows") { geometryRows.append("\(location),\(length),\(fragment.layoutFragmentFrame.minY + line.typographicBounds.minY),\(line.typographicBounds.width),\(line.typographicBounds.height)") }
                    mix(location); mix(length)
                    rangeDigest = (rangeDigest ^ location) &* 1_099_511_628_211
                    rangeDigest = (rangeDigest ^ length) &* 1_099_511_628_211
                    for number in [fragment.layoutFragmentFrame.minX + line.typographicBounds.minX,
                                   fragment.layoutFragmentFrame.minY + line.typographicBounds.minY,
                                   line.typographicBounds.width, line.typographicBounds.height] {
                        mix(Double(number).bitPattern)
                    }
                }
                return true
            }
            if CommandLine.arguments.contains("--dump-rows") { try! geometryRows.joined(separator: "\n").write(toFile: option("--dump-rows", "/private/tmp/mdwrite-probe-rows.csv"), atomically: true, encoding: .utf8) }
            print("layout_lines=\(lines) layout_digest=\(String(digest, radix: 16)) visual_ranges_digest=\(String(rangeDigest, radix: 16))")
        }
        if let paragraphTypesetter { print("paragraph_cap_calls=\(paragraphTypesetter.calls) max_input_glyphs=\(paragraphTypesetter.maximumInput) max_layout_ms=\(paragraphTypesetter.maximumLayoutMilliseconds)") }
        if let cappedTypesetter {
            print("typesetter_calls=\(cappedTypesetter.calls) typesetter_call_max_ms=\(cappedTypesetter.maximumMilliseconds) typesetter_total_ms=\(cappedTypesetter.totalMilliseconds) typesetter_input_max=\(cappedTypesetter.maximumCharacters) typesetter_output_max=\(cappedTypesetter.maximumProcessed)")
        }
        if let chunked = content as? ChunkedContentStorage { print(chunked.diagnosticMetrics) }
        let correct = editor.string == expected as String
        let remainsModern = (editor.textLayoutManager != nil) == (engine == "2")
        print("source_correct=\(correct) engine_preserved=\(remainsModern) scrolling_correct=\(scrollingCorrect) hit_testing_correct=\(hitTestingCorrect) bytes=\(editor.string.utf8.count)")
        print("LIMIT: plain native text only; no Markdown styling, custom backgrounds, IME, or document services.")
        withExtendedLifetime((legacy, content, modern, storage, asyncDelegate)) { window.close() }
        exit(correct && remainsModern && scrollingCorrect && hitTestingCorrect && paragraphNavigationCorrect && wordNavigationCorrect ? 0 : 3)
    }
}


/// Diagnostic only: return AppKit's actual processed range, never pretend an
/// unlaid range was laid out. Native callers remain free to request more work.
// The probe's complete text graph is used exclusively by the main thread.
private final class LineCappedTypesetter: NSATSTypesetter {
    let cap: Int
    var calls = 0
    var maximumCharacters = 0
    var maximumProcessed = 0
    var maximumMilliseconds = 0.0
    var totalMilliseconds = 0.0

    init(cap: Int) { self.cap = cap; super.init() }

    override func layoutCharacters(in characterRange: NSRange, for layoutManager: NSLayoutManager,
                                   maximumNumberOfLineFragments: Int) -> NSRange {
        calls += 1
        maximumCharacters = max(maximumCharacters, characterRange.length)
        let started = ProcessInfo.processInfo.systemUptime
        let result = super.layoutCharacters(in: characterRange, for: layoutManager,
                                            maximumNumberOfLineFragments: min(cap, maximumNumberOfLineFragments))
        let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1000
        maximumMilliseconds = max(maximumMilliseconds, elapsed)
        totalMilliseconds += elapsed
        maximumProcessed = max(maximumProcessed, result.length)
        return result
    }
}


/// Record native invalidation expansion while preserving every notification
/// and all of AppKit's requested ranges unchanged.
// The probe's complete text graph is used exclusively by the main thread.
private final class EditingTraceLayoutManager: NSLayoutManager {
    var events: [String] = []
    override func processEditing(for textStorage: NSTextStorage, edited editMask: NSTextStorageEditActions,
                                 range newCharRange: NSRange, changeInLength delta: Int,
                                 invalidatedRange invalidatedCharRange: NSRange) {
        if events.count < 12 {
            events.append("native_edit mask=\(editMask.rawValue) delta=\(delta) changed=\(newCharRange) invalidated=\(invalidatedCharRange)")
        }
        super.processEditing(for: textStorage, edited: editMask, range: newCharRange,
                             changeInLength: delta, invalidatedRange: invalidatedCharRange)
    }
}


/// Feasibility diagnostic only. Substrings preserve UTF-16 source positions,
/// but raw chunk boundaries may introduce visual/paragraph-navigation changes.
/// No production editor uses this content manager.
private final class ChunkedContentStorage: NSTextContentStorage {
    let chunkLength: Int
    let aligned: Bool
    override var textStorage: NSTextStorage? {
        didSet {
            guard oldValue !== textStorage else { return }
            sourceRevision &+= 1
            cachedRevision = .max
            cachedLength = -1
            cachedWidth = -1
            logicalParagraphs.removeAll(keepingCapacity: true)
            nativeUniformLineLength = nil
            lastEdit = nil
        }
    }
    var viewportWidth: Double? {
        didSet {
            if oldValue != viewportWidth {
                nativeUniformLineLength = nil
                cachedWidth = -1
            }
        }
    }
    var nativeUniformLineLength: Int?
    private var nativeUniformRowHeight = 30.0
    func calibrateUniformLineLength(_ length: Int, rowHeight: Double) {
        nativeUniformLineLength = length
        nativeUniformRowHeight = rowHeight
        cachedWidth = -1
    }
    private var observedStorage: NSTextStorage?
    private var lastEdit: (NSRange, Int)?
    private var logicalParagraphs: [(range: NSRange, lineLength: Int)] = []
    private var cachedWidth = -1.0
    private var sourceRevision: UInt64 = 0
    private var cachedRevision: UInt64 = .max
    private var cachedLength = -1
    private var ranges: [NSRange] = []
    private var rowOrigins: [Int] = []
    private var cache: [Int: NSTextParagraph] = [:]

    init(chunkLength: Int, aligned: Bool) { self.chunkLength = chunkLength; self.aligned = aligned; super.init() }
    required init?(coder: NSCoder) { fatalError("Diagnostic content storage is not archived") }
    func diagnosticRange(atY y: Double) -> NSRange? {
        guard !ranges.isEmpty else { return nil }
        let row = max(0, Int(floor(y / nativeUniformRowHeight)))
        var lower = 0, upper = rowOrigins.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if rowOrigins[middle] <= row { lower = middle + 1 } else { upper = middle }
        }
        return ranges[max(0, lower - 1)]
    }
    var diagnosticBoundaries: [Int] {
        let large = ranges.filter { $0.length > 100 }.map(\.location)
        guard !large.isEmpty else { return [] }
        return [large[0], large[large.count / 2], large[large.count - 1]]
    }
    var diagnosticMetrics: String {
        "chunk_metrics width=\(cachedWidth) paragraphs=\(logicalParagraphs.count) line_lengths=\(logicalParagraphs.filter { $0.range.length > chunkLength }.map(\.lineLength)) chunk_lengths=\(ranges.filter { $0.length > 100 }.prefix(3).map(\.length))"
    }

    @objc private func sourceEdited(_ notification: Notification) {
        guard let storage = notification.object as? NSTextStorage, storage === textStorage else { return }
        sourceRevision &+= 1
        if storage.editedMask.contains(.editedAttributes) && !storage.editedMask.contains(.editedCharacters) {
            nativeUniformLineLength = nil
        }
        lastEdit = storage.editedMask.contains(.editedCharacters)
            ? (storage.editedRange, storage.changeInLength) : nil
    }

    override func enumerateTextElements(from textLocation: (any NSTextLocation)?, options: NSTextContentManager.EnumerationOptions = [],
                                        using block: (NSTextElement) -> Bool) -> (any NSTextLocation)? {
        guard let storage = textStorage else { return nil }
        if observedStorage !== storage {
            if let observedStorage {
                NotificationCenter.default.removeObserver(self, name: NSTextStorage.willProcessEditingNotification, object: observedStorage)
            }
            NotificationCenter.default.addObserver(self, selector: #selector(sourceEdited(_:)),
                name: NSTextStorage.willProcessEditingNotification, object: storage)
            observedStorage = storage
        }
        let container = primaryTextLayoutManager?.textContainer
        let width = viewportWidth ?? Double((container?.size.width ?? 780) - 2 * (container?.lineFragmentPadding ?? 5))
        if cachedLength != storage.length || cachedWidth != width || cachedRevision != sourceRevision {
            let oldLength = cachedLength
            cachedLength = storage.length
            cachedRevision = sourceRevision
            ranges.removeAll(keepingCapacity: true)
            rowOrigins.removeAll(keepingCapacity: true)
            // The framework keeps only weak element references. Invalidate old
            // associations before releasing cached element instances.
            if CommandLine.arguments.contains("--invalidate-elements") {
                primaryTextLayoutManager?.invalidateLayout(for: documentRange)
            }
            cache.removeAll(keepingCapacity: true)
            let source = storage.string as NSString
            // This isolated aligned variant accepts only the probe's ASCII y
            // insertions. Reuse paragraph/line metrics and shift following ranges
            // rather than rescanning or reshaping the complete source per key.
            if aligned, cachedWidth == width, !logicalParagraphs.isEmpty,
               let (edit, delta) = lastEdit, oldLength + delta == storage.length,
               delta > 0, source.substring(with: edit).allSatisfy({ $0 == "y" }),
               let affected = logicalParagraphs.firstIndex(where: { NSLocationInRange(edit.location, $0.range) }) {
                logicalParagraphs[affected].range.length += delta
                for index in logicalParagraphs.indices where index > affected {
                    logicalParagraphs[index].range.location += delta
                }
            } else {
                logicalParagraphs.removeAll(keepingCapacity: true)
                var cursor = 0
                while cursor < source.length {
                    let paragraph = source.paragraphRange(for: NSRange(location: cursor, length: 0))
                    var lineLength = chunkLength
                    if aligned, paragraph.length > chunkLength {
                        let sample = source.substring(with: NSRange(location: cursor, length: min(8192, paragraph.length)))
                        let font = storage.attribute(.font, at: cursor, effectiveRange: nil) as? NSFont
                            ?? NSFont.monospacedSystemFont(ofSize: 20, weight: .regular)
                        let ctFont = font as CTFont
                        let attributes = [NSAttributedString.Key(kCTFontAttributeName as String): ctFont]
                        let typesetter = CTTypesetterCreateWithAttributedString(NSAttributedString(string: sample, attributes: attributes))
                        let wordBreak = CTTypesetterSuggestLineBreak(typesetter, 0, width)
                        lineLength = nativeUniformLineLength ?? max(1, wordBreak > 0 ? wordBreak : CTTypesetterSuggestClusterBreak(typesetter, 0, width))
                        if CommandLine.arguments.contains("--geometry-trace") {
                            let line = CTTypesetterCreateLine(typesetter, CFRange(location: 0, length: lineLength))
                            print("ct_geometry font=\(font.fontName) point=\(font.pointSize) width=\(width) suggested=\(lineLength) actual_width=\(CTLineGetTypographicBounds(line, nil, nil, nil))")
                        }
                    }
                    logicalParagraphs.append((paragraph, lineLength))
                    cursor = NSMaxRange(paragraph)
                }
            }
            cachedWidth = width
            lastEdit = nil
            for paragraph in logicalParagraphs {
                var cursor = paragraph.range.location
                let end = NSMaxRange(paragraph.range)
                let limit = aligned && paragraph.range.length > chunkLength
                    ? max(paragraph.lineLength, (chunkLength / paragraph.lineLength) * paragraph.lineLength)
                    : chunkLength
                while cursor < end {
                    let length = min(limit, end - cursor)
                    let chunk = source.rangeOfComposedCharacterSequences(for: NSRange(location: cursor, length: length))
                    if let previous = ranges.last, let previousOrigin = rowOrigins.last {
                        var contentLength = previous.length
                        if contentLength > 0, source.character(at: NSMaxRange(previous) - 1) == 0x0A {
                            contentLength -= 1
                            if contentLength > 0, source.character(at: NSMaxRange(previous) - 2) == 0x0D { contentLength -= 1 }
                        } else if contentLength > 0, source.character(at: NSMaxRange(previous) - 1) == 0x0D {
                            contentLength -= 1
                        }
                        let previousLineLength = logicalParagraphs.first(where: { NSLocationInRange(previous.location, $0.range) })!.lineLength
                        rowOrigins.append(previousOrigin + max(1, Int(ceil(Double(contentLength) / Double(previousLineLength)))))
                    } else { rowOrigins.append(0) }
                    ranges.append(chunk)
                    cursor = NSMaxRange(chunk)
                }
            }
        }
        let start = textLocation.map { offset(from: documentRange.location, to: $0) }
            ?? (options.contains(.reverse) ? storage.length : 0)
        let indices: [Int]
        if options.contains(.reverse) {
            // The contract begins at the element preceding the one containing
            // start, or the last element when start is the document endpoint.
            indices = ranges.indices.reversed().filter { NSMaxRange(ranges[$0]) <= start }
        } else {
            indices = ranges.indices.filter { NSMaxRange(ranges[$0]) > start }
        }
        var edge: (any NSTextLocation)?
        for index in indices {
            let range = ranges[index]
            guard let beginning = location(documentRange.location, offsetBy: range.location),
                  let ending = location(beginning, offsetBy: range.length) else { return edge }
            let paragraph: NSTextParagraph
            if let old = cache[index] { paragraph = old }
            else {
                let attributes = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
                if aligned, let logical = logicalParagraphs.first(where: { NSLocationInRange(range.location, $0.range) }),
                   let base = attributes.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle,
                   let continuation = base.mutableCopy() as? NSMutableParagraphStyle {
                    if range.location > logical.range.location {
                        continuation.firstLineHeadIndent = continuation.headIndent
                        continuation.paragraphSpacingBefore = 0
                    }
                    if NSMaxRange(range) < NSMaxRange(logical.range) { continuation.paragraphSpacing = 0 }
                    attributes.addAttribute(.paragraphStyle, value: continuation, range: NSRange(location: 0, length: attributes.length))
                }
                let chunkParagraph = ChunkParagraph(attributedString: attributes)
                let lineSpacing = (attributes.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.lineSpacing ?? 0
                // Native first fragment omits leading line spacing; subsequent
                // fragments include it in their internal first-line bounds.
                chunkParagraph.expectedY = Double(rowOrigins[index]) * nativeUniformRowHeight - (index == 0 ? 0 : lineSpacing)
                paragraph = chunkParagraph
                paragraph.textContentManager = self
                paragraph.elementRange = NSTextRange(location: beginning, end: ending)
                cache[index] = paragraph
            }
            edge = options.contains(.reverse) ? beginning : ending
            if !block(paragraph) { break }
        }
        return edge
    }
}


/// The default paragraph subclass relies on its content manager's paragraph
/// cache for these ranges. Custom enumerated elements must provide their own.
private final class ChunkParagraph: NSTextParagraph {
    var expectedY: Double = 0
    override var paragraphContentRange: NSTextRange? {
        guard let range = elementRange, let owner = textContentManager else { return nil }
        let text = attributedString.string as NSString
        let separatorLength = text.hasSuffix("\r\n") ? 2 : (text.hasSuffix("\n") || text.hasSuffix("\r") ? 1 : 0)
        guard let end = owner.location(range.location, offsetBy: text.length - separatorLength) else { return nil }
        return NSTextRange(location: range.location, end: end)
    }
    override var paragraphSeparatorRange: NSTextRange? {
        guard let range = elementRange, let content = paragraphContentRange else { return nil }
        return NSTextRange(location: content.endLocation, end: range.endLocation)
    }
}


/// Supported action/selection overrides retain the original source's logical
/// paragraphs when the layout content manager uses smaller visual elements.
@MainActor
private final class LogicalParagraphTextView: NSTextView {
    override func moveToBeginningOfParagraph(_ sender: Any?) {
        var start = 0
        (string as NSString).getParagraphStart(&start, end: nil, contentsEnd: nil,
                                              for: NSRange(location: selectedRange().location, length: 0))
        setSelectedRange(NSRange(location: start, length: 0))
        scrollRangeToVisible(selectedRange())
    }
    override func moveToEndOfParagraph(_ sender: Any?) {
        var end = 0
        (string as NSString).getParagraphStart(nil, end: nil, contentsEnd: &end,
                                              for: NSRange(location: selectedRange().location, length: 0))
        setSelectedRange(NSRange(location: end, length: 0))
        scrollRangeToVisible(selectedRange())
    }
    override func selectionRange(forProposedRange proposedCharRange: NSRange,
                                 granularity: NSSelectionGranularity) -> NSRange {
        if granularity.rawValue == 2 { return (string as NSString).paragraphRange(for: proposedCharRange) }
        return super.selectionRange(forProposedRange: proposedCharRange, granularity: granularity)
    }
}


/// Experimental supported selection-data-source seam: linguistic boundaries
/// refer to original source, while glyph/line/hit-testing stays native.
private final class LogicalTextLayoutManager: NSTextLayoutManager {
    private var mappedHitCalls = 0
    func diagnosticSourceIndex(at point: CGPoint) -> Int? {
        guard let owner = textContentManager as? ChunkedContentStorage,
              let range = owner.diagnosticRange(atY: point.y),
              let beginning = owner.location(owner.documentRange.location, offsetBy: range.location),
              let next = owner.location(beginning, offsetBy: 1), let requested = NSTextRange(location: beginning, end: next) else { return nil }
        ensureLayout(for: requested)
        guard let fragment = textLayoutFragment(for: beginning), let elementRange = fragment.textElement?.elementRange,
              let line = fragment.textLineFragments.min(by: {
                  abs(fragment.layoutFragmentFrame.minY + $0.typographicBounds.midY - point.y)
                    < abs(fragment.layoutFragmentFrame.minY + $1.typographicBounds.midY - point.y)
              }) else { return nil }
        let local = CGPoint(x: point.x - fragment.layoutFragmentFrame.minX - line.typographicBounds.minX,
                            y: point.y - fragment.layoutFragmentFrame.minY - line.typographicBounds.minY)
        let glyphIndex = line.characterIndex(for: local)
        let fraction = line.fractionOfDistanceThroughGlyph(for: local)
        let nativeIndex = glyphIndex + (fraction >= 0.5 ? 1 : 0)
        let base = owner.offset(from: owner.documentRange.location, to: elementRange.location)
        return min(owner.textStorage?.length ?? 0, max(0, base + nativeIndex))
    }
    override func enumerateCaretOffsetsInLineFragment(at location: any NSTextLocation,
                                        using block: (CGFloat, any NSTextLocation, Bool, UnsafeMutablePointer<ObjCBool>) -> Void) {
        if CommandLine.arguments.contains("--trace-carets"), let owner = textContentManager as? ChunkedContentStorage {
            let source = owner.offset(from: owner.documentRange.location, to: location)
            super.enumerateCaretOffsetsInLineFragment(at: location) { caretOffset, position, leadingEdge, stop in
                if source > (owner.textStorage?.length ?? 0) - 100 {
                    print("native_caret_enum line=\(source) offset=\(caretOffset) source=\(owner.offset(from: owner.documentRange.location, to: position)) leading=\(leadingEdge)")
                }
                block(caretOffset, position, leadingEdge, stop)
            }
        } else { super.enumerateCaretOffsetsInLineFragment(at: location, using: block) }
    }
    override func textLayoutFragment(for position: CGPoint) -> NSTextLayoutFragment? {
        guard CommandLine.arguments.contains("--mapped-hit-test"),
              let owner = textContentManager as? ChunkedContentStorage,
              let range = owner.diagnosticRange(atY: position.y),
              let beginning = owner.location(owner.documentRange.location, offsetBy: range.location),
              let next = owner.location(beginning, offsetBy: 1), let requested = NSTextRange(location: beginning, end: next) else {
            return super.textLayoutFragment(for: position)
        }
        mappedHitCalls += 1
        if mappedHitCalls <= 12 { print("mapped_fragment_call=\(mappedHitCalls) point=\(position) chunk=\(range)") }
        ensureLayout(for: requested)
        return super.textLayoutFragment(for: beginning)
    }
    override func lineFragmentRange(for point: CGPoint, inContainerAt location: any NSTextLocation) -> NSTextRange? {
        guard CommandLine.arguments.contains("--mapped-hit-test"),
              let owner = textContentManager as? ChunkedContentStorage,
              let range = owner.diagnosticRange(atY: point.y),
              let beginning = owner.location(owner.documentRange.location, offsetBy: range.location),
              let next = owner.location(beginning, offsetBy: 1), let requested = NSTextRange(location: beginning, end: next) else {
            return super.lineFragmentRange(for: point, inContainerAt: location)
        }
        mappedHitCalls += 1
        if mappedHitCalls <= 12 { print("mapped_hit_call=\(mappedHitCalls) point=\(point) chunk=\(range)") }
        ensureLayout(for: requested)
        guard let fragment = textLayoutFragment(for: beginning), let elementRange = fragment.textElement?.elementRange else { return nil }
        let base = owner.offset(from: owner.documentRange.location, to: elementRange.location)
        for line in fragment.textLineFragments {
            let rect = line.typographicBounds.offsetBy(dx: fragment.layoutFragmentFrame.minX, dy: fragment.layoutFragmentFrame.minY)
            guard point.y >= rect.minY && point.y < rect.maxY else { continue }
            guard let start = owner.location(owner.documentRange.location, offsetBy: base + line.characterRange.location),
                  let end = owner.location(start, offsetBy: line.characterRange.length) else { return nil }
            return NSTextRange(location: start, end: end)
        }
        return nil
    }

    override func enumerateSubstrings(from location: any NSTextLocation,
                                      options: NSString.EnumerationOptions = [],
                                      using block: (String?, NSTextRange, NSTextRange?, UnsafeMutablePointer<ObjCBool>) -> Void) {
        guard !options.contains(.byLines), let owner = textContentManager as? NSTextContentStorage, let storage = owner.textStorage else {
            super.enumerateSubstrings(from: location, options: options, using: block)
            return
        }
        let length = storage.length
        let offset = owner.offset(from: owner.documentRange.location, to: location)
        guard offset >= 0 && offset <= length else { return }
        var search = options.contains(.reverse) ? NSRange(location: 0, length: offset)
            : NSRange(location: offset, length: length - offset)
        if options.contains(.byParagraphs), length > 0 {
            let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: min(offset, length - 1), length: 0))
            search = options.contains(.reverse) ? NSRange(location: 0, length: NSMaxRange(paragraph))
                : NSRange(location: paragraph.location, length: length - paragraph.location)
        }
        // NSString enumeration is synchronous; Swift imports its closure as
        // escaping, while the selection-data-source callback is nonescaping.
        withoutActuallyEscaping(block) { callback in
            (storage.string as NSString).enumerateSubstrings(in: search, options: options) { substring, range, enclosing, stop in
            func mapped(_ range: NSRange) -> NSTextRange? {
                guard let start = owner.location(owner.documentRange.location, offsetBy: range.location),
                      let end = owner.location(start, offsetBy: range.length) else { return nil }
                return NSTextRange(location: start, end: end)
            }
            guard let mappedRange = mapped(range) else { return }
                callback(substring, mappedRange, mapped(enclosing), stop)
            }
        }
    }

    override func textRange(for granularity: NSTextSelection.Granularity,
                            enclosing location: any NSTextLocation) -> NSTextRange? {
        if granularity == .line, CommandLine.arguments.contains("--mapped-hit-test"),
           let owner = textContentManager as? ChunkedContentStorage,
           let next = owner.location(location, offsetBy: 1), let requested = NSTextRange(location: location, end: next) {
            ensureLayout(for: requested)
            if let fragment = textLayoutFragment(for: location), let elementRange = fragment.textElement?.elementRange {
                let base = owner.offset(from: owner.documentRange.location, to: elementRange.location)
                let relative = owner.offset(from: elementRange.location, to: location)
                if let line = fragment.textLineFragments.first(where: { NSLocationInRange(relative, $0.characterRange) }),
                   let beginning = owner.location(owner.documentRange.location, offsetBy: base + line.characterRange.location),
                   let end = owner.location(beginning, offsetBy: line.characterRange.length) {
                    return NSTextRange(location: beginning, end: end)
                }
            }
        }
        guard granularity != .line, let owner = textContentManager as? NSTextContentStorage,
              let storage = owner.textStorage else { return super.textRange(for: granularity, enclosing: location) }
        let source = storage.string as NSString
        let offset = owner.offset(from: owner.documentRange.location, to: location)
        guard source.length > 0, offset >= 0, offset <= source.length else { return nil }
        let target = min(offset, source.length - 1)
        var range: NSRange?
        switch granularity {
        case .paragraph: range = source.paragraphRange(for: NSRange(location: target, length: 0))
        case .character: range = source.rangeOfComposedCharacterSequence(at: target)
        case .word, .sentence:
            let options: NSString.EnumerationOptions = granularity == .word ? [.byWords, .substringNotRequired] : [.bySentences, .substringNotRequired]
            source.enumerateSubstrings(in: NSRange(location: 0, length: source.length), options: options) { _, candidate, _, stop in
                if NSLocationInRange(target, candidate) { range = candidate; stop.pointee = true }
            }
        default: return super.textRange(for: granularity, enclosing: location)
        }
        guard let range, let start = owner.location(owner.documentRange.location, offsetBy: range.location),
              let end = owner.location(start, offsetBy: range.length) else { return nil }
        return NSTextRange(location: start, end: end)
    }

}

/// Isolated supported native-layout queue ablation, without element splitting.
private final class QueuedLayoutDelegate: NSObject, NSTextLayoutManagerDelegate {
    private let queue = OperationQueue()
    init(concurrency: Int) {
        super.init()
        queue.maxConcurrentOperationCount = concurrency
        queue.qualityOfService = .userInitiated
    }
    func textLayoutManager(_ textLayoutManager: NSTextLayoutManager,
                           textLayoutFragmentFor location: any NSTextLocation,
                           in textElement: NSTextElement) -> NSTextLayoutFragment {
        if CommandLine.arguments.contains("--exact-frame") { return ExactFrameFragment(textElement: textElement, range: nil) }
        let fragment = CommandLine.arguments.contains("--retain-layout-element")
            ? RetainedLayoutFragment(textElement: textElement, range: nil)
            : NSTextLayoutFragment(textElement: textElement, range: nil)
        fragment.layoutQueue = queue
        return fragment
    }
}

private final class RetainedLayoutFragment: NSTextLayoutFragment {
    private let retainedElement: NSTextElement
    override init(textElement: NSTextElement, range rangeInElement: NSTextRange?) {
        retainedElement = textElement
        super.init(textElement: textElement, range: rangeInElement)
    }
    required init?(coder: NSCoder) { fatalError("Diagnostic fragment is not archived") }
}

/// Synthetic uniform-font geometry ablation only; row-height is fixture-specific.
private final class ExactFrameFragment: NSTextLayoutFragment {
    override var layoutFragmentFrame: CGRect {
        var frame = super.layoutFragmentFrame
        if let paragraph = textElement as? ChunkParagraph { frame.origin.y = paragraph.expectedY }
        return frame
    }
}

/// Clamp the supported paragraph typesetter seam, preserving super layout.
/// Synthetic uniform ASCII only until full wrap/geometry parity is established.
private final class ParagraphCappedTypesetter: NSATSTypesetter {
    let cap: Int
    let maxLines: Int
    private var cursor = 0
    var calls = 0
    var maximumInput = 0
    var maximumLayoutMilliseconds = 0.0
    init(cap: Int, maxLines: Int) { self.cap = cap; self.maxLines = maxLines; super.init() }
    override func layoutCharacters(in characterRange: NSRange, for layoutManager: NSLayoutManager,
                                   maximumNumberOfLineFragments: Int) -> NSRange {
        cursor = layoutManager.glyphIndexForCharacter(at: characterRange.location)
        return super.layoutCharacters(in: characterRange, for: layoutManager,
                                      maximumNumberOfLineFragments: maxLines > 0 ? min(maxLines, maximumNumberOfLineFragments) : maximumNumberOfLineFragments)
    }
    override func layoutGlyphs(in layoutManager: NSLayoutManager, startingAtGlyphIndex startGlyphIndex: Int,
                               maxNumberOfLineFragments maxNumLines: Int, nextGlyphIndex nextGlyph: UnsafeMutablePointer<Int>) {
        cursor = startGlyphIndex
        super.layoutGlyphs(in: layoutManager, startingAtGlyphIndex: startGlyphIndex,
                          maxNumberOfLineFragments: maxNumLines, nextGlyphIndex: nextGlyph)
    }
    override func setParagraphGlyphRange(_ paragraphRange: NSRange, separatorGlyphRange paragraphSeparatorRange: NSRange) {
        maximumInput = max(maximumInput, paragraphRange.length)
        let beginning = max(paragraphRange.location, cursor)
        let ending = min(NSMaxRange(paragraphRange), beginning + cap)
        let bounded = NSRange(location: beginning, length: max(0, ending - beginning))
        if calls < 12 { print("paragraph_setter range=\(paragraphRange) separator=\(paragraphSeparatorRange) cursor=\(cursor) bounded=\(bounded)"); fflush(stdout) }
        super.setParagraphGlyphRange(bounded,
            separatorGlyphRange: ending < NSMaxRange(paragraphRange) ? NSRange(location: ending, length: 0) : paragraphSeparatorRange)
    }
    override func layoutParagraph(at lineFragmentOrigin: UnsafeMutablePointer<NSPoint>) -> Int {
        calls += 1
        let started = ProcessInfo.processInfo.systemUptime
        let next = super.layoutParagraph(at: lineFragmentOrigin)
        maximumLayoutMilliseconds = max(maximumLayoutMilliseconds, (ProcessInfo.processInfo.systemUptime - started) * 1000)
        cursor = next
        return next
    }
}

/// One geometry adapter diagnostic, rather than command-specific selection fixes.
@MainActor
private final class MappedGeometryTextView: NSTextView {
    override func characterIndexForInsertion(at point: NSPoint) -> Int {
        guard let manager = textLayoutManager as? LogicalTextLayoutManager,
              let result = manager.diagnosticSourceIndex(at: CGPoint(x: point.x - textContainerOrigin.x,
                                                                     y: point.y - textContainerOrigin.y)) else {
            return super.characterIndexForInsertion(at: point)
        }
        return result
    }
    override func characterIndex(for point: NSPoint) -> Int {
        guard let window else { return super.characterIndex(for: point) }
        let local = convert(window.convertPoint(fromScreen: point), from: nil)
        return characterIndexForInsertion(at: local)
    }
}
