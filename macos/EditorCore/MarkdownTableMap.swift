import Foundation

/// One span of a rendered table, tagged so a presentation offset can always be
/// resolved back to source. Generated text (separators, "Column N" labels) has no
/// source and copies as nothing.
public struct MarkdownTableMapSegment: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Verbatim source text; presentation and source ranges are identical.
        case verbatim(NSRange)
        /// Source text that is hidden in the presentation, such as pipes,
        /// alignment markers, and the delimiter row.
        case hidden(NSRange)
        /// Presentation-only text with no source span.
        case generated
    }

    public let kind: Kind
    /// Range within the presentation string.
    public let presentation: NSRange
    /// Matching source range, absent for `generated`.
    public let source: NSRange?

    public init(kind: Kind, presentation: NSRange, source: NSRange?) {
        self.kind = kind
        self.presentation = presentation
        self.source = source
    }
}

/// Bidirectional UTF-16 map between one table's source and its presentation.
public struct MarkdownTableMap: Equatable, Sendable {
    public let segments: [MarkdownTableMapSegment]
    public let presentationLength: Int

    /// Source range for a presentation range, or nil when the selection touches
    /// generated text that has no source.
    public func sourceRange(forPresentation range: NSRange) -> NSRange? {
        var lower: Int?
        var upper: Int?
        for segment in segments {
            let start = segment.presentation.location
            let end = NSMaxRange(segment.presentation)
            guard NSMaxRange(range) > start, range.location < end else { continue }
            guard case let .hidden(value) = segment.kind else { continue }
            lower = min(lower ?? value.location, value.location)
            upper = max(upper ?? NSMaxRange(value), NSMaxRange(value))
        }
        guard let lower, let upper else { return nil }
        return NSRange(location: lower, length: upper - lower)
    }

    /// Presentation range for a source location. Hidden syntax maps to the
    /// presentation offset where it was removed; verbatim text maps to itself
    /// once the table's own offset is applied.
    public func presentationRange(forSource location: Int) -> NSRange? {
        for segment in segments {
            guard case let .hidden(value) = segment.kind else { continue }
            if location >= value.location, location < NSMaxRange(value) { return segment.presentation }
        }
        return nil
    }

    /// Source offset for a presentation offset. Verbatim text maps straight
    /// across; a position where syntax was removed snaps to the nearest source
    /// text so View -> Edit keeps the caret beside the same content.
    public func sourceOffset(forPresentation offset: Int) -> Int? {
        // Hidden syntax and generated separators occupy no presentation
        // length, so they share an offset with real text. Prefer the nearest
        // verbatim segment so the caret lands on actual content.
        var verbatim: Int?
        var fallback: Int?
        for segment in segments {
            let start = segment.presentation.location
            let end = NSMaxRange(segment.presentation)
            guard offset >= start, offset <= end else { continue }
            switch segment.kind {
            case let .verbatim(value):
                // Clamp into the segment so a caret never lands mid-surrogate.
                let span = max(0, min(value.length, offset - start))
                let candidate = value.location + span
                if offset < end { return candidate }
                verbatim = verbatim ?? candidate
            case let .hidden(value):
                fallback = fallback ?? value.location
            case .generated:
                continue
            }
        }
        return verbatim ?? fallback
    }

    /// Source range for a presentation selection, extended to cover any source
    /// syntax hidden inside it so a full-table copy returns exact Markdown.
    public func sourceRange(coveringPresentation range: NSRange) -> NSRange? {
        var lower: Int?
        var upper: Int?
        for segment in segments {
            guard NSMaxRange(range) >= segment.presentation.location,
                  range.location <= NSMaxRange(segment.presentation),
                  case let .verbatim(source) = segment.kind else { continue }
            let value = source.location + max(0, range.location - segment.presentation.location)
            let end = source.location + min(source.length,
                                            max(0, NSMaxRange(range) - segment.presentation.location))
            lower = min(lower ?? value, value)
            upper = max(upper ?? end, end)
        }
        // A selection spanning a whole table should return its exact source,
        // delimiter row and pipes included.
        var tableLower = lower
        var tableUpper = upper
        for segment in segments {
            guard NSMaxRange(range) >= segment.presentation.location,
                  range.location <= NSMaxRange(segment.presentation),
                  case let .hidden(source) = segment.kind else { continue }
            tableLower = min(tableLower ?? source.location, source.location)
            tableUpper = max(tableUpper ?? NSMaxRange(source), NSMaxRange(source))
        }
        guard let low = tableLower ?? lower, let high = tableUpper ?? upper, high > low else { return nil }
        return NSRange(location: low, length: high - low)
    }
}

