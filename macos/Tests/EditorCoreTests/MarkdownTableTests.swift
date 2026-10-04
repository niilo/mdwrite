import Foundation
import Testing
@testable import EditorCore

/// GFM table fixture shared by the projection tests. Every table in it must
/// project to rows of identical rendered width, which is what keeps the pipe
/// separators in one column.
private let tableFixture = try! String(
    contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("tests/fixtures/tables.md"),
    encoding: .utf8)

@Test func tableFixtureParsesEveryTable() {
    let tables = MarkdownTables.parse(tableFixture)
    #expect(tables.count == 7)
    #expect(tables.map(\.columnCount) == [3, 3, 2, 2, 2, 3, 2])
    #expect(tables[0].alignments == [.none, .center, .right])
    #expect(tables[5].alignments == [.left, .center, .right])
}

@Test func projectedTableRowsAllRenderAtTheSameWidth() throws {
    let tables = MarkdownTables.parse(tableFixture)
    let projection = MarkdownTablePresentation.project(tableFixture, tables: tables,
                                                       style: .pipes)
    let text = projection.text as NSString
    for table in tables.indices {
        let rows = projection.rowRanges.indices.filter { projection.rowOwner[$0] == table }
        #expect(!rows.isEmpty)
        let widths = rows.map { MarkdownTableWidth.of(text, range: projection.rowRanges[$0]) }
        // An escaped cell such as `\|` emits one character less than its source
        // span, so padding measured from the source pushed that row's separator
        // out of line with every other row.
        #expect(Set(widths).count == 1, "table \(table) rows render at widths \(widths)")
    }
}

@Test func escapedCellKeepsItsColumnSeparatorAligned() throws {
    // Regression: `\|` is two source characters but renders as one, so the
    // column had to be measured from the emitted text rather than the source.
    let source = "| A | B |\n| --- | --- |\n| x | y |\n| z | \\| |"
    let projection = MarkdownTablePresentation.project(source, style: .pipes)
    let rows = projection.rowRanges
    #expect(rows.count == 3)
    let rendered = rows.map { (projection.text as NSString).substring(with: $0) }
    // The escaped cell renders as a single pipe, so this row keeps the same
    // width as the rows above it instead of gaining a cell.
    #expect(rendered == ["A |B", "x |y", "z ||"])
    let widths = rows.map { MarkdownTableWidth.of(projection.text as NSString, range: $0) }
    #expect(Set(widths).count == 1, "\(rendered)")
}

/// A copy of projected rows must address real source. Both the grid and the
/// stacked projection hid a row's terminator by assuming every line had one;
/// the last line of the fixture has no trailing newline, so the range ran past
/// the end of the source and the copy asked for text that was not there.
private func wholeTableCopy(_ projection: MarkdownTablePresentation.Result,
                            _ table: Int, in source: String) -> String? {
    let rows = projection.rowRanges.indices.filter { projection.rowOwner[$0] == table }
    guard let first = rows.first, let last = rows.last else { return nil }
    let range = NSRange(location: projection.rowRanges[first].location,
                        length: NSMaxRange(projection.rowRanges[last]) - projection.rowRanges[first].location)
    guard let copied = projection.map.sourceRange(coveringPresentation: range) else { return nil }
    guard copied.location >= 0, NSMaxRange(copied) <= (source as NSString).length else { return nil }
    return (source as NSString).substring(with: copied)
}

@Test func everyFixtureTableCopiesBackInsideTheSourceFromEitherLayout() throws {
    let text = tableFixture as NSString
    let tables = MarkdownTables.parse(tableFixture)
    for (index, table) in tables.enumerated() {
        let expected = text.substring(with: table.range)
        for (style, projection) in [
            (MarkdownTableRowStyle.pipes,
             MarkdownTablePresentation.project(tableFixture, tables: tables, style: .pipes)),
            (.tabs, MarkdownTablePresentation.project(tableFixture, tables: tables, style: .tabs)),
            (.pipes, MarkdownTablePresentation.project(tableFixture, tables: tables,
                                                      stacked: [index], style: .pipes))
        ] {
            let copied = try #require(wholeTableCopy(projection, index, in: tableFixture),
                                      "table \(index) \(style) did not map a whole-table copy to source")
            // The terminator of the table's last line joins the copy when the
            // source has one, so it may carry exactly that trailing newline.
            #expect(copied == expected || copied == expected + "\n",
                    "table \(index) \(style) copied \(copied.debugDescription)")
        }
    }
}

