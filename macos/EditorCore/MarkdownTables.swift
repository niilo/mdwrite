import Foundation

/// Column alignment declared by a table's delimiter row.
public enum MarkdownTableAlignment: Equatable, Sendable {
    case none, left, center, right
}

/// One pipe-delimited cell. `raw` keeps original interior spacing so alignment
/// can be rewritten without touching cell content; `content` is the trimmed value.
public struct MarkdownTableCell: Equatable, Sendable {
    public let raw: NSRange
    public let content: NSRange

    public init(raw: NSRange, content: NSRange) {
        self.raw = raw
        self.content = content
    }

    public var isEmpty: Bool { content.length == 0 }
}

public struct MarkdownTableRow: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case header, delimiter, body }

    public let kind: Kind
    /// The physical line, excluding its newline terminator.
    public let line: NSRange
    public let cells: [MarkdownTableCell]

    public var columnCount: Int { cells.count }
}

/// Leading blockquote markers and list indentation in front of a table row.
    /// GFM allows up to three spaces of indent and tables inside quotes/lists.
    public struct MarkdownTableContainer: Equatable, Sendable {
        /// Source range of the prefix, hidden in the presentation.
        public let prefix: NSRange
        /// Quote depth and list depth, used for indentation.
        public let quoteDepth: Int
        public let listDepth: Int

        public var indent: Double { Double(quoteDepth) * 24 + Double(listDepth) * 20 }
    }

public struct MarkdownTable: Equatable, Sendable {
    /// Header line start through the last row's end; never includes trailing newline.
    public let range: NSRange
    public let header: MarkdownTableRow
    public let delimiter: MarkdownTableRow
    public let body: [MarkdownTableRow]
    public let alignments: [MarkdownTableAlignment]
    /// Block prefix for each row in `allRows` order, for hidden range tracking
    /// and for indenting the presentation inside quotes and lists.
    public let containers: [MarkdownTableContainer]

    public init(range: NSRange, header: MarkdownTableRow, delimiter: MarkdownTableRow,
                body: [MarkdownTableRow], alignments: [MarkdownTableAlignment],
                containers: [MarkdownTableContainer] = []) {
        self.range = range
        self.header = header
        self.delimiter = delimiter
        self.body = body
        self.alignments = alignments
        self.containers = containers
    }

    /// Left indentation the presentation should apply, from the enclosing quote
    /// or list. Zero for a top-level table.
    public var indent: Double { containers.first?.indent ?? 0 }

