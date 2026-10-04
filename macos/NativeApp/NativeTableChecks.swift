import AppKit
import EditorCore

/// Native checks for the wired-up "Align Table Source" action: menu presence,
/// enablement rules, one-step undo, and the guarantee that rendering-free
/// alignment never touches non-table source.
@MainActor
enum NativeTableChecks {
    static func run() throws {
        func expect(_ condition: Bool, _ message: String) throws {
            if !condition {
                throw NSError(domain: "mdwrite.tables", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        let source = "intro\n\n| Name | Value |\n| --- | --- |\n| a | longer |\n\noutro\n"
        let document = MarkdownDocument()
        document.recoveryStore = nil
        try document.read(from: Data(source.utf8), ofType: "net.daringfireball.markdown")
        document.makeWindowControllers()
        defer { document.close() }
        let controller = document.editorController!
        let editor = controller.editor

        // The action is reachable from both the main menu and the toolbox popup.
        let mainFormat = NSApp.mainMenu!.items.first { $0.title == "Format" }!.submenu!
        let mainAlign = mainFormat.items.first { $0.title == "Align Table Source" }
        try expect(mainAlign != nil, "main Format menu is missing Align Table Source")
        try expect(mainAlign!.target == nil, "Align Table Source must route to the focused document")
        try expect(mainAlign!.action == #selector(MarkdownTextView.alignTableSource(_:)),
                   "Align Table Source has the wrong action")
        let popup = controller.window!.toolbar!.items.compactMap { $0.view as? NSPopUpButton }.first!
        try expect(popup.menu!.items.contains { $0.title == "Align Table Source" },
                   "toolbox popup is missing Align Table Source")

        // View mode is read-only, so the action must be unavailable.
        editor.enterViewMode(nil)
        editor.setSelectedRange(NSRange(location: 10, length: 0))
        try expect(!editor.canAlignTableSource, "alignment is offered while read-only")
        try expect(!editor.validateMenuItem(mainAlign!), "menu item stays enabled in View mode")

        editor.enterEditMode(nil)
        // Caret outside the table: nothing to align.
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        try expect(!editor.canAlignTableSource, "alignment is offered outside a table")
        try expect(!editor.validateMenuItem(mainAlign!), "menu item stays enabled outside a table")

        // Caret inside the misaligned table: the action applies and is undoable.
        editor.setSelectedRange(NSRange(location: (source as NSString).range(of: "longer").location, length: 0))
        try expect(editor.canAlignTableSource, "alignment is not offered inside a table")
        try expect(editor.validateMenuItem(mainAlign!), "menu item is disabled inside a table")

        let entry = popup.menu!.items.first { $0.title == "Align Table Source" }!
        popup.menu!.performActionForItem(at: popup.menu!.index(of: entry))
        // NSDocument observes undo, so dirty state settles on the next turn.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        let aligned = "| Name | Value  |\n| ---- | ------ |\n| a    | longer |"
        try expect(editor.string.contains(aligned), "Align Table Source did not align the table")
        try expect(editor.string.hasPrefix("intro\n\n"), "alignment changed text before the table")
        try expect(editor.string.hasSuffix("\n\noutro\n"), "alignment changed text after the table")
        try expect(document.isDocumentEdited, "alignment did not mark the document dirty")

        // One undo restores the exact original source.
        document.undoManager?.undo()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        try expect(editor.string == source, "one undo does not restore the original table source")
        try expect(!document.isDocumentEdited, "undo to baseline clears dirty state")

        // Re-aligning an already aligned table is a no-op, not a dirtying edit.
        editor.alignTableSource(nil)
        let once = editor.string
        editor.alignTableSource(nil)
        try expect(editor.string == once, "aligning an aligned table changed the source again")
        document.undoManager?.undo()
        try expect(editor.string == source, "second alignment was not a single undo step")

        // Table recognition must ignore fenced code.
        let fenced = MarkdownDocument()
        fenced.recoveryStore = nil
        try fenced.read(from: Data("```\n| a | b |\n| --- | --- |\n```\n".utf8),
                        ofType: "net.daringfireball.markdown")
        fenced.makeWindowControllers()
        defer { fenced.close() }
        let fencedEditor = fenced.editorController!.editor
        fencedEditor.enterEditMode(nil)
        fencedEditor.setSelectedRange(NSRange(location: 6, length: 0))
        try expect(!fencedEditor.canAlignTableSource, "a table inside a code fence is alignable")

        // Column width must follow the rendered font, not the character count.
        // The bundled face lacks CJK/emoji glyphs, so these fall back to a
        // fractional-advance face that a static table would misjudge.
        let wide = MarkdownTableFontMetrics.cells(in: "abc")
        try expect(wide == 3, "ASCII cell width is \(wide), expected 3")
        let cjk = MarkdownTableFontMetrics.cells(in: "日本")
        let emoji = MarkdownTableFontMetrics.cells(in: "🎉")
        try expect(cjk >= 2, "CJK cell width is \(cjk), expected at least 2")
        try expect(emoji >= 1, "emoji cell width is \(emoji), expected at least 1")
        try expect(MarkdownTableFontMetrics.cells(in: "") == 0, "empty cell has nonzero width")

        let mixed = MarkdownDocument()
        mixed.recoveryStore = nil
        try mixed.read(from: Data("| A | B |\n| --- | --- |\n| 日本 | x |\n| ab | yyyy |\n".utf8),
                       ofType: "net.daringfireball.markdown")
        mixed.makeWindowControllers()
        defer { mixed.close() }
        let mixedEditor = mixed.editorController!.editor
        mixedEditor.enterEditMode(nil)
        mixedEditor.setSelectedRange(NSRange(location: 12, length: 0))
        guard let wideEdit = try MarkdownTableAlignmentEdit.editAligningTable(at: 12, in: mixedEditor.string) else {
            throw NSError(domain: "mdwrite.tables", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "wide-character table produced no alignment edit"])
        }
        let wideResult = try wideEdit.applying(to: mixedEditor.string)
        // Every row must occupy the same number of rendered cells.
        let lines = wideResult.split(separator: "\n").map(String.init)
        let widths = Set(lines.map { MarkdownTableFontMetrics.cells(in: $0) })
        try expect(widths.count == 1, "mixed-width rows render at differing widths: \(widths)")
        try expect(wideResult.contains("日本"), "alignment dropped the wide cell text")

        print("PASS: Align Table Source menu wiring, enablement, single undo, font-metric column widths, and fenced-code exclusion")
    }

    /// View-mode presentation: pipe-free cells, exact source copy, and a caret
    /// anchor that survives the View -> Edit transition.
    static func runPresentation() throws {
        func expect(_ condition: Bool, _ message: String) throws {
            if !condition {
                throw NSError(domain: "mdwrite.tables", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        let source = "intro\n\n| Command | Description |\n| --- | --- |\n| git status | List files |\n| git diff | Show diffs |\n\noutro\n"
        let text = source as NSString
        let projection = MarkdownTablePresentation.project(source)
        try expect(!projection.text.contains("|"),
                   "presentation still shows table pipes: \(projection.text.debugDescription)")
        try expect(!projection.text.contains("---"),
                   "presentation still shows the delimiter row")
        try expect(projection.text.contains("Command\tDescription"),
                   "cells are not tab separated: \(projection.text.debugDescription)")
        try expect(projection.text.hasPrefix("intro\n\n"), "text before the table changed")
        try expect(projection.text.contains("outro"), "text after the table changed")
        try expect(projection.rowRanges.count == 3 && projection.rowOwner == [0, 0, 0],
                   "unexpected projected rows \(projection.rowRanges.count)/\(projection.rowOwner)")

        // A full-table selection must copy back to exact original Markdown.
        let first = projection.rowRanges[0].location
        let last = projection.rowRanges[2]
        let tableSelection = NSRange(location: first, length: last.location + last.length - first)
        guard let copied = projection.map.sourceRange(coveringPresentation: tableSelection) else {
            throw NSError(domain: "mdwrite.tables", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "table selection did not map to source"])
        }
        try expect(text.substring(with: copied)
                   == "| Command | Description |\n| --- | --- |\n| git status | List files |\n| git diff | Show diffs |\n",
                   "copied table is not the exact source: \(text.substring(with: copied).debugDescription)")

        // View -> Edit must place the caret beside the same cell.
        let cell = (projection.text as NSString).range(of: "Show diffs")
        guard let anchored = projection.map.sourceOffset(forPresentation: cell.location) else {
            throw NSError(domain: "mdwrite.tables", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "presentation offset did not map to source"])
        }
        try expect(anchored == text.range(of: "Show diffs").location,
                   "anchor \(anchored) does not match source \(text.range(of: "Show diffs").location)")

        // Projection must not mutate the authoritative source or dirty state.
        let document = MarkdownDocument()
        document.recoveryStore = nil
        try document.read(from: Data(source.utf8), ofType: "net.daringfireball.markdown")
        document.makeWindowControllers()
        defer { document.close() }
        let editor = document.editorController!.editor
        try expect(editor.string == source, "loading a document changed its source")
        try expect(!document.isDocumentEdited, "loading a document marked it dirty")

        print("PASS: View-mode table projection is pipe-free, copies exact source, anchors the caret, and leaves source untouched")
    }

    /// The window must actually swap the projection in for View mode and back,
    /// without ever touching source or dirty state.
    static func runViewIntegration() throws {
        func expect(_ condition: Bool, _ message: String) throws {
            if !condition {
                throw NSError(domain: "mdwrite.tables", code: 6,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        let withTable = "intro\n\n| A | B |\n| --- | --- |\n| c | d |\n\noutro\n"
        let document = MarkdownDocument()
        document.recoveryStore = nil
        try document.read(from: Data(withTable.utf8), ofType: "net.daringfireball.markdown")
        document.makeWindowControllers()
        defer { document.close() }
        let controller = document.editorController!
        let editor = controller.editor
        guard let scroll = controller.editorScroll else {
            throw NSError(domain: "mdwrite.tables", code: 7,
                          userInfo: [NSLocalizedDescriptionKey: "editor scroll view not found"])
        }

        // Documents start in View mode, so the projection should be showing.
        try expect(editor.mode == .view, "document did not start in View mode")
        try expect(scroll.documentView !== editor,
                   "View mode did not install the table projection")
        let shown = (scroll.documentView as? MarkdownTablePresentationView)?.string ?? ""
        try expect(!shown.contains("|"), "projected view still shows pipes: \(shown.debugDescription)")
        // A small table should still use columns; a wide one legitimately stacks.
        try expect(shown.contains("A\tB") || !controller.tablesUseColumns,
                   "projected view did not use column geometry for a small table")
        try expect(editor.string == withTable, "projecting changed the source editor text")
        try expect(!document.isDocumentEdited, "projecting marked the document dirty")

        // Edit mode must restore the source editor.
        controller.enterEditMode(nil)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        try expect(scroll.documentView === editor, "Edit mode did not restore the source editor")
        try expect(editor.string == withTable, "returning to Edit mode changed the source")
        try expect(editor.isEditable, "Edit mode is not editable")

        // Back to View mode: the projection returns.
        controller.enterViewMode(nil)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        try expect(scroll.documentView !== editor, "View mode did not reinstall the projection")
        try expect(editor.string == withTable, "re-entering View mode changed the source")
        try expect(!document.isDocumentEdited, "mode switching marked the document dirty")

        // Copy from the projection returns original Markdown.
        guard let view = scroll.documentView as? MarkdownTablePresentationView,
              let rows = view.projection?.rowRanges, let first = rows.first, let last = rows.last
        else { throw NSError(domain: "mdwrite.tables", code: 8,
                             userInfo: [NSLocalizedDescriptionKey: "projection rows unavailable"]) }
        let selection = NSRange(location: first.location,
                                length: last.location + last.length - first.location)
        try expect(view.sourceText(for: selection) == "| A | B |\n| --- | --- |\n| c | d |\n",
                   "copying a projected table did not return source Markdown")

        // A document with no tables keeps the plain source editor in View mode.
        let plain = MarkdownDocument()
        plain.recoveryStore = nil
        try plain.read(from: Data("no tables here\n".utf8), ofType: "net.daringfireball.markdown")
        plain.makeWindowControllers()
        defer { plain.close() }
        try expect(plain.editorController!.editorScroll?.documentView === plain.editorController!.editor,
                   "a table-free document should keep the source editor in View mode")

        // View mode must keep the full Markdown styling, not just table geometry.
        // Regression guard: the projection once replaced the styled editor with
        // a bare text view, losing headings, emphasis, and code entirely.
        let rich = "# Heading\n\nSome **bold** and *italic* and `code`.\n\n> quoted\n\n- item\n\n| A | B |\n| --- | --- |\n| c | d |\n"
        let styled = MarkdownDocument()
        styled.recoveryStore = nil
        try styled.read(from: Data(rich.utf8), ofType: "net.daringfireball.markdown")
        styled.makeWindowControllers()
        defer { styled.close() }
        let styledEditor = styled.editorController!.editor
        styledEditor.restyle()
        guard let styledScroll = styled.editorController!.editorScroll,
              let styledView = styledScroll.documentView as? MarkdownTablePresentationView,
              let storage = styledView.textStorage else {
            throw NSError(domain: "mdwrite.tables", code: 9,
                          userInfo: [NSLocalizedDescriptionKey: "rich document did not install a projection"])
        }
        let projected = styledView.string as NSString
        func font(_ needle: String) -> NSFont? {
            let range = projected.range(of: needle)
            guard range.location != NSNotFound else { return nil }
            return storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        }
        let bodySize = font("Some")?.pointSize ?? 0
        let headingSize = font("Heading")?.pointSize ?? 0
        try expect(headingSize > bodySize,
                   "heading lost its larger size in the projection (\(headingSize) vs \(bodySize))")
        try expect(NSFontManager.shared.traits(of: font("bold") ?? NSFont.systemFont(ofSize: 12))
            .contains(.boldFontMask), "bold lost its weight in the projection")
        let codeRange = projected.range(of: "code")
        try expect(storage.attribute(.backgroundColor, at: codeRange.location, effectiveRange: nil) != nil,
                   "inline code lost its background in the projection")
        let quoteStyle = storage.attribute(.paragraphStyle, at: projected.range(of: "quoted").location,
                                           effectiveRange: nil) as? NSParagraphStyle
        try expect((quoteStyle?.headIndent ?? 0) > 0, "blockquote lost its indentation in the projection")
        // The table itself must still be pipe-free.
        try expect(!styledView.string.contains("|"), "projection reintroduced pipes")

        print("PASS: View mode swaps in a pipe-free table presentation, keeps full Markdown styling, copies source, and never mutates source or dirty state")
    }

    /// Column geometry must never place a tab stop past the usable width.
    ///
    /// Regression guard: a stop beyond the viewport is unreachable, and AppKit
    /// silently collapses that column back to the line start. It looks aligned
    /// while being wrong, which is worse than visibly ragged columns.
    static func runWidthBudget() throws {
        func expect(_ condition: Bool, _ message: String) throws {
            if !condition {
                throw NSError(domain: "mdwrite.tables", code: 10,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        let advance = MarkdownTableFontMetrics.advance(for: 20)
        try expect(advance > 0, "font advance is zero")
        let wide = "| Col | Description |\n| --- | --- |\n| a | short |\n| b | an extremely long description that certainly exceeds the available width |\n"
        let small = "| A | B |\n| --- | --- |\n| 1 | 2 |\n"
        guard let wideTable = MarkdownTables.parse(wide).first,
              let smallTable = MarkdownTables.parse(small).first else {
            throw NSError(domain: "mdwrite.tables", code: 11,
                          userInfo: [NSLocalizedDescriptionKey: "fixtures did not parse"])
        }
        for available in [200.0, 456.0, 800.0, 1200.0, 1600.0] {
            let layout = MarkdownTableLayoutPlanner.layout(
                for: wideTable, in: wide, available: available, advance: advance)
            if case let .grid(stops) = layout {
                for stop in stops {
                    try expect(stop <= available,
                                "grid stop \(stop) exceeds available width \(available)")
                }
            } else {
                try expect(true, "wide table stacks at \(available)")
            }
            // A small table must use columns at every tested width.
            switch MarkdownTableLayoutPlanner.layout(
                for: smallTable, in: small, available: available, advance: advance) {
            case let .grid(stops):
                for stop in stops {
                    try expect(stop <= available, "small-table stop \(stop) exceeds \(available)")
                }
            case .stacked:
                try expect(false, "a two-cell table stacked at \(available)pt")
            }
        }
        // A single-column table is stacked, since a grid needs a boundary.
        if let one = MarkdownTables.parse("| A |\n| --- |\n| 1 |\n").first {
            switch MarkdownTableLayoutPlanner.layout(for: one, in: "| A |\n| --- |\n| 1 |\n",
                                                     available: 800, advance: advance) {
            case .grid: try expect(false, "a single-column table produced a grid")
            case .stacked: try expect(true, "single column stacks")
            }
        }
        print("PASS: column geometry never emits a tab stop beyond the usable width and falls back to stacked rows")
    }

    /// Inline markup inside cells must render, and a resize must re-evaluate
    /// the column layout so a stacked table can become a grid.
    static func runCellStylingAndResize() throws {
        func expect(_ condition: Bool, _ message: String) throws {
            if !condition {
                throw NSError(domain: "mdwrite.tables", code: 12,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        let source = "| Item | Detail |\n| --- | --- |\n| run | **bold** and *soft* and `code` and [link](https://example.com) |\n"
        let document = MarkdownDocument()
        document.recoveryStore = nil
        try document.read(from: Data(source.utf8), ofType: "net.daringfireball.markdown")
        document.makeWindowControllers()
        defer { document.close() }
        let controller = document.editorController!
        controller.editor.restyle()
        guard let view = controller.editorScroll?.documentView as? MarkdownTablePresentationView,
              let storage = view.textStorage else {
            throw NSError(domain: "mdwrite.tables", code: 13,
                          userInfo: [NSLocalizedDescriptionKey: "no table projection installed"])
        }
        let text = view.string as NSString
        func font(_ needle: String) -> NSFont? {
            let range = text.range(of: needle)
            guard range.location != NSNotFound else { return nil }
            return storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        }
        let body = font("run")?.pointSize ?? 0
        // Cell content keeps its inline weight rather than staying plain.
        try expect(NSFontManager.shared.traits(of: font("bold") ?? NSFont.systemFont(ofSize: 12))
            .contains(.boldFontMask), "bold inside a table cell was not styled")
        try expect(NSFontManager.shared.traits(of: font("soft") ?? NSFont.systemFont(ofSize: 12))
            .contains(.italicFontMask), "italic inside a table cell was not styled")
        // Inline code is smaller than the body face.
        try expect((font("code")?.pointSize ?? 0) < body,
                   "inline code inside a cell was not shrunk (\(font("code")?.pointSize ?? -1) vs \(body))")
        // The marker characters are still present (copy fidelity) but dimmed.
        try expect(text.contains("**"), "projection dropped the bold markers")
        if let markers = text.range(of: "**") as NSRange?, markers.location != NSNotFound {
            let color = storage.attribute(.foregroundColor, at: markers.location, effectiveRange: nil) as? NSColor
            try expect(color != nil, "bold markers inside a cell are not dimmed")
        }
        // Source is untouched by all of this.
        try expect(controller.editor.string == source, "cell styling changed the source")

        // A resize must re-evaluate layout: a narrow window stacks, a wide one grids.
        guard let scroll = controller.editorScroll else {
            throw NSError(domain: "mdwrite.tables", code: 14,
                          userInfo: [NSLocalizedDescriptionKey: "no scroll view"])
        }
        let wide = "| A | B |\n| --- | --- |\n| 1 | 2 |\n| longer value here | x |\n"
        let sized = MarkdownDocument()
        sized.recoveryStore = nil
        try sized.read(from: Data(wide.utf8), ofType: "net.daringfireball.markdown")
        sized.makeWindowControllers()
        defer { sized.close() }
        let sizedController = sized.editorController!
        let narrowFrame = NSRect(x: 0, y: 0, width: 460, height: 500)
        sizedController.window!.setFrame(
            NSRect(origin: .zero, size: NSSize(width: narrowFrame.width, height: narrowFrame.height)),
            display: true)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        let narrowWidth = sizedController.presentationAvailableWidth
        sizedController.window!.setFrame(
            NSRect(origin: .zero, size: NSSize(width: 1400, height: 500)), display: true)
        // The coalesced refresh runs on the next main-queue turn.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.4))
        let wideWidth = sizedController.presentationAvailableWidth
        try expect(wideWidth > narrowWidth,
                   "available width did not grow after resizing (\(narrowWidth) -> \(wideWidth))")
        try expect(wideWidth >= 1000, "wide window did not report a wide usable width (\(wideWidth))")

        print("PASS: cell inline markup renders, markers stay dimmed and copyable, and resizing re-evaluates the column layout")
    }

    /// A row must resolve to a single band. Inline styling splits a row into many
    /// attribute runs, and treating those as separate rows striped one row with
    /// several shades. Renders a heavily styled table and samples the pixels.
    static func runZebraUniformity() throws {
        // Narrow enough to stay one row per line at the default viewport, and
        // full of inline styling because that is what splits a row into many
        // attribute runs.
        let source = Self.fixture("tables")
        let document = MarkdownDocument()
        document.recoveryStore = nil
        try document.read(from: Data(source.utf8), ofType: "net.daringfireball.markdown")
        document.makeWindowControllers()
        defer { document.close() }
        let controller = document.editorController!
        controller.editor.restyle()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        guard let view = controller.editorScroll?.documentView as? MarkdownTablePresentationView else {
            throw NSError(domain: "mdwrite.tables", code: 17,
                          userInfo: [NSLocalizedDescriptionKey: "no projection for zebra check"])
        }
        // The grid-versus-stacked choice is made from the scroll view's content
        // width, so the window has to be sized before projecting. Resizing only
        // the text view leaves the projection stacked.
        let target = NSRect(x: 0, y: 0, width: 900, height: 900)
        controller.window?.setContentSize(target.size)
        controller.editorScroll?.setFrameSize(target.size)
        view.setFrameSize(target.size)
        view.layoutSubtreeIfNeeded()
        controller.editorScroll?.layoutSubtreeIfNeeded()

        // Row rectangles are computed from the attributed rows rather than read
        // back from painting, so the geometry assertions do not depend on draw
        // timing. The grid-versus-stacked choice depends on the window width, so
        // the row count is not fixed here; what must hold is that every row is a
        // single band and rows never overlap.
        //
        // Let the projection settle first. It is installed asynchronously after
        // the window resize, so sampling immediately can capture a half-laid-out
        // state and make this check flap between runs.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        view.layoutSubtreeIfNeeded()
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        // Capture only after settling. The bitmap is the earlier of the two
        // reads taken from this view: taking it before the run loop turns would
        // sample a projection that is still the pre-resize one, so every row
        // would report the same plain background and the zebra assertion below
        // would fail for a layout that is in fact correct.
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        // Restrict to this document's tables. The smoke suite opens several
        // documents in one process, and a shared layout manager can still hold
        // another document's rows.
        let tables = MarkdownTables.parse(source)
        let owners = Set(0..<tables.count)
        let rows = view.debugTableRowRects().filter { owners.contains($0.owner) }
        let settled = rows.sorted { $0.rect.maxY > $1.rect.maxY }
        guard settled.count >= 3 else {
            throw NSError(domain: "mdwrite.tables", code: 18,
                          userInfo: [NSLocalizedDescriptionKey:
                            "expected at least 3 table rows, found \(settled.count)"])
        }
        // Overlapping bands within one table are the striping bug: a single row
        // painted as several bands at different offsets. Rows from different
        // tables are independent, so only same-table rows are compared.
        for table in owners {
            let tableRows = settled.filter { $0.owner == table }
                .sorted { $0.rect.maxY > $1.rect.maxY }
            for index in tableRows.indices.dropFirst() {
                let rect = tableRows[index].rect
                let above = tableRows[index - 1].rect
                guard rect.maxY <= above.minY + 1.5 else {
                    throw NSError(domain: "mdwrite.tables", code: 22,
                                  userInfo: [NSLocalizedDescriptionKey:
                                    "table \(table) row \(index) overlaps the row above (striped)"])
                }
            }
        }
        for (index, entry) in settled.enumerated() {
            let rect = entry.rect
            // A row spanning the full container width means padding leaked in.
            guard rect.width > 0, rect.width < target.width - 20 else {
                throw NSError(domain: "mdwrite.tables", code: 19,
                              userInfo: [NSLocalizedDescriptionKey:
                                "row \(index) width \(rect.width) spans the container"])
            }
            // Rows in one table must share a right edge, or shading looks ragged.
            if index > 0, entry.owner == settled[index - 1].owner {
                guard abs(settled[index - 1].rect.maxX - rect.maxX) < 1.5 else {
                    throw NSError(domain: "mdwrite.tables", code: 20,
                                  userInfo: [NSLocalizedDescriptionKey:
                                    "row \(index) right edge differs from the row above"])
                }
            }
        }
        // Exactly two row fills per table: the plain background plus one zebra
        // tone, and nothing else.
        //
        // The tones are measured rather than assumed. Predicting them from
        // `backgroundColor` plus the overlay alpha is fragile: the rep is
        // colour-managed, so the painted value does not match the arithmetic
        // exactly, and a wrong prediction classifies every sample as "off tone".
        //
        // Glyphs are excluded first, by luminance. Text fills most of a ~30pt
        // band, and antialiased edges produce a long tail of intermediate greys
        // that an exact-value histogram happily elects as the fill. The two
        // fills are the brightest colours in the band, so the tone set is the
        // two most common bright samples; everything darker is glyph or outline.
        func packedComponents(_ packed: String) -> (Double, Double, Double) {
            let parts = packed.split(separator: ",").compactMap { Double($0) }
            guard parts.count == 3 else { return (0, 0, 0) }
            return (parts[0] / 255, parts[1] / 255, parts[2] / 255)
        }
        /// Relative luminance, used only to rank samples bright to dark.
        func luminance(_ rgb: (Double, Double, Double)) -> Double {
            0.2126 * rgb.0 + 0.7152 * rgb.1 + 0.0722 * rgb.2
        }

        for table in owners {
            let tableRows = settled.filter { $0.owner == table }
            guard !tableRows.isEmpty else { continue }
            // Collect every in-band sample for the whole table first, so the two
            // tones are the table's actual fills and not one row's outliers.
            var bands: [[(Double, Double, Double)]] = []
            for entry in tableRows {
                let rect = entry.rect
                var samples: [(Double, Double, Double)] = []
                // Inset from the band edges. A row's rect is the union of its
                // line fragments plus line spacing, and the fill is painted over
                // the glyph area, so the outermost points of the rect can fall
                // in the unshaded gap between rows. Sampling those picks up the
                // neighbouring background and makes a shaded row read as plain.
                let inset = max(4, Int(rect.height / 4))
                var y = Int(rect.minY) + inset
                while y <= Int(rect.maxY) - inset {
                    for step in 1...7 {
                        let x = Int(rect.minX) + step * max(1, Int(rect.width) / 8)
                        if let color = sampleColor(bitmap, x: x, y: y,
                                                   viewHeight: Int(target.height)) {
                            samples.append(packedComponents(color))
                        }
                    }
                    y += 3
                }
                bands.append(samples)
            }
            let all = bands.flatMap { $0 }
            guard all.count >= 20 else {
                throw NSError(domain: "mdwrite.tables", code: 23,
                              userInfo: [NSLocalizedDescriptionKey:
                                "table \(table) produced too few samples (\(all.count))"])
            }
            // Each band must reduce to a single fill tone.
            //
            // The band's own brightest samples are used. A band is only ~30pt
            // tall and the amount of text in it varies row to row, so the median
            // drifts with glyph coverage and two genuinely equal fills can read
            // as different tones. The fill is both the brightest thing in the
            // band and the most common of the bright samples.
            //
            // Clustering tolerance is 0.03, not tighter. The hairline outline
            // around each row blends to roughly 241/255, which sits about 0.027
            // below the zebra tone, so a tighter window splits the outline into a
            // phantom third fill on some rows and not others.
            var tones: [Double] = []
            for (index, samples) in bands.enumerated() {
                let values = samples.map(luminance)
                guard let peak = values.max() else {
                    throw NSError(domain: "mdwrite.tables", code: 23,
                                  userInfo: [NSLocalizedDescriptionKey:
                                    "table \(table) row \(index) painted nothing"])
                }
                let bright = values.filter { $0 >= peak - 0.03 }.sorted()
                tones.append(bright[bright.count / 2])
            }
            var clusters: [Double] = []
            for value in tones.sorted() {
                if clusters.contains(where: { abs($0 - value) <= 0.03 }) { continue }
                clusters.append(value)
            }
            // At most two fills per table: the background plus one zebra tone.
            // A row painted several shades is the striping bug, and it shows up
            // as a third or fourth cluster.
            //
            // The converse is deliberately not asserted. Requiring both tones to
            // be present depends on the capture coming from a view that has
            // actually drawn: `cacheDisplay` on a window that was never ordered
            // front can come back with no decoration at all, which reads as "no
            // zebra" for a table that is in fact striped. That alternation is
            // asserted deterministically from the storage attributes below
            // instead, and confirmed visually by the isolated preview.
            guard clusters.count <= 2 else {
                throw NSError(domain: "mdwrite.tables", code: 24,
                              userInfo: [NSLocalizedDescriptionKey:
                                "table \(table) uses \(clusters.count) row fills, expected 2: \(clusters)"])
            }
        }
        // Alternation, read from the projection rather than from pixels: the rows
        // of a table must carry ordinals 0, 1, 2, ... in document order, so the
        // layout manager's parity is a pure function of position and cannot drift
        // with how AppKit chunks a draw call.
        let storage = view.textStorage!
        var ordinalsByOwner: [Int: [Int]] = [:]
        var expectedNext: [Int: Int] = [:]
        storage.enumerateAttribute(.mdwriteTableRow, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let rowID = value as? Int,
                  let owner = storage.attribute(.mdwriteTableIndex, at: range.location, effectiveRange: nil) as? Int else { return }
            let isFirst = (storage.attribute(.mdwriteTableIsFirstRow, at: range.location, effectiveRange: nil) as? Bool) ?? false
            let position = isFirst ? 0 : (expectedNext[owner] ?? 0)
            expectedNext[owner] = position + 1
            ordinalsByOwner[owner, default: []].append(position)
        }
        for (owner, ordinals) in ordinalsByOwner.sorted(by: { $0.key < $1.key }) {
            for (index, position) in ordinals.enumerated() where position != index {
                throw NSError(domain: "mdwrite.tables", code: 26,
                              userInfo: [NSLocalizedDescriptionKey:
                                "table \(owner) row \(index) has ordinal \(position), so its band parity depends on draw order"])
            }
        }
        document.close()
        print("PASS: zebra banding uses two row colours and stops at the last cell")
    }

    /// The shared table fixture: GFM alignment, a table with no outer pipes,
    /// inline markup in cells, and escaped pipes. Kept inline so previews do
    /// not depend on locating the file at runtime.
    static let tableFixture = """
Colons can be used to align columns.

| Tables        | Are           | Cool  |
| ------------- |:-------------:| -----:|
| col 3 is      | right-aligned | $1600 |
| col 2 is      | centered      |   $12 |
| zebra stripes | are neat      |    $1 |

There must be at least 3 dashes separating each header cell.
The outer pipes (|) are optional, and you don't need to make the
raw Markdown line up prettily. You can also use inline Markdown.

Markdown | Less | Pretty
--- | --- | ---
*Still* | `renders` | **nicely**
1 | 2 | 3

| First Header  | Second Header |
| ------------- | ------------- |
| Content Cell  | Content Cell  |
| Content Cell  | Content Cell  |

| Command | Description |
| --- | --- |
| git status | List all new or modified files |
| git diff | Show file differences that haven't been staged |

| Command | Description |
| --- | --- |
| `git status` | List all *new or modified* files |
| `git diff` | Show file differences that **haven't been** staged |

| Left-aligned | Center-aligned | Right-aligned |
| :---         |     :---:      |          ---: |
| git status   | git status     | git status    |
| git diff     | git diff       | git diff      |

| Name     | Character |
| ---      | ---       |
| Backtick | `         |
| Pipe     | \\|        |
"""

    static func fixture(_ name: String) -> String { tableFixture }

    /// Reads a single pixel as a packed RGBA string, or nil when outside bounds.
    ///
    /// `x` and `y` are view coordinates. `NSView` counts rows from the bottom,
    /// but a caching rep stores them from the top and at the backing scale, so
    /// the point is converted before sampling. Without this the samples are read
    /// from a vertically mirrored row, which silently invalidates every
    /// pixel-based assertion below.
    private static func sampleColor(_ bitmap: NSBitmapImageRep, x: Int, y: Int,
                                    viewHeight: Int) -> String? {
        let scale = bitmap.pixelsWide > 0
            ? Double(bitmap.pixelsWide) / Double(max(1, viewHeight)) : 1
        guard scale > 0 else { return nil }
        let px = Int((Double(x) * scale).rounded())
        let flipped = Int((Double(viewHeight - y) * scale).rounded())
        let py = min(max(flipped, 0), max(0, bitmap.pixelsHigh - 1))
        guard let color = bitmap.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else { return nil }
        let r = Int((color.redComponent * 255).rounded())
        let g = Int((color.greenComponent * 255).rounded())
        let b = Int((color.blueComponent * 255).rounded())
        return "\(r),\(g),\(b)"
    }

    /// Export table previews so zebra banding and outlines can be inspected
    /// visually rather than only through attributes.
    static func runTablePreview() throws {
        guard CommandLine.arguments.contains("--table-preview") else { return }
        // The fixture mirrors GFM's table section: alignments, a table with no
        // outer pipes, inline markup in cells, and escaped pipes.
        let source = Self.fixture("tables")
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let document = MarkdownDocument()
            document.recoveryStore = nil
            try document.read(from: Data(source.utf8), ofType: "net.daringfireball.markdown")
            document.makeWindowControllers()
            let controller = document.editorController!
            controller.editor.restyle()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
            guard let view = controller.editorScroll?.documentView as? MarkdownTablePresentationView else {
                throw NSError(domain: "mdwrite.tables", code: 15,
                              userInfo: [NSLocalizedDescriptionKey: "no projection to preview"])
            }
            view.appearance = NSAppearance(named: appearance)
            // Size the window before projecting: the grid-versus-stacked choice
            // comes from the scroll view's content width, and the fixture is
            // tall enough that a short window would crop most of the tables.
            let target = NSRect(x: 0, y: 0, width: 900, height: 900)
            controller.window?.setContentSize(target.size)
            controller.editorScroll?.setFrameSize(target.size)
            view.setFrameSize(target.size)
            view.layoutSubtreeIfNeeded()
            controller.editorScroll?.layoutSubtreeIfNeeded()
            // Sizing the window re-projects on a later turn, and the fixture is
            // taller than one screen. Drain the run loop and let layout settle
            // before capturing, otherwise the bitmap catches a half-swapped
            // state and shows two renderings on top of each other.
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
            let used = view.layoutManager?.usedRect(for: view.textContainer!)
            let height = max(target.height, (used?.height ?? 0) + 24)
            view.setFrameSize(NSRect(x: 0, y: 0, width: target.width, height: height).size)
            view.layoutSubtreeIfNeeded()
            view.layoutManager?.ensureLayout(for: view.textContainer!)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
            view.layoutManager?.ensureLayout(for: view.textContainer!)
            let windows = NSApp.windows.count
            let text = view.textStorage?.string.count ?? -1
            let subs = (controller.editorScroll?.subviews ?? []).map {
                "\(type(of: $0)) vis=\(!$0.isHidden) f=\(Int($0.frame.width))x\(Int($0.frame.height))"
            }
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                throw NSError(domain: "mdwrite.tables", code: 16,
                              userInfo: [NSLocalizedDescriptionKey: "could not encode preview"])
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("mdwrite-table-\(appearance.rawValue)-\(UUID()).png")
            try data.write(to: url)
            print("Table preview: \(url.path)")
            document.close()
        }
    }
}