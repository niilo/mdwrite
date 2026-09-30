import Foundation
import Testing
@testable import EditorCore

private func formatted(_ format: MarkdownFormat, _ source: String, selection: NSRange? = nil) throws -> String {
    let edit = try EditorBehavior.edit(.format(format), in: source,
                                       selection: selection ?? NSRange(location: 0, length: source.utf16.count))
    return try edit?.applying(to: source) ?? source
}

@Test func formatCatalogHasValidEmptyAndUnicodeEdits() throws {
    #expect(MarkdownFormat.groups.flatMap(\.options) == MarkdownFormat.allCases)
    #expect(Set(MarkdownFormat.allCases.map(\.title)).count == MarkdownFormat.allCases.count)
    for format in MarkdownFormat.allCases {
        for source in ["", "👩‍💻é"] {
            let optional = try EditorBehavior.edit(.format(format), in: source,
                                                    selection: NSRange(location: 0, length: source.utf16.count))
            if optional == nil {
                #expect(format == .paragraph || format == .outdent || format == .escape,
                        "Unexpected no-op for \(format.title)")
                continue
            }
            let edit = try #require(optional)
            let result = try edit.applying(to: source)
            #expect(!result.isEmpty, "\(format.title) has no template")
            #expect(Range(edit.selection, in: result) != nil, "\(format.title) selects an invalid range")
        }
    }
}

@Test func inlineToolboxProducesLiteralCodeAndEscapedLabels() throws {
    let cases: [(MarkdownFormat, String, String)] = [
        (.bold, "text", "**text**"), (.italic, "text", "*text*"),
        (.boldItalic, "text", "***text***"), (.strikethrough, "text", "~~text~~"),
        (.inlineCode, "a`b", "``a`b``"), (.inlineCode, "`code`", "`` `code` ``"),
        (.inlineCode, " text ", "`  text  `"),
        (.image, "a[b]", "![a\\[b\\]](image.png)"),
        (.referenceLink, "a[b]", "[a\\[b\\]][reference]\n\n[reference]: https://example.com"),
        (.referenceImage, "a[b]", "![a\\[b\\]][reference]\n\n[reference]: image.png"),
        (.autolink, "www.example.com", "<https://www.example.com>"),
        (.escape, "*a* [b] \\", "\\*a\\* \\[b\\] \\\\"),
        (.comment, "comment", "<!-- comment -->"), (.hardBreak, "", "  \n")
    ]
    for (format, source, expected) in cases {
        #expect(try formatted(format, source) == expected, "\(format.title)")
    }
    let image = try #require(try EditorBehavior.edit(.format(.image), in: "label", selection: NSRange(location: 0, length: 5)))
    let result = try image.applying(to: "label") as NSString
    #expect(result.substring(with: image.selection) == "image.png")
    for (format, selected) in [(MarkdownFormat.heading1, "Heading"), (.setextHeading1, "Heading"),
                               (.unorderedList, ""), (.taskList, ""), (.blockquote, ""),
                               (.indentedCode, "code")] {
        let edit = try #require(try EditorBehavior.edit(.format(format), in: "", selection: NSRange(location: 0, length: 0)))
        #expect((try edit.applying(to: "") as NSString).substring(with: edit.selection) == selected,
                "Typing after \(format.title) should preserve its markers")
    }
}

@Test func lineFormatsReplacePrefixesAndRespectSelectionBoundaries() throws {
    #expect(try formatted(.heading3, "## title") == "### title")
    #expect(try formatted(.paragraph, "- [x] task") == "task")
    #expect(try formatted(.setextHeading1, "## title") == "title\n=====")
    #expect(try formatted(.heading2, "title\n=====") == "## title")
    #expect(try formatted(.heading2, "title\n=====\nnext", selection: NSRange(location: 2, length: 0)) == "## title\nnext")
    #expect(try formatted(.orderedList, "- one\n- [x] two") == "1. one\n2. two")
    #expect(try formatted(.taskList, "1. one\n2. two") == "- [ ] one\n- [ ] two")
    #expect(try formatted(.completedTask, "- [ ] one") == "- [x] one")
    #expect(try formatted(.blockquote, "> one\n\ntwo") == "> > one\n> \n> two")
    #expect(try formatted(.unorderedList, "one\ntwo\nthree", selection: NSRange(location: 0, length: 8))
            == "- one\n- two\nthree")
    #expect(try formatted(.heading1, "one\ntwo", selection: NSRange(location: 1, length: 0)) == "# one\ntwo")
    let nested = try formatted(.indent, "- one\n- two")
    #expect(nested == "    - one\n    - two")
    #expect(try formatted(.outdent, nested) == "- one\n- two")
}

@Test func blockTemplatesStaySeparateAndUseSafeFences() throws {
    #expect(try formatted(.fencedCode, "```\ncode") == "````\n```\ncode\n````")
    #expect(try formatted(.fencedCode, "before\ncode\nafter", selection: NSRange(location: 8, length: 0))
            == "before\n\n```\ncode\n```\n\nafter")
    #expect(try formatted(.indentedCode, "before\ncode\nafter", selection: NSRange(location: 8, length: 0))
            == "before\n\n    code\n\nafter")
    #expect(try formatted(.horizontalRule, "beforeafter", selection: NSRange(location: 6, length: 0))
            == "before\n\n---\n\nafter")
    #expect(try formatted(.table, "A|B") == "| A\\|B | Column 2 |\n| --- | --- |\n| Cell | Cell |")
    #expect(try formatted(.linkDefinition, "https://example.com") == "[reference]: https://example.com")
    #expect(try formatted(.html, "text") == "<div>\ntext\n</div>")
}

@Test func footnotesPreserveSurroundingTextAndAvoidLabelCollisions() throws {
    #expect(try formatted(.footnote, "before note after", selection: NSRange(location: 7, length: 4))
            == "before [^note1] after\n\n[^note1]: note")
    #expect(try formatted(.footnote, "See [^note1].\n\n[^note1]: first", selection: NSRange(location: 0, length: 0))
            == "[^note2]See [^note1].\n\n[^note1]: first\n\n[^note2]: Footnote text")
    #expect(try formatted(.footnote, "one\ntwo") == "[^note1]\n\n[^note1]: one\n    two")
    let source = "one after\n\n[Reference]: https://old.example.com"
    #expect(try formatted(.referenceLink, source, selection: NSRange(location: 0, length: 3))
            == "[one][reference2] after\n\n[Reference]: https://old.example.com\n\n[reference2]: https://example.com")
}
