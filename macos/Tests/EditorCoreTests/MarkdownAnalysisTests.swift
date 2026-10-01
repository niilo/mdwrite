import Foundation
import Testing
@testable import EditorCore

@Test func immutableAnalysisRetainsExactUnicodeSourceAndDescriptors() throws {
    let source = "# 👩‍💻é\n\n**strong** and *soft* [ref][id]\n\n```\n**literal**\n```\n\n[id]: https://example.com"
    let backing = NSMutableString(string: source)
    let analysis = MarkdownAnalysis.analyze(backing as String)
    backing.append("changed")
    #expect(Data(analysis.source.utf8) == Data(source.utf8))
    #expect(analysis.blocks == MarkdownBlocks.parse(source))
    #expect(analysis.inlineSpans == MarkdownSpans.inline(in: source))
    #expect(analysis.wordCount == EditorBehavior.wordCount(source))
    #expect(analysis.runs.map(\.range) == MarkdownSyntax.runs(in: source).map(\.range))
    #expect(analysis.runs.contains { $0.link?.absoluteString == "https://example.com" })
    #expect(analysis.codeRanges.count == 1)
    #expect(analysis.codeRanges.allSatisfy { NSMaxRange($0) <= (source as NSString).length })
}

@Test func rangeMappingHandlesRepeatedMultibyteScalarsAndCRLF() throws {
    let unit = "**é é 👩‍💻 🇫🇮 漢字**\r\n\r\n"
    let source = String(repeating: unit, count: 300)
    let runs = MarkdownSyntax.runs(in: NSMutableString(string: source) as String)
    let strong = runs.filter { $0.inlineIntent.contains(.stronglyEmphasized) }
    #expect(strong.count == 300)
    for run in strong {
        #expect((source as NSString).substring(with: run.range) == "é é 👩‍💻 🇫🇮 漢字")
    }
}

@Test func spliceValidationMatchesFullResultValidationAtUnicodeJoins() throws {
    let sources = ["a", "éx", "👩‍💻x", "🇫🇮🇸🇪🇺🇸x", "a\r\nb", "a\u{0600}b", "a\u{0301}b", "a👩‍👩‍👧‍👦b"]
    let replacements = ["", "x", "\u{0301}", "\u{200D}", "🇦", "\u{0600}", "\r", "\n"]
    for source in sources {
        let text = source as NSString
        for location in 0...text.length {
            for length in 0...(text.length - location) {
                let range = NSRange(location: location, length: length)
                for replacement in replacements {
                    let resultLength = text.length - length + (replacement as NSString).length
                    for selection in 0...resultLength {
                        let edit = SourceEdit(range: range, replacement: replacement,
                                              selection: NSRange(location: selection, length: 0))
                        let fullPass = (try? edit.applying(to: source)) != nil
                        var nativePass = true
                        do { try edit.validate(in: text) } catch { nativePass = false }
                        #expect(nativePass == fullPass,
                                "\(source.debugDescription) \(range) \(replacement.debugDescription) caret \(selection)")
                    }
                }
            }
        }
    }
}

@Test func returnColdContextPreservesLiteralContainersAndFenceEdits() throws {
    let cases: [(String, String)] = [
        ("- parent\n      - item", "- parent\n      - item\n      - "),
        ("> quote\n>     - item", "> quote\n>     - item\n>     - "),
        ("> quote\n>     code", "> quote\n>     code\n> "),
        ("text\n    - item", "text\n    - item\n    - "),
        ("- ```\n  code\n- item", "- ```\n  code\n- item\n"),
        ("> > ```\n> > code\n> - item", "> > ```\n> > code\n> - item\n> "),
        ("- parent\n  ```\n>     code", "- parent\n  ```\n>     code\n>     "),
        ("> ```\n> ", "> ```\n> \n> "),
        ("- ```\n  - literal", "- ```\n  - literal\n  "),
        ("> - ~~~\n>   - literal", "> - ~~~\n>   - literal\n>   "),
        ("    - literal", "    - literal\n    "),
        (">     - literal", ">     - literal\n>     "),
        ("    code\n    - literal", "    code\n    - literal\n    "),
        ("> ```\n> code\n> ```\n- item", "> ```\n> code\n> ```\n- item\n- "),
        ("> ```\n> code\n- item", "> ```\n> code\n- item\n"),
        ("```\n> - literal", "```\n> - literal\n"),
        ("~~~\n```\n- literal", "~~~\n```\n- literal\n"),
        ("```\ncode\n```\n- item", "```\ncode\n```\n- item\n- "),
        ("- parent\n    - child", "- parent\n    - child\n    - ")
    ]
    for (source, expected) in cases {
        let edit = try #require(try EditorBehavior.edit(.insertReturn(soft: false), in: source,
                                selection: NSRange(location: (source as NSString).length, length: 0)))
        #expect(try edit.applying(to: source) == expected, "\(source.debugDescription)")
    }
}