/// How a table should be laid out at a given available width.
public enum MarkdownTableLayout: Equatable, Sendable {
    /// Columns side by side, separated by tabs. `stops` are cell boundaries in
    /// points; every stop is guaranteed to lie inside `available`.
    case grid(stops: [Double])
    /// Each data row becomes header/value pairs because columns cannot fit.
    case stacked
}

public enum MarkdownTableLayoutPlanner {
    /// Smallest readable column, per the presentation plan.
    public static let minimumColumnWidth: Double = 64
    /// Padding inserted between a column's content and the next boundary.
    public static let columnPadding: Double = 12
    /// Left inset used when a table is rendered as stacked pairs.
    public static let stackedLabelIndent: Double = 12

    /// Decide between grid and stacked rows.
    ///
    /// A grid is used only when every column can hold its widest content, or
    /// when capping every column still fits the available width. Crucially, the
    /// returned stops never exceed `available`, because a tab stop beyond the
    /// viewport is silently unreachable and collapses the column back inline.
    ///
    /// Every column is also floored at its header cell's own width, so a header
    /// never has to wrap to fit. When honouring those floors overflows the
    /// viewport the table stacks instead: a wrapped header loses its column
    /// alignment and reads as broken, while stacked rows stay readable.
    ///
    /// `style` must match the style the presentation will actually project.
    /// Pipe rows are wider than the summed cells alone, because each boundary
    /// costs a literal ` |`; estimating without those glyphs made the planner
    /// approve rows that then overflowed the viewport and wrapped mid-cell.
    public static func layout(for table: MarkdownTable, in source: String,
                              available: Double, advance: Double,
                              style: MarkdownTableRowStyle = .pipes) -> MarkdownTableLayout {
        guard advance > 0, available > 0, table.columnCount > 1 else { return .stacked }
        let text = source as NSString
        var widest: [Double] = Array(repeating: 0, count: table.columnCount)
        // Measure what the presentation emits, not the raw source span: an
        // escaped cell such as `\|` renders one character narrower than it is
        // written, and measuring the source would budget a cell that never
        // reaches the screen.
        for row in table.rows {
            for (column, cell) in row.cells.enumerated() where column < widest.count {
                let cells = MarkdownTablePresentation.emittedCellWidth(cell.content, in: text)
                widest[column] = max(widest[column], Double(cells) * advance)
            }
        }
        // The header sets a per-column floor. Content wider than its header still
        // wraps, but the header itself is the label every column is read by, so
        // it is never the thing that gives way.
        for (column, cell) in table.header.cells.enumerated() where column < widest.count {
            let cells = MarkdownTablePresentation.emittedCellWidth(cell.content, in: text)
            widest[column] = max(widest[column], Double(cells) * advance)
        }
        let minimum = max(minimumColumnWidth, advance * 4)
        let content = widest.map { max($0 + columnPadding, minimum) }
        // Count the glyphs the row style adds on top of its cells: a leading
        // `|` and a ` |` before every column but the first.
        var total = content.reduce(0, +)
        if style == .pipes {
            total += Double(1 + 2 * (table.columnCount - 1)) * advance
        }
        guard total <= available else { return .stacked }
        // Walk the boundaries, never emitting a stop past the right edge.
        var stops: [Double] = []
        var x: Double = 0
        for width in content.dropLast() {
            x += width
            guard x <= available else { return .stacked }
            stops.append(x)
        }
        return .grid(stops: stops)
    }
}

