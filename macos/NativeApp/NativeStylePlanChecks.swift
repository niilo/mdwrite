import AppKit
import EditorCore

@MainActor
enum NativeStylePlanChecks {
    static func run() throws {
        let dense = "**bold** *italic* ~~strike~~ `literal` [link](https://example.org) ![image](asset.png)\n\n| a | b |\n|---|---|\n| c | d |\n\n> > quote\n> - list\n>   - child\n\n"
        let mixed = "# H1 👩🏽‍💻\n\n> # H2\n> **bold** *italic* ~~strike~~ [link](https://example.org)\n> > quote\n> - [x] complete\n>   - nested\n\nTitle\n===\n\n| Head | Next |\n| --- | --- |\n| row | cell |\n\n```swift\n**literal**\n```\n\n    indented\n\n[remote][label]\n\n[label]: https://example.org\n\n---\n\n![image](a.png) &amp; \\*escape* <b>raw</b> [^note]\n\n[^note]: content\n\nsoft  \nnext\\\nline\r\nA é 日本語 🇫🇮\r\n"
        let malformed = "***open\r\n[bad](\r\n> # 👩🏽‍💻 title\r\n> - [ ] é item\r\n\r\n<em>raw\r\n\\*escaped &unknown;\r\n\r\n| a | b\r\n|---|---|\r\n\r\n~~~swift\r\n**literal** [^note]\r\n"
        for (name, source) in [("empty", ""), ("dense", String(repeating: dense, count: 32)),
                               ("mixed", mixed), ("malformed", malformed)] {
            let reference = NSTextStorage(string: source)
            _ = MarkdownStyler.apply(to: reference, fontSize: 20)
            let candidate = NSTextStorage(string: source)
            let plan = MarkdownStylePlanBuilder.build(MarkdownAnalysis.analyze(source))
            var end = 0
            for run in plan.runs {
                guard run.range.location == end, run.range.length > 0 else {
                    throw failure("\(name): style plan has missing or overlapping source coverage")
                }
                candidate.setAttributes(MarkdownStyler.attributes(for: run.style, fontSize: 20), range: run.range)
                end = NSMaxRange(run.range)
            }
            guard end == reference.length, plan.length == reference.length,
                  Data(candidate.string.utf8) == Data(source.utf8) else {
                throw failure("\(name): style plan changed source or coverage")
            }
            let whole = NSRange(location: 0, length: reference.length)
            reference.ensureAttributesAreFixed(in: whole)
            candidate.ensureAttributesAreFixed(in: whole)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                var discrepancy: String?
                NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                    for offset in 0..<reference.length {
                        for key in MarkdownStyler.ownedKeys {
                            let expected = reference.attribute(key, at: offset, effectiveRange: nil)
                            let actual = candidate.attribute(key, at: offset, effectiveRange: nil)
                            if !equal(actual, expected) {
                                discrepancy = "\(name): \(key.rawValue) differs at UTF16 \(offset) in \(appearance.rawValue)"
                                return
                            }
                        }
                    }
                }
                if let discrepancy { throw failure(discrepancy) }
            }
        }
        print("PASS: overlay style plans match native styles for dense, Unicode, CRLF, malformed, and empty Markdown")
    }

    private static func equal(_ actual: Any?, _ expected: Any?) -> Bool {
        if let actual = actual as? NSColor, let expected = expected as? NSColor {
            return actual.usingColorSpace(.deviceRGB) == expected.usingColorSpace(.deviceRGB)
        }
        if let actual = actual as? NSFont, let expected = expected as? NSFont {
            // Font fallback can return distinct private font objects with equal
            // public face, traits and metrics, especially for CJK and emoji.
            return actual.fontName == expected.fontName && actual.pointSize == expected.pointSize
                && actual.fontDescriptor.symbolicTraits == expected.fontDescriptor.symbolicTraits
                && actual.ascender == expected.ascender && actual.descender == expected.descender
                && actual.capHeight == expected.capHeight && actual.xHeight == expected.xHeight
        }
        return actual == nil && expected == nil || (actual as? NSObject)?.isEqual(expected) == true
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "mdwrite.style-plan", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