@Test func aTableWithoutBodyRowsStillRendersWhenStacked() throws {
    // A stacked table is emitted as header/value pairs. A table with no body has
    // no pairs, so the stacked projection emitted no row for it and the whole
    // table disappeared from the presentation.
    let source = "intro\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\n| Name |\n| --- |\n\noutro\n"
    let parsed = MarkdownTables.parse(source)
    #expect(parsed.count == 2)
    #expect(parsed[1].body.isEmpty)
    let projection = MarkdownTablePresentation.project(source, tables: parsed,
                                                       stacked: [1], style: .pipes)
    #expect(projection.text.contains("Name"))
    #expect(projection.rowOwner == [0, 0, 1])
    #expect(wholeTableCopy(projection, 1, in: source) == "| Name |\n| --- |\n")
}

@Test func quotedAndListedTablesKeepTheirPrefixOnEveryCopiedRow() throws {
    // The block prefix is hidden source. Recording it ahead of the row's opening
    // pipe put its presentation offset before the row range, so a copy covering
    // the whole table started after it and the first line lost its `> ` or
    // bullet. The copied Markdown has to round-trip unchanged.
    for source in ["> | a | b |\n> | --- | --- |\n> | 1 | 2 |\n\nafter\n",
                   "- | a | b |\n  | --- | --- |\n  | 1 | 2 |\n\nafter\n",
                   "  | a | b |\n  | --- | --- |\n  | 1 | 2 |\n\nafter\n"] {
        let text = source as NSString
        let tables = try #require(MarkdownTables.parse(source).first)
        for projection in [
            MarkdownTablePresentation.project(source, tables: [tables], style: .pipes),
            MarkdownTablePresentation.project(source, tables: [tables], style: .tabs),
            MarkdownTablePresentation.project(source, tables: [tables], stacked: [0], style: .pipes)
        ] {
            let copied = try #require(wholeTableCopy(projection, 0, in: source))
            let expected = text.substring(with: tables.range)
            #expect(copied == expected || copied == expected + "\n",
                    "copied \(copied.debugDescription)")
        }
    }
}

@Test func aTableAtTheEndOfAFileCopiesBackFromEveryLayout() throws {
    // No trailing newline exists to hide, and a CRLF table's terminator is two
    // units rather than one.
    for source in ["| a | b |\n| --- | --- |\n| 1 | 2 |",
                   "> | a | b |\n> | --- | --- |\n> | 1 | 2 |",
                   "| a | b |\r\n| --- | --- |\r\n| 1 | 2 |",
                   "| a | b |\r\n| --- | --- |\r\n| 1 | 2 |\r\n"] {
        let tables = try #require(MarkdownTables.parse(source).first)
        for projection in [
            MarkdownTablePresentation.project(source, tables: [tables], style: .pipes),
            MarkdownTablePresentation.project(source, tables: [tables], stacked: [0], style: .pipes)
        ] {
            let copied = try #require(wholeTableCopy(projection, 0, in: source))
            #expect(copied == source, "copied \(copied.debugDescription) from \(source.debugDescription)")
        }
    }
}

@Test func projectionRecordsItsRowStyleInsteadOfInferringItFromPipes() throws {
    let tables = MarkdownTables.parse(tableFixture)
    // A cell may legitimately contain a literal pipe. Inferring the style by
    // searching the text for "|" mistook that content for a separator and
    // suppressed the tab stops for every other table in the document.
    #expect(MarkdownTablePresentation.project(tableFixture, tables: tables,
                                              style: .pipes).rowStyle == .pipes)
    #expect(MarkdownTablePresentation.project(tableFixture, tables: tables,
                                              style: .tabs).rowStyle == .tabs)
    // The stacked overload dropped the caller's style and fell back to tabs,
    // removing the very separators that keep columns aligned.
    #expect(MarkdownTablePresentation.project(tableFixture, tables: tables,
                                              stacked: [], style: .pipes).rowStyle == .pipes)
    #expect(MarkdownTablePresentation.project(tableFixture, tables: tables,
                                              stacked: [0], style: .pipes).rowStyle == .pipes)
}

@Test func cellEscapesAreNotProcessedInsideCodeSpans() throws {
    func rendered(_ source: String) -> String {
        let table = try! #require(MarkdownTables.parse(source).first)
        let cell = table.body[0].cells[0].content
        return MarkdownTablePresentation.unescapedCell(cell, in: source as NSString)
            ?? (source as NSString).substring(with: cell)
    }
    // Outside a code span the escape is removed.
    #expect(rendered("| A | B |\n| --- | --- |\n| \\|x | y |") == "|x")
    // Inside a code span it is literal, per the GFM table rules.
    #expect(rendered("| A | B |\n| --- | --- |\n| `a\\|b` | y |") == "`a\\|b`")
    // A run of backticks is closed only by an identical run.
    #expect(rendered("| A | B |\n| --- | --- |\n| ``a\\|b`` | y |") == "``a\\|b``")
    // An unmatched run is literal text, so its escapes are still processed.
    #expect(rendered("| A | B |\n| --- | --- |\n| `a\\|b | y |") == "`a|b")
}