/// How projected rows separate their columns.
public enum MarkdownTableRowStyle: Equatable, Sendable {
    /// Tab-separated cells; the native adapter supplies column geometry.
    case tabs
    /// Cells padded to a shared width and separated by a visible `|`.
    ///
    /// A literal pipe is a real glyph, so it cannot be silently dropped the way
    /// an out-of-viewport tab stop is. It survives wrapping and font fallback,
    /// and it keeps the source's familiar Markdown shape.
    case pipes
}

/// Inline constructs that read as one unit and must never be split by wrapping.
///
/// Text is the only thing allowed to wrap. A code span, a link, a URL, or a bare
/// path broken across two lines stops reading as the thing it is: `` `git diff` ``
/// becomes a dangling backtick and a stray word. These are found in the emitted
/// cell text so the same scan covers a cell written directly in Markdown and one
/// that only became markup after unescaping.
public enum MarkdownTableAtomicElement {
    /// Code spans first: a `|` or a space inside them belongs to the span.
    private static let patterns = [
        ##"`+[^`]*`+"##,                                    // code span
        ##"!?\[[^\]]*\]\([^)\s]*\)"##,                      // link or image
        ##"(?:https?|ftp)://[^\s<>()\[\]]+"##,               // bare URL
        ##"(?:^|(?<=[\s(]))[~]?(?:/|\.{1,2}/)[^\s<>()\[\]]*"##, // path
    ]

    /// UTF-16 ranges in `value` that must stay on one line.
    public static func ranges(in value: String) -> [NSRange] {
        guard !value.isEmpty else { return [] }
        var found: [NSRange] = []
        for pattern in patterns {
            found.append(contentsOf: EditorBehavior.matches(pattern, in: value).map(\.range))
        }
        return found
    }

    /// Replace the breakable spaces inside atomic elements with U+00A0.
    ///
    /// A non-breaking space is one UTF-16 unit, exactly like the space it
    /// replaces, so every offset in the cell — and therefore the whole
    /// source/presentation map — stays valid. Only the presentation is rewritten;
    /// `sourceStorage` keeps the original characters, so saving is byte-exact.
    static func nonBreaking(_ value: String) -> String {
        let protected = ranges(in: value)
        guard !protected.isEmpty, value.contains(" ") else { return value }
        var scalars = Array(value.unicodeScalars)
        // Convert UTF-16 offsets to scalar offsets once, rather than per match.
        var unitToScalar: [Int] = [0]
        for scalar in scalars {
            unitToScalar.append(unitToScalar[unitToScalar.count - 1]
                                + (scalar.isASCII ? 1 : scalar.utf16.count))
        }
        // Walk matches high to low so a match never shifts the offsets of one
        // that has not been handled yet.
        for range in protected.sorted(by: { $0.location > $1.location }) {
            for unit in stride(from: NSMaxRange(range) - 1, through: range.location, by: -1)
            where unit < unitToScalar.count - 1 {
                let scalar = unitToScalar[unit]
                if scalar < scalars.count, scalars[scalar] == " " {
                    scalars[scalar] = "\u{00A0}"
                }
            }
        }
        return String(String.UnicodeScalarView(scalars))
    }

    /// Widest atomic element in `value`, in rendered cells; 0 when it has none.
    static func widestWidth(in value: String) -> Int {
        ranges(in: value).map { MarkdownTableWidth.of(value as NSString, range: $0) }.max() ?? 0
    }
}

/// Renders a table to plain text and records the map back to its source.
/// Layout is deliberately one line per source row: column geometry and cell
/// padding are resolved by the native adapter, not here.
public enum MarkdownTablePresentation {
    public struct Result: Equatable, Sendable {
        public let text: String
        public let map: MarkdownTableMap
        /// Presentation range of each logical row, header included.
        public let rowRanges: [NSRange]
        /// Index of the owning table for each entry in `rowRanges`.
        public var rowOwner: [Int] = []
        /// Left indent in points for each row, from an enclosing quote or list.
        public var rowIndent: [Double] = []
        /// How rows separate their columns. The adapter reads this instead of
        /// searching the text for a pipe: a cell whose content legitimately
        /// contains a literal `|` looks identical to a pipe separator.
        public var rowStyle: MarkdownTableRowStyle = .tabs
    }

