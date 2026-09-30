import AppKit

@MainActor
enum NativeLayoutChecks {
    static func run() throws {
        let paragraph = String(repeating: "Text should wrap within the window with equal padding on both sides. ", count: 10)
        let source = "# Window wrapping\n\n" + paragraph + "\n\n> " + paragraph + "\n\n- " + paragraph
            + "\n\n```\n" + String(repeating: "long_code_value_", count: 30) + "\n```"
        let document = MarkdownDocument()
        document.recoveryStore = nil
        try document.read(from: Data(source.utf8), ofType: "net.daringfireball.markdown")
        document.makeWindowControllers()
        defer { document.close() }
        let controller = document.editorController!
        let window = controller.window!
        let editor = controller.editor
        let scroll = editor.enclosingScrollView!
        let manager = editor.layoutManager!
        let container = editor.textContainer!
        var failures: [String] = []
        var fragmentCounts: [Int] = []
        for width: CGFloat in [560, 800, 1200, 560] {
            window.setContentSize(NSSize(width: width, height: 600))
            window.contentView!.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
            manager.ensureLayout(for: container)
            let viewport = scroll.contentSize.width
            func expect(_ condition: Bool, _ message: String) {
                if !condition { failures.append("\(Int(width))px: " + message) }
            }
            expect(abs(editor.bounds.width - viewport) < 1,
                   "editor width \(editor.bounds.width) does not fit viewport \(viewport)")
            let left = editor.textContainerOrigin.x + container.lineFragmentPadding
            let right = viewport - (editor.textContainerOrigin.x + container.size.width - container.lineFragmentPadding)
            expect(abs(left - right) < 1, "unequal padding: left \(left), right \(right), container \(container.size.width)")
            expect(!scroll.hasHorizontalScroller, "horizontal scrolling is enabled")
            let allGlyphs = manager.glyphRange(for: container)
            var fragments = 0
            manager.enumerateLineFragments(forGlyphRange: allGlyphs) { rect, used, _, _, _ in
                fragments += 1
                if editor.textContainerOrigin.x + used.maxX > viewport - editor.textContainerInset.width + 1,
                   !failures.contains("\(Int(width))px: text overflows the right padding") {
                    failures.append("\(Int(width))px: text overflows the right padding")
                }
            }
            fragmentCounts.append(fragments)
            expect(editor.string == source && !document.isDocumentEdited && document.undoManager?.canUndo != true,
                   "resizing changes source, dirty state, or undo")
            if CommandLine.arguments.contains("--layout-preview"), width == 560 || width == 1200 {
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    let drawingAppearance = NSAppearance(named: appearance)!
                    window.appearance = drawingAppearance
                    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
                    let frame = window.contentView!.superview!
                    frame.layoutSubtreeIfNeeded()
                    guard let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { continue }
                    drawingAppearance.performAsCurrentDrawingAppearance {
                        frame.cacheDisplay(in: frame.bounds, to: bitmap)
                    }
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("mdwrite-wrap-\(Int(width))-\(appearance.rawValue)-\(UUID()).png")
                    try bitmap.representation(using: .png, properties: [:])!.write(to: url)
                    print("Wrapping preview: \(url.path)")
                }
            }
        }
        if fragmentCounts[0] <= fragmentCounts[2] { failures.append("narrowing the window does not increase wrapped line count") }
        if !failures.isEmpty {
            throw NSError(domain: "mdwrite.layout", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "; ")])
        }
        print("PASS: window-width wrapping, equal side padding, resize reflow, and source preservation")
    }
}