@Test func boundedGraphemeQueriesMatchNativeSegmentation() {
    let clusters = ["a", "é", "é", "👩‍💻", "👩‍👩‍👧‍👦", "🇫🇮🇸🇪🇦", "\r\n", "\r", "\n",
                    "\u{0600}a", "\u{0301}", "\u{200D}", "क्‍ष", "각", "1️⃣"]
    let sources = clusters.flatMap { left in clusters.map { right in "ab" + left + right + "cd" } }
        + [String(repeating: "🇦", count: 400), "a" + String(repeating: "\u{0301}", count: 600) + "bc",
           String(repeating: "x", count: 400) + "\r\n" + String(repeating: "y", count: 400)]
    for source in sources {
        let text = source as NSString
        for offset in 0..<text.length {
            #expect(EditorBehavior.composedCharacterRange(at: offset, in: text)
                    == text.rangeOfComposedCharacterSequence(at: offset),
                    "\(source.prefix(60).debugDescription) offset \(offset)")
        }
    }
}

@Test func seededReturnCheckpointsMatchColdContextAfterSourceEdits() throws {
    let unit = "# 👩‍💻é heading\n\n> > quote\n> - list\n>   - child\n\n```swift\n- literal\n```\n\n- parent\n    - child\n\n"
    var source = String(repeating: unit, count: 700)
    var cache = MarkdownReturnCache.seeded(in: source)
    var random: UInt64 = 0x5EED
    func next(_ count: Int) -> Int {
        random = random &* 6364136223846793005 &+ 1
        return Int(random % UInt64(count))
    }
    let replacements = ["", "x", "```\n", "~~~\n", "> ", "\n", "👩‍💻é", "    "]
    for iteration in 0..<100 {
        let text = source as NSString
        for position in [0, text.length / 3, text.length / 2, text.length - 1, text.length] {
            let caret = position == text.length ? position
                : EditorBehavior.composedCharacterRange(at: position, in: text).location
            let selection = NSRange(location: caret, length: 0)
            let cold = try EditorBehavior.edit(.insertReturn(soft: false), in: source, selection: selection)
            let cached = try EditorBehavior.edit(.insertReturn(soft: false), in: source,
                                                 selection: selection, returnCache: &cache)
            #expect(cached == cold, "iteration \(iteration) caret \(caret)")
        }
        let cluster = EditorBehavior.composedCharacterRange(at: next(text.length), in: text)
        let range = NSRange(location: cluster.location, length: iteration % 2 == 0 ? 0 : cluster.length)
        let replacement = replacements[next(replacements.count)]
        cache.invalidate(fromUTF16: range.location)
        source = try SourceEdit(range: range, replacement: replacement,
                                selection: NSRange(location: 0, length: 0)).applying(to: source)
    }
    cache.invalidate(fromUTF16: 0)
    source = "> ```\n> fresh code\n- item"
    let selection = NSRange(location: (source as NSString).length, length: 0)
    #expect(try EditorBehavior.edit(.insertReturn(soft: false), in: source, selection: selection, returnCache: &cache)
            == EditorBehavior.edit(.insertReturn(soft: false), in: source, selection: selection))
}