    /// Build the presentation for one table. Cell content is copied verbatim so
    /// inline emphasis, code, and link labels keep their source spelling.
    public static func build(_ table: MarkdownTable, in source: String) -> Result {
        let text = source as NSString
        var output = ""
        var segments: [MarkdownTableMapSegment] = []
        var rowRanges: [NSRange] = []
        func append(_ kind: MarkdownTableMapSegment.Kind, _ sourceRange: NSRange?) {
            let length = sourceRange?.length ?? 0
            let presentation = NSRange(location: (output as NSString).length, length: length)
            if case let .verbatim(value) = kind {
                output += text.substring(with: value)
            }
            segments.append(MarkdownTableMapSegment(kind: kind, presentation: presentation, source: sourceRange))
        }
        func appendGenerated(_ value: String) {
            let presentation = NSRange(location: (output as NSString).length, length: (value as NSString).length)
            output += value
            segments.append(MarkdownTableMapSegment(kind: .generated, presentation: presentation, source: nil))
        }
        for (index, row) in table.rows.enumerated() {
            if index > 0 { appendGenerated("\n") }
            let start = (output as NSString).length
            for (column, cell) in row.cells.enumerated() {
                if column > 0 { appendGenerated("\t") }
                if cell.content.length > 0 {
                    append(.verbatim(cell.content), cell.content)
                } else {
                    // Empty cells still occupy a column; record the padding the
                    // source used so a later map can reach the correct cell.
                    append(.hidden(NSRange(location: cell.raw.location, length: 0)), nil)
                }
            }
            rowRanges.append(NSRange(location: start, length: (output as NSString).length - start))
        }
        return Result(text: output, map: MarkdownTableMap(segments: segments,
                                                          presentationLength: (output as NSString).length),
                      rowRanges: rowRanges)
    }

    /// The delimiter row is structural: it is hidden entirely in the presentation.
    public static func hiddenDelimiterRange(_ table: MarkdownTable) -> NSRange { table.delimiter.line }