@Test func tableProjectionPreservesSurroundingProseAndSourceSpans() throws {
    let tables = MarkdownTables.parse(tableFixture)
    let projection = MarkdownTablePresentation.project(tableFixture, tables: tables,
                                                       style: .pipes)
    // Prose between the tables survives verbatim.
    #expect(projection.text.contains("Colons can be used to align columns."))
    #expect(projection.text.contains("You can also use inline Markdown."))
    // The delimiter rows are structural and never reach the presentation.
    for table in tables {
        #expect(!projection.text.contains((tableFixture as NSString)
            .substring(with: table.delimiter.line)))
    }
    // Every row range must address real presentation text on one line.
    let text = projection.text as NSString
    for row in projection.rowRanges {
        #expect(NSMaxRange(row) <= text.length)
        #expect(row.length > 0)
    }
}

@Test func gridIsOnlyApprovedWhenTheProjectedRowActuallyFits() throws {
    let tables = MarkdownTables.parse(tableFixture)
    let advance = 12.0
    // A pipe row is wider than the sum of its cells: each boundary costs a
    // literal ` |` plus a leading `|`. Estimating without them approved rows
    // that then overflowed the viewport and wrapped mid-cell.
    for available in [300.0, 456.0, 800.0, 1200.0] {
        for table in tables {
            guard case .grid = MarkdownTableLayoutPlanner.layout(
                for: table, in: tableFixture, available: available, advance: advance) else {
                continue
            }
            let cells = MarkdownTablePresentation.columnWidths(of: table, in: tableFixture)
            let projected = Double(1 + cells.reduce(0, +) + (cells.count - 1) * 2) * advance
            #expect(projected <= available,
                    "grid approved at \(available) but the row needs \(projected)")
        }
    }
}

@Test func gridColumnsAreNeverNarrowerThanTheirHeaderCells() throws {
    let tables = MarkdownTables.parse(tableFixture)
    let text = tableFixture as NSString
    let advance = 12.0
    // The header is the label each column is read by, so it must never be the
    // thing that wraps. Content wider than its header may still wrap.
    for available in [300.0, 456.0, 800.0, 1200.0] {
        for (index, table) in tables.enumerated() {
            guard case let .grid(stops) = MarkdownTableLayoutPlanner.layout(
                for: table, in: tableFixture, available: available, advance: advance) else {
                continue
            }
            var widths: [Double] = []
            var previous = 0.0
            for stop in stops { widths.append(stop - previous); previous = stop }
            widths.append(max(0, available - previous))
            for (column, cell) in table.header.cells.enumerated() where column < widths.count {
                let header = Double(
                    MarkdownTablePresentation.emittedCellWidth(cell.content, in: text)) * advance
                #expect(header <= widths[column] + 0.001,
                        "table \(index) column \(column) header needs \(header) but is \(widths[column])")
            }
        }
    }
}

@Test func smallTablesStillUseColumnsAtEveryTestedWidth() throws {
    let source = "| A | B |\n| --- | --- |\n| 1 | 2 |\n"
    let table = try #require(MarkdownTables.parse(source).first)
    for available in [200.0, 456.0, 800.0, 1200.0, 1600.0] {
        guard case let .grid(stops) = MarkdownTableLayoutPlanner.layout(
            for: table, in: source, available: available, advance: 12.0) else {
            Issue.record("a two-cell table stacked at \(available)")
            continue
        }
        for stop in stops {
            #expect(stop <= available, "stop \(stop) exceeds \(available)")
        }
    }
}

