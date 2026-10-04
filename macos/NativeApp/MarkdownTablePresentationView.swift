import AppKit
import EditorCore

/// Owns the View-mode presentation of a document's tables.
///
/// `MarkdownDocument.sourceStorage` stays authoritative for Save, recovery,
/// dirty tracking, word count, and undo. This view is read-only and holds a
/// projected copy of the source in which recognized tables appear pipe-free.
/// It never writes back to source; the source/presentation map converts
/// selections, copies, and caret anchors.
@MainActor
final class MarkdownTablePresentationView: NSTextView {
    /// The projection currently installed, or nil when no table is present.
    private(set) var projection: MarkdownTablePresentation.Result?
    /// Band rects for the rows in a character range, computed on demand rather
    /// than read from the last draw. Drawing re-enters, so the most recent pass
    /// is not a reliable record of what is on screen.
    func debugTableRowRects() -> [(owner: Int, rowID: Int, rect: NSRect)] {
        guard let manager = layoutManager as? MarkdownLayoutManager,
              let storage = textStorage else { return [] }
        return manager.debugRowRects(in: storage)
    }
    /// The exact source the installed projection was built from.
    private(set) var projectedSource: String?

    override init(frame frameRect: NSRect, textContainer: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: textContainer)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        isEditable = false
        isSelectable = true
        isRichText = false
        importsGraphics = false
        allowsUndo = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        setAccessibilityIdentifier("mdwrite.tablePresentation")
    }

    /// Install a projection of `source`, styled like the source editor but with
    /// column tab stops on projected table rows. Returns false when there are no
    /// table rows, so the caller can keep showing ordinary styled source.
    ///
    /// `available` is the usable text width. When the columns cannot fit inside
    /// it, no tab stops are installed: an unreachable stop makes AppKit collapse
    /// the column inline, which reads as aligned but is not.
    @discardableResult
    func install(projection: MarkdownTablePresentation.Result, source: String,
                 fontSize: CGFloat, available: Double) -> Bool {
        guard !projection.rowRanges.isEmpty else { return false }
        let stops = columnTabStops(projection: projection, available: available, fontSize: fontSize)
        self.projection = projection
        projectedSource = source
        columnsFit = !stops.isEmpty
        // Read the recorded style rather than searching the text for a pipe: a
        // cell may legitimately contain a literal `|`, and treating that content
        // as a separator suppressed the tab stops for every other table.
        usesPipes = projection.rowStyle == .pipes
        guard let storage = textStorage else { return false }
        // Replacing the storage leaves the old glyphs in place: a previous
        // projection may have wrapped at a different width, so its glyph
        // positions survive and get drawn on top of the new text. Drop them
        // before restyling so only the new projection is painted.
        storage.beginEditing()
        let previous = NSRange(location: 0, length: storage.length)
        layoutManager?.invalidateDisplay(forCharacterRange: previous)
        storage.setAttributedString(NSAttributedString(
            string: projection.text,
            attributes: MarkdownStyler.baseAttributes(fontSize: fontSize)))
        // Style the projected text first. The analyzer sees tab-separated cells,
        // which it does not recognize as a table, so it styles everything else
        // normally and leaves the projected cells to the geometry pass below.
        _ = MarkdownStyler.apply(to: storage, fontSize: fontSize)
        applyTableStyling(to: storage, projection: projection, fontSize: fontSize, tabStops: stops)
        storage.endEditing()
        // The new string can wrap differently, so re-run layout for all of it.
        layoutManager?.invalidateDisplay(forCharacterRange: NSRange(location: 0, length: storage.length))
        layoutManager?.ensureLayout(for: textContainer!)
        return true
    }

    /// True when the presentation draws its own column separators, so tab stops
    /// would double the indent.
    private(set) var usesPipes = false

    /// True when column geometry fits the available width; false means the
    /// table is showing without column alignment.
    private(set) var columnsFit = true

    /// Semibold header rows, aligned column tab stops, and inline markup inside
    /// cells. Header weight is applied before inline styling so a bold header
    /// cell containing `**bold**` is not flattened.
    private func applyTableStyling(to attributed: NSMutableAttributedString,
                                   projection: MarkdownTablePresentation.Result,
                                   fontSize: CGFloat, tabStops: [NSTextTab]) {
        for (index, range) in projection.rowRanges.enumerated() {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = fontSize * 0.25
            paragraph.tabStops = tabStops
            // In pipe mode the literal separators already position the columns,
            // so tab stops are suppressed to avoid a double indent.
            let effectiveStops = usesPipes ? [] : tabStops
            attributed.addAttribute(.paragraphStyle, value: paragraph, range: range)
            if !effectiveStops.isEmpty {
                let withStops = (paragraph.mutableCopy() as! NSMutableParagraphStyle)
                withStops.tabStops = effectiveStops
                attributed.addAttribute(.paragraphStyle, value: withStops, range: range)
            }
            // Indent a projected table to sit inside its quote or list, matching
            // the surrounding blocks rather than flush against the gutter.
            if index < projection.rowOwner.count,
               let indent = projection.rowIndent[safe: index], indent > 0 {
                let indented = (paragraph.mutableCopy() as! NSMutableParagraphStyle)
                indented.headIndent = indent
                indented.firstLineHeadIndent = indent
                attributed.addAttribute(.paragraphStyle, value: indented, range: range)
            }
            // Within each table, the first projected row is the header.
            let owner = index < projection.rowOwner.count ? projection.rowOwner[index] : -1
            let previous = index > 0 && index - 1 < projection.rowOwner.count
                ? projection.rowOwner[index - 1] : -2
            // Tag the row so the layout manager can band and outline it without
            // re-parsing tables while drawing.
            attributed.addAttribute(.mdwriteTableRow, value: index, range: range)
            attributed.addAttribute(.mdwriteTableIndex, value: owner, range: range)
            attributed.addAttribute(.mdwriteTableIsFirstRow, value: owner != previous, range: range)
            let next = index + 1 < projection.rowOwner.count ? projection.rowOwner[index + 1] : -2
            attributed.addAttribute(.mdwriteTableIsLastRow, value: owner != next, range: range)
            if owner != previous {
                attributed.addAttribute(
                    .font,
                    value: NSFontManager.shared.convert(
                        MarkdownTableFontMetrics.bodyFont(size: fontSize), toHaveTrait: .boldFontMask),
                    range: range)
            }
        }
        applyInlineStyling(in: attributed, projection: projection, fontSize: fontSize)
    }

    /// Render emphasis, inline code, and link labels inside projected cells.
    ///
    /// The projection preserves each cell's source spelling, so the shared inline
    /// analyzer already resolved the runs; they only need to be applied here
    /// because table rows were excluded from the normal document styling pass.
    private func applyInlineStyling(in attributed: NSMutableAttributedString,
                                    projection: MarkdownTablePresentation.Result,
                                    fontSize: CGFloat) {
        let sp = MarkdownSpans.inline(in: projection.text)
        guard !sp.isEmpty else { return }
        let body = MarkdownTableFontMetrics.bodyFont(size: fontSize)
        let codeFont = NSFont.monospacedSystemFont(ofSize: fontSize * 0.9, weight: .regular)
        let dim = NSColor.tertiaryLabelColor
        // Only touch ranges that fall inside a projected row.
        func insideTable(_ range: NSRange) -> Bool {
            projection.rowRanges.contains { NSIntersectionRange($0, range).length > 0 }
        }
        for span in sp where insideTable(span.content) {
            for marker in span.markers where insideTable(marker) {
                attributed.addAttribute(.foregroundColor, value: dim, range: marker)
            }
            switch span.kind {
            case .bold:
                attributed.addAttribute(
                    .font, value: NSFontManager.shared.convert(body, toHaveTrait: .boldFontMask),
                    range: span.content)
            case .italic:
                attributed.addAttribute(
                    .font, value: NSFontManager.shared.convert(body, toHaveTrait: .italicFontMask),
                    range: span.content)
            case .link:
                attributed.addAttribute(.foregroundColor, value: NSColor.linkColor, range: span.content)
            }
        }
        // Inline code inside a cell keeps its smaller face and background.
        let ticks = try? NSRegularExpression(pattern: #"`([^`\n]+)`"#)
        if let ticks {
            let whole = NSRange(location: 0, length: attributed.length)
            for match in ticks.matches(in: projection.text, range: whole)
            where insideTable(match.range) {
                attributed.addAttribute(.font, value: codeFont, range: match.range)
                attributed.addAttribute(.foregroundColor, value: dim, range: match.range(at: 1))
                // Dim the backticks too. Only the code content was faded, which
                // left `renders` showing its delimiters at full opacity while the
                // emphasis markers beside it were correctly hidden.
                if match.range(at: 1).location > match.range.location {
                    attributed.addAttribute(
                        .foregroundColor, value: dim,
                        range: NSRange(location: match.range.location, length: 1))
                }
                if match.range(at: 1).location < NSMaxRange(match.range) - 1 {
                    attributed.addAttribute(
                        .foregroundColor, value: dim,
                        range: NSRange(location: NSMaxRange(match.range) - 1, length: 1))
                }
            }
        }
    }

    /// Source text for a presentation selection, so Copy returns real Markdown.
    func sourceText(for range: NSRange) -> String? {
        guard let projection, let source = projectedSource else { return nil }
        guard let sourceRange = projection.map.sourceRange(coveringPresentation: range) else { return nil }
        return (source as NSString).substring(with: sourceRange)
    }

    /// Source offset for a presentation caret position, for View -> Edit.
    func sourceOffset(forPresentation offset: Int) -> Int? {
        projection?.map.sourceOffset(forPresentation: offset)
    }

    /// Invoked when the reader presses E over the projection; the controller maps
    /// the caret back into source before switching to Edit mode.
    var editRequested: ((Int) -> Void)?

    override func keyDown(with event: NSEvent) {
        // E enters Edit mode from the presentation without inserting a character.
        if event.charactersIgnoringModifiers?.lowercased() == "e",
           event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
            editRequested?(selectedRange().location)
            return
        }
        super.keyDown(with: event)
    }

    /// Copy returns the original Markdown, not the projected cell text.
    override func copy(_ sender: Any?) {
        let selection = selectedRange()
        guard selection.length > 0, let text = sourceText(for: selection) else {
            super.copy(sender)
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Column geometry from the budgeted planner.
    ///
    /// Every stop is guaranteed to lie inside the available width. A stop past
    /// the viewport is unreachable, and AppKit silently collapses the column
    /// back to the line start instead of aligning it.
    private func columnTabStops(projection: MarkdownTablePresentation.Result,
                                available: Double, fontSize: CGFloat) -> [NSTextTab] {
        let advance = MarkdownTableFontMetrics.advance(for: fontSize)
        guard advance > 0 else { return [] }
        // One pass: measure every projected row, then reduce to shared widths.
        let text = projection.text as NSString
        var perRow: [[Double]] = []
        perRow.reserveCapacity(projection.rowRanges.count)
        for row in projection.rowRanges {
            var cells: [Double] = []
            var start = row.location
            var index = row.location
            while index <= NSMaxRange(row) {
                if index == NSMaxRange(row) || text.character(at: index) == 9 {
                    let value = text.substring(with: NSRange(location: start, length: index - start))
                    cells.append(Double(MarkdownTableFontMetrics.cells(in: value)) * advance)
                    start = index + 1
                }
                index += 1
            }
            perRow.append(cells)
        }
        guard !perRow.isEmpty else { return [] }
        // Tables of different shapes get their own stops, keyed by column count.
        var widthsByShape: [Int: [Double]] = [:]
        for cells in perRow {
            let key = cells.count
            var widths = widthsByShape[key] ?? Array(repeating: 0, count: key)
            for (column, width) in cells.enumerated() { widths[column] = max(widths[column], width) }
            widthsByShape[key] = widths
        }
        let minimum = max(MarkdownTableLayoutPlanner.minimumColumnWidth, advance * 4)
        // The widest shape must fit, otherwise no grid is possible. Include the
        // separators the row style will actually draw, so a shape is not
        // approved here and then found to overflow once its pipes are added.
        var extra: Double = 0
        if projection.rowStyle == .pipes, let widest = widthsByShape.values.max(by: { $0.count < $1.count }) {
            extra = Double(1 + 2 * (widest.count - 1)) * advance
        }
        for (_, widths) in widthsByShape {
            let padded = widths.map { max($0 + MarkdownTableLayoutPlanner.columnPadding, minimum) }
            let total = padded.reduce(0, +) + extra
            guard total <= available else { return [] }
        }
        // Rows with more columns than any other shape are stacked instead.
        let stopSet = widthsByShape.values.max(by: { $0.count < $1.count }) ?? []
        let padded = stopSet.map { max($0 + MarkdownTableLayoutPlanner.columnPadding, minimum) }
        var stops: [NSTextTab] = []
        var x: Double = 0
        for width in padded.dropLast() {
            x += width
            guard x <= available else { return [] }
            stops.append(NSTextTab(textAlignment: .left, location: x))
        }
        return stops
    }
}