    public var columnCount: Int { alignments.count }
    /// Header plus body, in document order. The delimiter row is structural only.
    public var rows: [MarkdownTableRow] { [header] + body }
    /// Header, delimiter, and body, for source-exact operations.
    public var allRows: [MarkdownTableRow] { [header, delimiter] + body }
}
/// GFM table discovery over the unmodified source. Ranges address UTF-16 units
/// so they can be applied directly to `MarkdownDocument.sourceStorage`.
public enum MarkdownTables {
    /// Recognize every table in `source`, skipping fenced code contents.
    /// Pipe splitting happens before inline parsing, so a cell escapes a literal
    /// pipe with `\|`; per GFM, backtick spans do not protect a pipe here.
    public static func parse(_ source: String) -> [MarkdownTable] {
        let text = source as NSString
        guard text.length > 0 else { return [] }
        let excluded = MarkdownBlocks.parse(source)
            .filter { $0.kind == .fencedCode }.map(\.range)
        func isCode(_ offset: Int) -> Bool {
            excluded.contains { NSLocationInRange(offset, $0) }
        }
        let lines = contentLines(of: text)
        var tables: [MarkdownTable] = []
        var index = 0
        while index + 1 < lines.count {
            let headerLine = lines[index]
            let delimiterLine = lines[index + 1]
            guard !isCode(headerLine.location), !isCode(delimiterLine.location) else {
                index += 1
                continue
            }
            // Rows must share one container prefix; a mismatched marker means the
            // block ended and this is not a table.
            // Rows of a quoted, bulleted, or plainly indented table all carry a
            // prefix their continuation lines repeat, so strip those too.
            // A header is "indented" when its rows carry a prefix at all: plain
            // spaces, a quote marker, or a list bullet.
            let headerHasPrefix = MarkdownTables.indentation(of: headerLine, in: text) > 0
                || { let probe = containerPrefix(of: headerLine, in: text); return probe.prefix.length > 0 }()
            let headerWasIndented = headerHasPrefix
            let headerContainer = containerPrefix(of: headerLine, in: text,
                                                  headerWasIndented: headerWasIndented)
            let delimiterContainer = containerPrefix(of: delimiterLine, in: text,
                                                      headerWasIndented: headerWasIndented)
            let headerContent = offsetting(headerLine, by: headerContainer.prefix.length)
            let delimiterContent = offsetting(delimiterLine, by: delimiterContainer.prefix.length)
            // The delimiter may be bulleted like the header or, on a
            // continuation line, merely indented.
            let delimiterMatches = delimiterContainer.quoteDepth == headerContainer.quoteDepth
                && (delimiterContainer.listDepth == headerContainer.listDepth
                    || (headerContainer.listDepth > 0 && delimiterContainer.prefix.length > 0))
            guard headerContainer.quoteDepth == delimiterContainer.quoteDepth,
                  delimiterMatches,
                  let headerCells = cells(in: text, line: headerContent),
                  let delimiterCells = cells(in: text, line: delimiterContent),
                  let alignments = alignments(from: text, delimiterCells),
                  !alignments.isEmpty, alignments.count == headerCells.count else {
                index += 1
                continue
            }
            var body: [MarkdownTableRow] = []
            var containers = [headerContainer, delimiterContainer]
            var cursor = index + 2
            while cursor < lines.count {
                let line = lines[cursor]
                guard !isCode(line.location) else { break }
                let container = containerPrefix(of: line, in: text,
                                              headerWasIndented: headerWasIndented)
                let content = offsetting(line, by: container.prefix.length)
                // Continuation lines of a list item are indented rather than
                // bulleted, so compare indentation, not just the bullet flag.
                let sameContainer = container.quoteDepth == headerContainer.quoteDepth
                    && (container.listDepth == headerContainer.listDepth
                        || (headerContainer.listDepth > 0 && container.prefix.length > 0))
                guard sameContainer, let rowCells = cells(in: text, line: content) else { break }
                body.append(MarkdownTableRow(kind: .body, line: content, cells: rowCells))
                containers.append(container)
                cursor += 1
            }
            let last = body.last?.line ?? delimiterContent
            tables.append(MarkdownTable(range: NSRange(location: headerLine.location,
                                                       length: NSMaxRange(last) - headerLine.location),
                                       header: MarkdownTableRow(kind: .header, line: headerContent, cells: headerCells),
                                       delimiter: MarkdownTableRow(kind: .delimiter, line: delimiterContent, cells: delimiterCells),
                                       body: body, alignments: alignments,
                                       containers: containers))
            index = cursor
        }
        return tables
    }

        /// Detect the block prefix on a line, returning the range of the remainder.
    ///
    /// Without this a table inside a blockquote or list item is not recognized,
    /// because every cell offset would be shifted by the marker.
    static func containerPrefix(of line: NSRange, in text: NSString,
                                headerWasIndented: Bool = false) -> MarkdownTableContainer {
        var index = line.location
        let end = NSMaxRange(line)
        var quoteDepth = 0
        var listDepth = 0
        // Blockquote markers, allowing a space after each.
        scan: while index < end {
            var cursor = index
            var spaces = 0
            while cursor < end, spaces < 3, text.character(at: cursor) == 32 {
                cursor += 1; spaces += 1
            }
            guard cursor < end, text.character(at: cursor) == 62 else { break scan }
            cursor += 1
            if cursor < end, text.character(at: cursor) == 32 { cursor += 1 }
            index = cursor
            quoteDepth += 1
        }
        // A list bullet with its content. The bullet only appears on the first
        // line of an item; continuation lines are indented instead.
        if index < end, [45, 43, 42].contains(text.character(at: index)),
           index + 1 < end, text.character(at: index + 1) == 32 {
            index += 2
            listDepth = 1
            // Task checkbox `[ ]` / `[x]`, optionally followed by a space.
            // After the bullet, index points at '[', so the mark is index+1.
            if index + 2 < end, text.character(at: index) == 91,
               [120, 32].contains(text.character(at: index + 1)),
               text.character(at: index + 2) == 93 {
                index += 3
                if index < end, text.character(at: index) == 32 { index += 1 }
            }
        } else {
            // Continuation lines are indented by the bullet width or by spaces
            // alone, within GFM's three-space allowance. Only strip when the row
            // still begins a cell after the indent; `" | x"` is a two-cell row
            // whose first cell is empty, not an indented one-cell row.
            // Continuation lines of an indented block repeat the block's indentation.
            // `" | x"` is different: its leading space precedes a delimiter, so
            // the row genuinely has an empty first cell. Only strip when the
            // table's own header is indented, so the rows still line up.
            if headerWasIndented {
                var cursor = index
                var spaces = 0
                while cursor < end, spaces < 3, text.character(at: cursor) == 32 {
                    cursor += 1; spaces += 1
                }
                if spaces > 0 { index = cursor }
            }
        }
        return MarkdownTableContainer(prefix: NSRange(location: line.location, length: index - line.location),
                                       quoteDepth: quoteDepth, listDepth: listDepth)
    }