@Test func onlyTextIsLeftWrappableInsideCells() {
    // Text wraps; a code span, link, URL, or path does not. A space inside one
    // of those becomes U+00A0, which is exactly one UTF-16 unit like the space it
    // replaced, so every offset in the cell — and the whole map — stays valid.
    #expect(MarkdownTableAtomicElement.nonBreaking("`git status`") == "`git\u{00A0}status`")
    #expect(MarkdownTableAtomicElement.nonBreaking("run `git diff` now") == "run `git\u{00A0}diff` now")
    #expect(MarkdownTableAtomicElement.nonBreaking("``a b c``") == "``a\u{00A0}b\u{00A0}c``")
    #expect(MarkdownTableAtomicElement.nonBreaking("see /usr/local/bin here")
            == "see /usr/local/bin here")
    // Prose keeps ordinary breakable spaces.
    #expect(MarkdownTableAtomicElement.nonBreaking("plain prose wraps here") == "plain prose wraps here")
    #expect(MarkdownTableAtomicElement.nonBreaking("**bold** text here") == "**bold** text here")
    // Length is preserved in every case, which is what keeps the map valid.
    for value in ["`git status`", "a `b` c `d` e", "see [d](u) now", "no markup at all"] {
        #expect((MarkdownTableAtomicElement.nonBreaking(value) as NSString).length
                == (value as NSString).length)
    }
}

@Test func linkLabelsAndBareURLsStayOnOneLine() {
    // A link's label and destination form one clickable element, so a space
    // inside the label must not offer a wrap point.
    let label = "[the docs](https://example.com/a)"
    #expect(MarkdownTableAtomicElement.nonBreaking(label) == "[the\u{00A0}docs](https://example.com/a)")
    // A bare URL is atomic too, including one embedded in prose.
    let url = "go https://example.com/x now"
    #expect(MarkdownTableAtomicElement.nonBreaking(url) == url)
    // A link destination may not contain a space, so one is prose, not markup.
    #expect(MarkdownTableAtomicElement.nonBreaking("[d](u) tail") == "[d](u) tail")
}

@Test func nonBreakingSubstitutionStaysInsideAtomicElements() {
    // Prose around an element must still wrap; only the element is protected.
    let value = "first `code span` second"
    let rendered = MarkdownTableAtomicElement.nonBreaking(value)
    #expect(rendered.contains("first "))
    #expect(rendered.contains(" second"))
    #expect(!rendered.contains("first\u{00A0}"))
    #expect(!rendered.contains("\u{00A0}second"))
}

@Test func cellSubstitutionLeavesSourceCopyAndWidthsIntact() throws {
    let source = "| Command | Description |\n| --- | --- |\n| `git status` | List all new or modified files |\n| `git diff` | See /usr/local/share/notes.txt |"
    let projection = MarkdownTablePresentation.project(source, style: .pipes)
    // The presentation protects the code span and the path.
    #expect(projection.text.contains("\u{00A0}"))
    // Copy still returns the original Markdown, with real spaces.
    let rows = projection.rowRanges
    let first = try #require(rows.first)
    let last = try #require(rows.last)
    guard let copied = projection.map.sourceRange(
        coveringPresentation: NSRange(location: first.location,
                                       length: NSMaxRange(last) - first.location)) else {
        Issue.record("the table did not map back to source")
        return
    }
    let substring = (source as NSString).substring(with: copied)
    #expect(!substring.unicodeScalars.contains("\u{00A0}"))
    #expect(substring.contains("`git status`"))
    #expect(substring.contains("/usr/local/share/notes.txt"))
    // A non-breaking space measures exactly like the space it replaced, so
    // padded rows stay the same width and their separators stay aligned.
    let widths = rows.map { MarkdownTableWidth.of(projection.text as NSString, range: $0) }
    #expect(Set(widths).count == 1, "rows render at \(widths)")
}

@Test func tableCellsTrimSpacingAndSplitOnUnescapedPipes() throws {
    let source = "|  Name  | Value |\n| --- | --- |\n|  a\\|b  |  2  |"
    let tables = MarkdownTables.parse(source)
    let table = try #require(tables.first)
    #expect(tables.count == 1)
    #expect(table.columnCount == 2)
    #expect(table.alignments == [.none, .none])
    #expect((source as NSString).substring(with: table.header.cells[0].content) == "Name")
    // The escaped pipe stays inside one cell, and trimming keeps cell content.
    #expect((source as NSString).substring(with: table.body[0].cells[0].content) == "a\\|b")
    #expect((source as NSString).substring(with: table.body[0].cells[1].content) == "2")
    #expect((source as NSString).substring(with: table.range) == source)
}

@Test func tableAlignmentMarkersAreRecognized() throws {
    let source = "| a | b | c | d |\n| :-- | :-: | --: | --- |\n| 1 | 2 | 3 | 4 |"
    let table = try #require(MarkdownTables.parse(source).first)
    #expect(table.alignments == [.left, .center, .right, .none])
}

