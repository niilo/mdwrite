import Foundation
import Testing
@testable import EditorCore

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