    /// Whole-document projection where individual tables may use stacked
    /// header/value rows instead of columns. Tables listed in `stacked` render
    /// as pairs; all others render as tab-separated columns.
    public static func project(_ source: String, tables: [MarkdownTable],
                               stacked: Set<Int>,
                               style: MarkdownTableRowStyle = .tabs) -> Result {
        // Forward the caller's style. Falling back to the default here silently
        // switched a pipe-styled document back to tabs, which dropped the very
        // separators that keep columns aligned.
        guard !stacked.isEmpty else { return project(source, tables: tables, style: style) }
        let text = source as NSString
        var output = ""
        var segments: [MarkdownTableMapSegment] = []
        var rowRanges: [NSRange] = []
        var rowOwner: [Int] = []
        var rowIndent: [Double] = []
        var cursor = 0

        func appendVerbatim(_ range: NSRange) {
            guard range.length > 0 else { return }
            let presentation = NSRange(location: (output as NSString).length, length: range.length)
            output += text.substring(with: range)
            segments.append(MarkdownTableMapSegment(kind: .verbatim(range), presentation: presentation,
                                                    source: range))
        }
        func appendCell(_ range: NSRange) {
            if let unescaped = unescapedCell(range, in: text) {
                // Text may wrap; an atomic element inside it may not. The
                // substitution is UTF-16 length preserving, so the presentation
                // range still lines up with the source range it points at.
                let rendered = MarkdownTableAtomicElement.nonBreaking(unescaped)
                let presentation = NSRange(location: (output as NSString).length,
                                            length: (rendered as NSString).length)
                output += rendered
                segments.append(MarkdownTableMapSegment(kind: .verbatim(range),
                                                        presentation: presentation, source: range))
            } else {
                appendCellVerbatim(range)
            }
        }
        /// A cell with no escapes still needs its atomic elements protected, so
        /// it cannot share the plain verbatim path used for surrounding prose.
        func appendCellVerbatim(_ range: NSRange) {
            guard range.length > 0 else { return }
            let value = text.substring(with: range)
            let rendered = MarkdownTableAtomicElement.nonBreaking(value)
            let presentation = NSRange(location: (output as NSString).length,
                                        length: (rendered as NSString).length)
            output += rendered
            segments.append(MarkdownTableMapSegment(kind: .verbatim(range), presentation: presentation,
                                                    source: range))
        }

        func appendHidden(_ range: NSRange) {
            let presentation = NSRange(location: (output as NSString).length, length: 0)
            segments.append(MarkdownTableMapSegment(kind: .hidden(range), presentation: presentation, source: range))
        }
        func appendGenerated(_ value: String) {
            let presentation = NSRange(location: (output as NSString).length, length: (value as NSString).length)
            output += value
            segments.append(MarkdownTableMapSegment(kind: .generated, presentation: presentation, source: nil))
        }

        for (index, table) in tables.enumerated() {
            if table.range.location > cursor {
                appendVerbatim(NSRange(location: cursor, length: table.range.location - cursor))
            }
            let rowStart = rowRanges.count
            // A table with no body rows has nothing to pair up, so the stacked
            // projection emitted no row for it at all and its content vanished
            // from View mode. Such a table renders as a plain row instead.
            if stacked.contains(index), !table.body.isEmpty {
                // Header/value pairs, blank line between data rows.
                for (rowIndex, row) in table.allRows.enumerated() {
                    let container = table.containers[safe: rowIndex]
                    // The row's own newline is hidden source too, but the final
                    // line of a document need not have one: assuming a terminator
                    // ran the hidden range past the end of the source, so copying
                    // the whole table asked for text that was not there.
                    let start = rowIndex == 0 ? table.range.location
                                               : (container?.prefix.location ?? row.line.location)
                    let lineEnd = min(NSMaxRange(text.lineRange(for: NSRange(location: start, length: 0))),
                                      text.length)
                    appendHidden(NSRange(location: start, length: max(0, lineEnd - start)))
                }
                func label(_ column: Int) -> String {
                    guard column < table.header.cells.count,
                          table.header.cells[column].content.length > 0 else { return "Column \(column + 1)" }
                    return text.substring(with: table.header.cells[column].content)
                }
                var first = true
                for row in table.body {
                    if !first { appendGenerated("\n") }
                    first = false
                    for column in 0..<table.columnCount {
                        let start = (output as NSString).length
                        // "Label\nvalue\n" for each pair; the trailing newline
                        // keeps the next label from running into this value.
                        appendGenerated(label(column))
                        appendGenerated("\n")
                        if column < row.cells.count { appendCell(row.cells[column].content) }
                        appendGenerated("\n")
                        rowRanges.append(NSRange(location: start, length: (output as NSString).length - start))
                        rowIndent.append(table.indent)
                    }
                }
            } else {
                appendRows(of: table, in: text,
                           appendVerbatim: appendVerbatim, appendCell: appendCell,
                           appendHidden: appendHidden, appendGenerated: appendGenerated,
                           outputLength: { (output as NSString).length },
                           rowRanges: &rowRanges, rowIndent: &rowIndent,
                           style: style, widths: columnWidths(of: table, in: source))
            }
            for _ in rowStart..<rowRanges.count { rowOwner.append(index) }
            cursor = NSMaxRange(table.range)
        }
        if cursor < text.length {
            appendVerbatim(NSRange(location: cursor, length: text.length - cursor))
        }
        var result = Result(text: output,
                            map: MarkdownTableMap(segments: segments,
                                                  presentationLength: (output as NSString).length),
                            rowRanges: rowRanges)
        result.rowOwner = rowOwner
        result.rowIndent = rowIndent
        result.rowStyle = style
        return result
    }