@Test func tablesRequireADelimiterRowAndMatchingColumnCount() {
    #expect(MarkdownTables.parse("| a | b |\n| c | d |").isEmpty)
    #expect(MarkdownTables.parse("| a | b |\n| --- |\n| c | d |").isEmpty)
    #expect(MarkdownTables.parse("no pipes at all\n---\n").isEmpty)
    // A header-only table is still a table with no body rows.
    #expect(MarkdownTables.parse("| a |\n| --- |").first?.body.isEmpty == true)
}

@Test func fencedCodePipesAreNotTables() {
    let source = "```\n| a | b |\n| --- | --- |\n```\n"
    #expect(MarkdownTables.parse(source).isEmpty)
}

@Test func optionalOuterPipesAndEmptyCellsAreSupported() throws {
    let source = "a | b\n--- | ---\n | x"
    let table = try #require(MarkdownTables.parse(source).first)
    #expect(table.columnCount == 2)
    #expect(table.body[0].cells[0].isEmpty)
    #expect((source as NSString).substring(with: table.body[0].cells[1].content) == "x")
}

@Test func tablePresentationOmitsDelimiterRowAndKeepsCellText() throws {
    let source = "| A | B |\n| --- | --- |\n| c | d |"
    let table = try #require(MarkdownTables.parse(source).first)
    let result = MarkdownTablePresentation.build(table, in: source)
    #expect(!result.text.contains("---"))
    #expect(result.text == "A\tB\nc\td")
    #expect(result.rowRanges.count == 2)
    // Verbatim cell text resolves back to its exact source span.
    let cell = (source as NSString).range(of: "d")
    let mapped = result.map.segments.first { $0.source == cell }
    #expect(mapped != nil)
}

@Test func tableCopyAsTSVQuotesTabsNewlinesAndQuotes() throws {
    let source = "| A | B |\n| --- | --- |\n| x | a\"b |"
    let table = try #require(MarkdownTables.parse(source).first)
    #expect(MarkdownTablePresentation.tsv(table, in: source) == "A\tB\nx\t\"a\"\"b\"")
}

@Test func alignTableSourcePadsCellsInOneEditAndPreservesContent() throws {
    let source = "| Name | Value |\n| --- | --- |\n| a | longer |"
    let text = source as NSString
    let edit = try #require(try MarkdownTableAlignmentEdit.editAligningTable(at: 0, in: source))
    let result = try edit.applying(to: source)
    #expect(result == "| Name | Value  |\n| ---- | ------ |\n| a    | longer |")
    // The delimiter row is not rewritten: content and markers are preserved.
    #expect(result.contains("---"))
    // One undo restores the original source exactly.
    #expect(edit.range == NSRange(location: 0, length: text.length))
}

@Test func alignTableSourceIsNilForAlreadyAlignedAndNonTables() throws {
    let aligned = "| a   | b   |\n| --- | --- |\n| ccc | ddd |"
    #expect(try MarkdownTableAlignmentEdit.editAligningTable(at: 0, in: aligned) == nil)
    #expect(try MarkdownTableAlignmentEdit.editAligningTable(at: 0, in: "plain text") == nil)
}

@Test func tableWidthCountsWideCharactersAsTwoCells() {
    // Without an installed font measurer the static table applies.
    MarkdownTableWidth.useFontMetrics(nil)
    #expect(MarkdownTableWidth.of("abc") == 3)
    #expect(MarkdownTableWidth.of("日本") == 4)
    #expect(MarkdownTableWidth.of("") == 0)
    // A combining mark rides on the base glyph and adds no width.
    #expect(MarkdownTableWidth.of("e\u{0301}") == MarkdownTableWidth.of("e"))
    // Range and string overloads must agree.
    let text = "日本" as NSString
    #expect(MarkdownTableWidth.of(text, range: NSRange(location: 0, length: text.length)) == 4)
}

@Test func installedMeasurerOverridesTheStaticTable() {
    MarkdownTableWidth.useFontMetrics { _ in 7 }
    defer { MarkdownTableWidth.useFontMetrics(nil) }
    #expect(MarkdownTableWidth.of("abc") == 7)
    #expect(MarkdownTableWidth.of("日本") == 7)
    #expect(MarkdownTableWidth.of("abc" as NSString, range: NSRange(location: 0, length: 3)) == 7)
}

@Test func crlfTablesAlignWithoutConvertingNewlines() throws {
    let source = "| a | b |\r\n| --- | --- |\r\n| ccc | d |"
    let edit = try #require(try MarkdownTableAlignmentEdit.editAligningTable(at: 0, in: source))
    let result = try edit.applying(to: source)
    #expect(result.contains("\r\n"))
    #expect(!result.contains("\n\n"))
    #expect(!result.contains("\r\r"))
}