    /// The table containing `offset`, if any.
    public static func table(containing offset: Int, in tables: [MarkdownTable]) -> MarkdownTable? {
        tables.first { NSLocationInRange(offset, $0.range) }
    }

    /// Count leading spaces on a line, used to detect an indented table.
    static func indentation(of line: NSRange, in text: NSString) -> Int {
        var spaces = 0
        var index = line.location
        let end = NSMaxRange(line)
        while index < end, spaces < 3, text.character(at: index) == 32 {
            spaces += 1; index += 1
        }
        return spaces
    }

    /// Narrow a line range to skip a leading block prefix.
    static func offsetting(_ line: NSRange, by amount: Int) -> NSRange {
        guard amount > 0 else { return line }
        return NSRange(location: line.location + amount, length: max(0, line.length - amount))
    }

    /// Physical line ranges excluding their newline terminator.
    static func contentLines(of text: NSString) -> [NSRange] {
        var lines: [NSRange] = []
        var offset = 0
        let length = text.length
        while offset <= length {
            let line = text.lineRange(for: NSRange(location: offset, length: 0))
            var content = line
            while content.length > 0 {
                let last = text.character(at: NSMaxRange(content) - 1)
                if last == 10 || last == 13 { content.length -= 1 } else { break }
            }
            lines.append(content)
            let end = NSMaxRange(line)
            if end >= length { break }
            offset = end
        }
        return lines
    }

    static func containsUnescapedPipe(_ text: NSString, _ line: NSRange) -> Bool {
        var index = line.location
        let end = NSMaxRange(line)
        while index < end {
            let character = text.character(at: index)
            if character == 92 { index += 2; continue }
            if character == 124 { return true }
            index += 1
        }
        return false
    }

    /// Split one line into cells on unescaped pipes, honoring optional outer
    /// pipes. Returns nil when the line has no pipe at all.
    static func cells(in text: NSString, line: NSRange) -> [MarkdownTableCell]? {
        guard containsUnescapedPipe(text, line) else { return nil }
        var pipes: [Int] = []
        var index = line.location
        let end = NSMaxRange(line)
        while index < end {
            let character = text.character(at: index)
            if character == 92 { index += 2; continue }
            if character == 124 { pipes.append(index) }
            index += 1
        }
        // A pipe at either end is a delimiter, not a cell boundary: "| a |" has
        // one cell, while " | x" has an empty first cell and one value.
        let leading = pipes.first == line.location
        let trailing = pipes.last == end - 1
        // Cells are the gaps between delimiters. A missing leading or trailing
        // delimiter contributes an empty edge cell instead of dropping one.
        var bounds: [(lower: Int, upper: Int)] = []
        if !leading { bounds.append((line.location, pipes[0])) }
        for index in 0..<(pipes.count - 1) {
            bounds.append((pipes[index] + 1, pipes[index + 1]))
        }
        if !trailing { bounds.append((pipes[pipes.count - 1] + 1, end)) }
        guard !bounds.isEmpty else { return nil }
        return bounds.map { raw -> MarkdownTableCell in
            let range = NSRange(location: raw.lower, length: max(0, raw.upper - raw.lower))
            return MarkdownTableCell(raw: range, content: trimming(text, range))
        }
    }

    /// Parse the delimiter row, or nil when any cell is not `:?-+:?`.
    static func alignments(from text: NSString, _ cells: [MarkdownTableCell]) -> [MarkdownTableAlignment]? {
        var result: [MarkdownTableAlignment] = []
        result.reserveCapacity(cells.count)
        for cell in cells {
            let value = text.substring(with: cell.content)
            let left = value.hasPrefix(":")
            let right = value.hasSuffix(":") && value != ":"
            let body = String(value.drop(while: { $0 == ":" }).reversed().drop(while: { $0 == ":" }))
            guard !body.isEmpty, body.allSatisfy({ $0 == "-" }) else { return nil }
            switch (left, right) {
            case (true, true): result.append(.center)
            case (true, false): result.append(.left)
            case (false, true): result.append(.right)
            case (false, false): result.append(.none)
            }
        }
        return result
    }