    /// Cell content is shown unescaped: a literal `\|` reads as a pipe, while the
    /// map still points at the original two source characters.
    ///
    /// Backslash escapes are not processed inside a code span, so `` `a\|b` ``
    /// keeps its backslash. Unescaping there would change the rendered cell and
    /// the cell's measured width, which is how a code cell ends up misaligned.
    static func unescapedCell(_ range: NSRange, in text: NSString) -> String? {
        let value = text.substring(with: range)
        guard value.contains("\\") else { return nil }
        let scalars = Array(value.unicodeScalars)
        // Locate the backtick runs first, so a run is only treated as a code
        // delimiter when an identical run later closes it. An unmatched run is
        // literal text, so escapes beside it are still processed.
        var runs: [(start: Int, length: Int)] = []
        var scan = 0
        while scan < scalars.count {
            guard scalars[scan] == "`" else { scan += 1; continue }
            var length = 0
            while scan + length < scalars.count, scalars[scan + length] == "`" { length += 1 }
            runs.append((scan, length))
            scan += length
        }
        var codeSpans: [Range<Int>] = []
        var open: (start: Int, length: Int)?
        for run in runs {
            guard let pending = open else {
                open = run
                continue
            }
            if pending.length == run.length {
                codeSpans.append(pending.start..<run.start + run.length)
                open = nil
            }
        }
        var out = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            if scalars[index] == "\\", index + 1 < scalars.count,
               !codeSpans.contains(where: { $0.contains(index) }) {
                out.append(scalars[index + 1]); index += 2
                continue
            }
            out.append(scalars[index]); index += 1
        }
        return String(out)
    }

    /// Rendered width of a cell as the presentation actually emits it.
    ///
    /// Width must be measured after unescaping, because `appendCell` writes the
    /// unescaped text. Measuring the source span instead over-counts every
    /// escape by one character: a `\|` cell is two source characters but one
    /// rendered cell, so the column would be padded one cell too wide and that
    /// row's separator would sit past the other rows'.
    static func emittedCellWidth(_ range: NSRange, in text: NSString) -> Int {
        if let unescaped = unescapedCell(range, in: text) {
            return MarkdownTableWidth.of(unescaped)
        }
        return MarkdownTableWidth.of(text, range: range)
    }

    /// Separator emitted before a given column.
    static func separator(for column: Int, widths: [Int],
                         style: MarkdownTableRowStyle) -> String {
        style == .pipes ? " |" : "\t"
    }

    /// Widest cell per column, in rendered cells, for a pipe-separated table.
    public static func columnWidths(of table: MarkdownTable, in source: String) -> [Int] {
        let text = source as NSString
        var widths = [Int](repeating: 0, count: max(1, table.columnCount))
        for row in table.rows {
            for (column, cell) in row.cells.enumerated() where column < widths.count {
                widths[column] = max(widths[column], emittedCellWidth(cell.content, in: text))
            }
        }
        return widths
    }

    /// Project one table's rows as tab-separated cells, appending to the sink
    /// and recording each emitted row's presentation range.
    static func appendRows(of table: MarkdownTable, in text: NSString,
                           appendVerbatim: (NSRange) -> Void,
                           appendCell: (NSRange) -> Void,
                           appendHidden: (NSRange) -> Void,
                           appendGenerated: (String) -> Void,
                           outputLength: () -> Int,
                           rowRanges: inout [NSRange],
                           rowIndent: inout [Double],
                           style: MarkdownTableRowStyle = .tabs,
                           widths: [Int] = []) {
        var offset = table.range.location
        let end = NSMaxRange(table.range)
        var isFirstVisibleRow = true
        var rowIndex = 0
        while offset < end {
            let line = text.lineRange(for: NSRange(location: offset, length: 0))
            let lineEnd = NSMaxRange(line)
            // A block prefix (`> `, a bullet, plain indent) is source syntax the
            // presentation hides; the table's own indent is applied instead.
            let container = table.containers[safe: rowIndex]
            var contentEnd = lineEnd
            while contentEnd > offset {
                let unit = text.character(at: contentEnd - 1)
                guard unit == 10 || unit == 13 else { break }
                contentEnd -= 1
            }
            let content = NSRange(location: offset, length: contentEnd - offset)
            let row = table.allRows[safe: rowIndex]
            // The delimiter row is structural: hide it entirely, newline included.
            if row?.kind == .delimiter {
                if let container, container.prefix.length > 0 {
                    appendHidden(NSRange(location: line.location, length: container.prefix.length))
                }
                appendHidden(NSRange(location: line.location + (container?.prefix.length ?? 0),
                                     length: lineEnd - line.location - (container?.prefix.length ?? 0)))
                offset = lineEnd
                rowIndex += 1
                continue
            }
            if !isFirstVisibleRow { appendGenerated("\n") }
            isFirstVisibleRow = false
            // A leading pipe opens the row so the grid has a left edge.
            if style == .pipes { appendGenerated("|") }
            let rowStart = outputLength()
            // A block prefix (`> `, a bullet, plain indent) is source syntax the
            // presentation hides; the table's own indent is applied instead.
            //
            // It is recorded here, after the row's opening pipe, so the hidden
            // span shares the row's presentation offset. Hiding it first put it
            // one position ahead of the row range, and a copy covering the whole
            // table started after it: the first line lost its `> ` or bullet and
            // pasted as broken Markdown.
            if let container, container.prefix.length > 0 {
                appendHidden(NSRange(location: line.location, length: container.prefix.length))
            }
            if let row {
                for (column, cell) in row.cells.enumerated() {
                    if column > 0 {
                        // Hide the pipe and surrounding spaces, then present a
                        // real tab so columns stay separated without syntax.
                        var hideStart = cell.raw.location
                        while hideStart > content.location, text.character(at: hideStart - 1) == 32 {
                            hideStart -= 1
                        }
                        appendHidden(NSRange(location: hideStart, length: cell.raw.location - hideStart))
                        appendGenerated(separator(for: column, widths: widths, style: style))
                    } else if cell.content.location > row.line.location {
                        // Hide indentation and the leading pipe.
                        appendHidden(NSRange(location: row.line.location,
                                             length: cell.content.location - row.line.location))
                    }
                    appendCell(cell.content)
                    // In pipe mode each cell is padded so the following separator
                    // lands in the same column on every row. Measure the emitted
                    // text, not the source span, or an escaped cell such as `\|`
                    // is padded one cell short and its separator drifts right.
                    if style == .pipes, column < widths.count {
                        let used = emittedCellWidth(cell.content, in: text)
                        if used < widths[column] {
                            appendGenerated(String(repeating: " ", count: widths[column] - used))
                        }
                    }
                }
                // Hide trailing spaces and any closing pipe.
                let afterLast = NSMaxRange(row.cells[row.cells.count - 1].raw)
                if afterLast < contentEnd {
                    appendHidden(NSRange(location: afterLast, length: contentEnd - afterLast))
                }
                // The row's own newline is source with no presentation text.
                // Recording it keeps a full-table copy byte-exact.
                if lineEnd > contentEnd {
                    appendHidden(NSRange(location: contentEnd, length: lineEnd - contentEnd))
                }
            } else {
                appendVerbatim(content)
            }
            rowRanges.append(NSRange(location: rowStart, length: outputLength() - rowStart))
            // Continuation lines report no bullet of their own, so fall back to
            // the table's container indent to keep every row aligned.
            rowIndent.append(max(container?.indent ?? 0, table.indent))
            offset = lineEnd
            rowIndex += 1
        }
    }

    /// Whole-document projection: every recognized table becomes pipe-free
    /// tab-separated cell text, and all surrounding text is copied verbatim.
    /// This is the View-mode buffer; `MarkdownDocument.sourceStorage` remains
    /// authoritative for Save, recovery, dirty state, word count, and undo.
    public static func project(_ source: String,
                               tables: [MarkdownTable]? = nil,
                               style: MarkdownTableRowStyle = .tabs) -> Result {
        let text = source as NSString
        let resolved = tables ?? MarkdownTables.parse(source)
        var output = ""
        var segments: [MarkdownTableMapSegment] = []
        var rowRanges: [NSRange] = []
        var rowOwner: [Int] = []   // presentation row index -> table index
        var rowIndent: [Double] = []
        var cursor = 0

        func appendVerbatim(_ range: NSRange) {
            guard range.length > 0 else { return }
            let presentation = NSRange(location: (output as NSString).length, length: range.length)
            output += text.substring(with: range)
            segments.append(MarkdownTableMapSegment(kind: .verbatim(range), presentation: presentation,
                                                    source: range))
        }
        func appendCell(_ range: NSRange) {
            if let unescaped = unescapedCell(range, in: text) {
                // Text may wrap; an atomic element inside it may not. The
                // substitution is UTF-16 length preserving, so the presentation
                // range still lines up with the source range it points at.
                let rendered = MarkdownTableAtomicElement.nonBreaking(unescaped)
                let presentation = NSRange(location: (output as NSString).length,
                                            length: (rendered as NSString).length)
                output += rendered
                segments.append(MarkdownTableMapSegment(kind: .verbatim(range),
                                                        presentation: presentation, source: range))
            } else {
                appendCellVerbatim(range)
            }
        }
        /// A cell with no escapes still needs its atomic elements protected, so
        /// it cannot share the plain verbatim path used for surrounding prose.
        func appendCellVerbatim(_ range: NSRange) {
            guard range.length > 0 else { return }
            let value = text.substring(with: range)
            let rendered = MarkdownTableAtomicElement.nonBreaking(value)
            let presentation = NSRange(location: (output as NSString).length,
                                        length: (rendered as NSString).length)
            output += rendered
            segments.append(MarkdownTableMapSegment(kind: .verbatim(range), presentation: presentation,
                                                    source: range))
        }

        func appendHidden(_ range: NSRange) {
            let presentation = NSRange(location: (output as NSString).length, length: 0)
            segments.append(MarkdownTableMapSegment(kind: .hidden(range), presentation: presentation, source: range))
        }
        func appendGenerated(_ value: String) {
            let presentation = NSRange(location: (output as NSString).length, length: (value as NSString).length)
            output += value
            segments.append(MarkdownTableMapSegment(kind: .generated, presentation: presentation, source: nil))
        }

        for (index, table) in resolved.enumerated() {
            // Copy untouched source up to this table.
            if table.range.location > cursor {
                appendVerbatim(NSRange(location: cursor, length: table.range.location - cursor))
            }
            let rowStart = rowRanges.count
            appendRows(of: table, in: text,
                       appendVerbatim: appendVerbatim, appendCell: appendCell,
                       appendHidden: appendHidden, appendGenerated: appendGenerated,
                       outputLength: { (output as NSString).length },
                       rowRanges: &rowRanges, rowIndent: &rowIndent,
                       style: style, widths: columnWidths(of: table, in: source))
            for _ in rowStart..<rowRanges.count { rowOwner.append(index) }
            cursor = NSMaxRange(table.range)
        }
        if cursor < text.length {
            appendVerbatim(NSRange(location: cursor, length: text.length - cursor))
        }
        var result = Result(text: output,
                            map: MarkdownTableMap(segments: segments,
                                                  presentationLength: (output as NSString).length),
                            rowRanges: rowRanges)
        result.rowOwner = rowOwner
        result.rowIndent = rowIndent
        result.rowStyle = style
        return result
    }

    /// Tab-separated values for spreadsheet paste, quoting tabs, newlines and
    /// quotes inside cell content.
    public static func tsv(_ table: MarkdownTable, in source: String) -> String {
        let text = source as NSString
        return table.rows.map { row in
            row.cells.map { cell -> String in
                quote(text.substring(with: cell.content))
            }.joined(separator: "\t")
        }.joined(separator: "\n")
    }

    private static func quote(_ value: String) -> String {
        guard value.contains(where: { $0 == "\t" || $0 == "\n" || $0 == "\r" || $0 == "\"" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

extension Array {
    /// Bounds-checked lookup, used where row and container arrays can differ in
    /// length for malformed tables.
    public subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
