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
    public static func layout(for table: MarkdownTable, in source: String,
                              available: Double, advance: Double) -> MarkdownTableLayout {
        guard advance > 0, available > 0, table.columnCount > 1 else { return .stacked }
        let text = source as NSString
        var widest: [Double] = Array(repeating: 0, count: table.columnCount)
        for row in table.rows {
            for (column, cell) in row.cells.enumerated() where column < widest.count {
                let cells = MarkdownTableWidth.of(text, range: cell.content)
                widest[column] = max(widest[column], Double(cells) * advance)
            }
        }
        let minimum = max(minimumColumnWidth, advance * 4)
        let content = widest.map { max($0 + columnPadding, minimum) }
        let total = content.reduce(0, +)
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
        guard !stacked.isEmpty else { return project(source, tables: tables) }
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
                let presentation = NSRange(location: (output as NSString).length,
                                            length: (unescaped as NSString).length)
                output += unescaped
                segments.append(MarkdownTableMapSegment(kind: .verbatim(range),
                                                        presentation: presentation, source: range))
            } else {
                appendVerbatim(range)
            }
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
            if stacked.contains(index) {
                // Header/value pairs, blank line between data rows.
                for (rowIndex, row) in table.allRows.enumerated() {
                    let container = table.containers[safe: rowIndex]
                    appendHidden(NSRange(location: rowIndex == 0 ? table.range.location
                                                                   : (container?.prefix.location ?? row.line.location),
                                         length: (container?.prefix.length ?? 0)
                                         + row.line.length + 1))
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
        return result
    }

    /// Cell content is shown unescaped: a literal `\|` reads as a pipe, while the
    /// map still points at the original two source characters.
    static func unescapedCell(_ range: NSRange, in text: NSString) -> String? {
        let value = text.substring(with: range)
        guard value.contains("\\") else { return nil }
        let scalars = Array(value.unicodeScalars)
        var out = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            if scalars[index] == "\\", index + 1 < scalars.count {
                out.append(scalars[index + 1]); index += 2
            } else {
                out.append(scalars[index]); index += 1
            }
        }
        return String(out)
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
                widths[column] = max(widths[column], MarkdownTableWidth.of(text, range: cell.content))
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
            if let container, container.prefix.length > 0 {
                appendHidden(NSRange(location: line.location, length: container.prefix.length))
            }
            // The delimiter row is structural: hide it entirely, newline included.
            if row?.kind == .delimiter {
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
                    // lands in the same column on every row.
                    if style == .pipes, column < widths.count {
                        let used = MarkdownTableWidth.of(text, range: cell.content)
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
                let presentation = NSRange(location: (output as NSString).length,
                                            length: (unescaped as NSString).length)
                output += unescaped
                segments.append(MarkdownTableMapSegment(kind: .verbatim(range),
                                                        presentation: presentation, source: range))
            } else {
                appendVerbatim(range)
            }
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