    /// Trim ASCII spaces and tabs from both ends.
    static func trimming(_ text: NSString, _ range: NSRange) -> NSRange {
        guard range.length > 0 else { return range }
        let space: Set<unichar> = [32, 9]
        var lower = range.location
        var upper = NSMaxRange(range)
        while lower < upper, space.contains(text.character(at: lower)) { lower += 1 }
        while upper > lower, space.contains(text.character(at: upper - 1)) { upper -= 1 }
        return NSRange(location: lower, length: upper - lower)
    }
}
/// Columns are padded by *rendered* width, not UTF-16 length. The editor uses a
/// monospaced face, so a CJK ideograph or emoji occupies more cells than an
/// ASCII letter while a combining mark occupies none.
///
/// A static table cannot be exact: `iAWriterMonoS` has no CJK glyphs, so those
/// characters fall back to another face whose advance is fractional (measured
/// 3.33 cells for two ideographs, 1.92 for one emoji). The native layer
/// therefore installs a font-metric measurer; the table below is the fallback
/// used by pure-core callers and tests.
public enum MarkdownTableWidth {
    /// Measures one string's rendered width in monospaced cells.
    public typealias Measurer = @Sendable (String) -> Int

    private struct State: Sendable {
        var measurer: Measurer?
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var state = State()

    /// Install a font-metric measurer. Passing nil restores the static table.
    public static func useFontMetrics(_ measurer: Measurer?) {
        lock.lock()
        defer { lock.unlock() }
        state.measurer = measurer
    }

    /// Rendered column width of `text` in monospaced cells.
    public static func of(_ text: String) -> Int {
        lock.lock()
        let measurer = state.measurer
        lock.unlock()
        if let measurer { return measurer(text) }
        var total = 0
        for scalar in text.unicodeScalars { total += staticWidth(of: scalar) }
        return total
    }

    /// Rendered column width of a source range, without copying the substring.
    public static func of(_ text: NSString, range: NSRange) -> Int {
        guard range.length > 0 else { return 0 }
        lock.lock()
        let measurer = state.measurer
        lock.unlock()
        if let measurer { return measurer(text.substring(with: range)) }
        var total = 0
        var index = range.location
        let end = NSMaxRange(range)
        while index < end {
            let unit = text.character(at: index)
            if unit >= 0xD800, unit <= 0xDBFF, index + 1 < end {
                // A surrogate pair encodes one astral scalar; never split it.
                let low = text.character(at: index + 1)
                if low >= 0xDC00, low <= 0xDFFF {
                    let value = 0x10000 + (UInt32(unit - 0xD800) << 10) + UInt32(low - 0xDC00)
                    if let scalar = Unicode.Scalar(value) { total += staticWidth(of: scalar) }
                    index += 2
                    continue
                }
            }
            // A lone surrogate cannot form a scalar; count it as one visible cell.
            if let scalar = Unicode.Scalar(UInt32(unit)) { total += staticWidth(of: scalar) } else { total += 1 }
            index += 1
        }
        return total
    }

    /// Fallback width used when no font metrics are installed.
    public static func staticWidth(of scalar: Unicode.Scalar) -> Int {
        // Zero-width: combining marks, variation selectors, ZWJ, and friends.
        if isZeroWidth(scalar) { return 0 }
        return isWide(scalar) ? 2 : 1
    }

    /// Mn, Me, Cf and the zero-width formatting ranges that never advance a cell.
    private static func isZeroWidth(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x200B...0x200F, 0x2060...0x2064, 0xFE00...0xFE0F, 0xFEFF,
             0xE0100...0xE01EF:
            return true
        default:
            break
        }
        // General categories Mn (nonspacing mark) and Me (enclosing mark).
        let category = scalar.properties.generalCategory
        return category == .nonspacingMark || category == .enclosingMark
    }

    /// East Asian Wide and Fullwidth, plus the emoji blocks a monospaced editor
    /// renders double-width.
    private static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x115F,  // Hangul Jamo
             0x2E80...0x303E,  // CJK radicals, Kangxi, punctuation
             0x3041...0x33FF,  // Hiragana through CJK compatibility
             0x3400...0x4DBF,  // CJK extension A
             0x4E00...0x9FFF,  // CJK unified ideographs
             0xA000...0xA4CF,  // Yi
             0xAC00...0xD7A3,  // Hangul syllables
             0xF900...0xFAFF,  // CJK compatibility ideographs
             0xFE30...0xFE6F,  // CJK compatibility forms
             0xFF00...0xFF60,  // Fullwidth forms
             0xFFE0...0xFFE6,
             0x1F300...0x1F64F,  // Emoji: symbols and pictographs, emoticons
             0x1F680...0x1F6FF,  // Transport and map
             0x1F900...0x1F9FF,  // Supplemental symbols
             0x1FA70...0x1FAFF,  // Extended-A
             0x20000...0x3FFFD:   // CJK extensions B and beyond
            return true
        default:
            return false
        }
    }
}

