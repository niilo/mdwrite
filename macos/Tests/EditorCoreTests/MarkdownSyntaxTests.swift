import Foundation
import Testing
@testable import EditorCore

@Test func semanticStylesUseCompleteUTF16SourceRanges() throws {
    let source = "# 👩‍💻é\n\n**👩‍💻é** and ***both*** ~~deleted~~ `**literal**`"
    let runs = MarkdownSyntax.runs(in: source)
    let emoji = try #require(runs.first { $0.inlineIntent.contains(.stronglyEmphasized) })
    #expect((source as NSString).substring(with: emoji.range) == "👩‍💻é")
    #expect(emoji.range.length == 7)
    let combined = try #require(runs.first { $0.inlineIntent.contains(.stronglyEmphasized) && $0.inlineIntent.contains(.emphasized) })
    #expect((source as NSString).substring(with: combined.range) == "both")
    let code = try #require(runs.first { $0.inlineIntent.contains(.code) })
    #expect((source as NSString).substring(with: code.range) == "**literal**")
    #expect(!code.inlineIntent.contains(.stronglyEmphasized))
}

@Test func semanticParserDistinguishesNestedContainersLinksAndEscapedText() throws {
    let source = "> > nested\n\n- outer\n  - inner\n\n![image](picture.png) [ref][label] \\*escaped*\n\n[label]: https://example.com"
    let runs = MarkdownSyntax.runs(in: source)
    let nested = try #require(runs.first { (source as NSString).substring(with: $0.range) == "nested" })
    #expect(nested.presentation?.components.filter { $0.kind == .blockQuote }.count == 2)
    let inner = try #require(runs.first { (source as NSString).substring(with: $0.range) == "inner" })
    #expect(inner.presentation?.components.filter { $0.kind == .unorderedList }.count == 2)
    #expect(runs.contains { $0.image?.relativeString == "picture.png" })
    #expect(runs.contains { $0.link?.absoluteString == "https://example.com" })
    #expect(!runs.contains { $0.inlineIntent.contains(.emphasized) })
}

@Test func indentedCodeKeepsBlankLineEndPositionsAndLiteralSyntax() throws {
    let source = "---\n\n    **literal**\n\nbody"
    let code = try #require(MarkdownSyntax.runs(in: source).first { $0.isCodeBlock })
    #expect((source as NSString).substring(with: code.range) == "**literal**\n")
    #expect(!code.inlineIntent.contains(.stronglyEmphasized))
}

@Test func nativeReturnUsesSingleNewlinesAndContextualContinuation() throws {
    let cases: [(String, String)] = [
        ("hello", "hello\n"), ("# heading", "# heading\n"), ("hello\n", "hello\n\n"),
        ("- item", "- item\n- "), ("9. item", "9. item\n10. "),
        ("- [x] done", "- [x] done\n- [ ] "), ("- [ ] ", "\n"),
        ("> > quote", "> > quote\n> > "), ("> ", "\n"),
        ("~~~\n- literal", "~~~\n- literal\n"),
        ("````\n```\n- literal", "````\n```\n- literal\n"),
        ("    code", "    code\n    "),
        ("> ~~~\n> - literal", "> ~~~\n> - literal\n> "),
        ("```\n> literal", "```\n> literal\n"),
        ("> - item", "> - item\n> - "), ("> 9. item", "> 9. item\n> 10. "),
        ("- parent\n    - child", "- parent\n    - child\n    - ")
    ]
    for (source, expected) in cases {
        let result = try EditorBehavior.edit(.insertReturn(soft: false), in: source,
                                             selection: NSRange(location: source.utf16.count, length: 0))
        let edit = try #require(result)
        #expect(try edit.applying(to: source) == expected, "\(source.debugDescription)")
    }
}
