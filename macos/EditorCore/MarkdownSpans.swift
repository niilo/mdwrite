import Foundation

public struct InlineMarkup: Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case bold, italic, link
    }

    public let kind: Kind
    public let content: NSRange
    public let markers: [NSRange]
}

public enum MarkdownSpans {
    /// Preserve the Qt editor's deliberately limited, per-line syntax subset.
    /// All ranges address the full unmodified source in UTF-16 units.
    public static func inline(in source: String) -> [InlineMarkup] {
        let nsSource = source as NSString
        var result: [InlineMarkup] = []
        var lineStart = 0
        for line in source.components(separatedBy: "\n") {
            for match in EditorBehavior.matches(#"(\*\*|__)(.+?)(\1)"#, in: line) {
                result.append(InlineMarkup(kind: .bold, content: shifted(match.range(at: 2), by: lineStart),
                                           markers: [shifted(match.range(at: 1), by: lineStart),
                                                     shifted(match.range(at: 3), by: lineStart)]))
            }
            for match in EditorBehavior.matches(#"(?<!\*)\*([^*\n]+)\*(?!\*)|(?<!_)_([^_\n]+)_(?!_)"#, in: line) {
                let content = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
                result.append(InlineMarkup(kind: .italic, content: shifted(content, by: lineStart),
                                           markers: [NSRange(location: lineStart + match.range.location, length: 1),
                                                     NSRange(location: lineStart + NSMaxRange(match.range) - 1, length: 1)]))
            }
            for match in EditorBehavior.matches(#"\[([^\]]+)\]\(((?:\\.|[^)])+)\)"#, in: line) {
                let content = match.range(at: 1)
                result.append(InlineMarkup(kind: .link, content: shifted(content, by: lineStart),
                                           markers: [NSRange(location: lineStart + match.range.location, length: 1),
                                                     NSRange(location: lineStart + NSMaxRange(content),
                                                             length: NSMaxRange(match.range) - NSMaxRange(content))]))
            }
            lineStart += (line as NSString).length + 1
        }
        assert(result.allSatisfy { NSMaxRange($0.content) <= nsSource.length })
        return result
    }

    private static func shifted(_ range: NSRange, by offset: Int) -> NSRange {
        NSRange(location: range.location + offset, length: range.length)
    }
}
