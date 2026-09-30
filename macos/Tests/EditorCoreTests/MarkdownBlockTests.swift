import Foundation
import Testing
@testable import EditorCore

@Test func headingsHaveLevelsAndSourceUTF16Ranges() {
    let source = "👩‍💻\n# One\n## Two ##\n### Three\n#### Four\n##### Five\n###### Six\n####### plain"
    let blocks = MarkdownBlocks.parse(source)
    #expect(blocks.map(\.kind) == (1...6).map { .heading(level: $0) })
    #expect(blocks.map { (source as NSString).substring(with: $0.content) }
            == ["One", "Two", "Three", "Four", "Five", "Six"])
    #expect(blocks[0].content.location == (source as NSString).range(of: "One").location)
}

@Test func codeFencesSuppressHeadingsAndRequireMatchingDelimiters() throws {
    let source = "# Before\n````swift\n# literal\n```\n~~~\n**literal**\n`````\n## After"
    let blocks = MarkdownBlocks.parse(source)
    #expect(blocks.map(\.kind) == [.heading(level: 1), .fencedCode, .heading(level: 2)])
    let code = try #require(blocks.first { $0.kind == .fencedCode })
    #expect((source as NSString).substring(with: code.content) == "# literal\n```\n~~~\n**literal**\n")
    #expect(code.markers.count == 2)
    #expect((source as NSString).substring(with: code.markers[1]) == "`````")
}

@Test func unfinishedAndTildeFencesIncludeBlankLinesWithoutConsumingFollowingHeadings() throws {
    let closed = "  ~~~ python\n\n👩‍💻\n  ~~~~\n# Outside"
    let blocks = MarkdownBlocks.parse(closed)
    #expect(blocks.map(\.kind) == [.fencedCode, .heading(level: 1)])
    #expect((closed as NSString).substring(with: blocks[0].content) == "\n👩‍💻\n")
    let unfinished = "```\n# literal\n\n"
    let code = try #require(MarkdownBlocks.parse(unfinished).first)
    #expect(code.kind == .fencedCode)
    #expect(NSMaxRange(code.range) == unfinished.utf16.count)
    #expect(code.markers.count == 1)
    #expect(MarkdownBlocks.parse("    ```\n# Heading").map(\.kind) == [.heading(level: 1)])
}