/// Explicit "Align Table Source": pads each cell with spaces so the pipes line
/// up in the monospaced Edit-mode view. Cell content, alignment markers, and the
/// table's newline convention are preserved, and the result is one SourceEdit
/// so undo restores the original spacing in a single step.
public enum MarkdownTableAlignmentEdit {
    /// Returns nil when `offset` is not inside a valid table, or when the table's
    /// source is already aligned. Pass `tables` to avoid reparsing the document.
    public static func editAligningTable(at offset: Int, in source: String,
                                         tables: [MarkdownTable]? = nil) throws -> SourceEdit? {
        let text = source as NSString
        guard let table = MarkdownTables.table(containing: offset,
                                               in: tables ?? MarkdownTables.parse(source)) else { return nil }
        return try editAligning(table, in: text, caret: offset)
    }

    /// Pad each cell with trailing spaces so the pipes line up. Outer pipes,
    /// cell content, alignment markers, and the table's newline convention are
    /// preserved; the delimiter row is padded to width without losing markers.
    static func editAligning(_ table: MarkdownTable, in text: NSString, caret: Int) throws -> SourceEdit? {
        // Detect the newline convention from the separator between two rows; the
        // final row has no trailing newline inside the table range.
        let firstBreak = NSMaxRange(table.header.line)
        let newline = firstBreak < text.length && text.character(at: firstBreak) == 13 ? "\r\n" : "\n"
        // Trailing spaces never help a monospaced column, so the target width is
        // driven by the visible content, not by the delimiter row's dashes.
        // Width is measured in rendered cells, so CJK and emoji pad correctly.
        let rows = table.rows
        var widths = [Int](repeating: 0, count: table.columnCount)
        for row in rows {
            for (column, cell) in row.cells.enumerated() where column < widths.count {
                widths[column] = max(widths[column], MarkdownTableWidth.of(text, range: cell.content))
            }
        }
        var lines: [(range: NSRange, text: String)] = []
        for row in table.allRows {
            lines.append((row.line, aligned(row, widths: widths, delimiter: row.kind == .delimiter, text: text)))
        }
        guard lines.contains(where: { $0.text != text.substring(with: $0.range) }) else { return nil }
        var replacement = ""
        for (index, line) in lines.enumerated() {
            replacement += line.text
            if index < lines.count - 1 { replacement += newline }
        }
        // Keep the caret on the same cell it occupied before padding.
        let caretRow = rows.firstIndex { NSLocationInRange(caret, $0.line) } ?? 0
        let caretColumn = caret - rows[caretRow].line.location
        let selection = NSRange(location: table.range.location + min(caretColumn, max(0, (lines[caretRow].text as NSString).length)),
                                 length: 0)
        let edit = SourceEdit(range: table.range, replacement: replacement, selection: selection)
        try edit.validate(in: text)
        return edit
    }

    /// Rebuild one row at the shared column widths, keeping its outer-pipe style.
    private static func aligned(_ row: MarkdownTableRow, widths: [Int],
                                delimiter: Bool, text: NSString) -> String {
        let trimmed = MarkdownTables.trimming(text, row.line)
        let leading = trimmed.length > 0 && text.character(at: trimmed.location) == 124
        let trailing = trimmed.length > 0 && text.character(at: NSMaxRange(trimmed) - 1) == 124
        var line = leading ? "| " : ""
        for (column, cell) in row.cells.enumerated() {
            if column > 0 { line += " | " }
            var value = text.substring(with: cell.content)
            let target = column < widths.count ? widths[column] : 0
            if delimiter {
                // Keep the markers and widen the dashes to the column width so
                // the delimiter row's pipes line up with the data rows.
                let left = value.hasPrefix(":")
                let right = value.hasSuffix(":") && value != ":"
                let dashes = value.count - (left ? 1 : 0) - (right ? 1 : 0)
                value = (left ? ":" : "") + String(repeating: "-", count: max(dashes, target))
                    + (right ? ":" : "")
            } else {
                // Pad by rendered width, so a wide cell is not padded as if narrow.
                let used = MarkdownTableWidth.of(value)
                if used < target { value += String(repeating: " ", count: target - used) }
            }
            line += value
        }
        line += trailing ? " |" : ""
        return line
    }
}
