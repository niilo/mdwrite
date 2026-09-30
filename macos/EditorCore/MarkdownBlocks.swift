import Foundation

public struct MarkdownBlock: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case heading(level: Int)
        case fencedCode
    }

    public let kind: Kind
    public let range: NSRange
    public let content: NSRange
    public let markers: [NSRange]
}

public enum MarkdownBlocks {
    /// Source-preserving block ranges. Fences retain their delimiter and length,
    /// so a shorter or different delimiter cannot close an active code block.
    public static func parse(_ source: String) -> [MarkdownBlock] {
        let text = source as NSString
        let fencePattern = try! NSRegularExpression(pattern: #"^ {0,3}(`{3,}|~{3,})(.*)$"#)
        let headingPattern = try! NSRegularExpression(pattern: #"^ {0,3}(#{1,6})[ \t]+(.*?)(?:[ \t]+#+[ \t]*)?$"#)
        var result: [MarkdownBlock] = []
        var fence: (delimiter: Character, count: Int, start: Int, contentStart: Int, marker: NSRange)?
        var offset = 0
        while offset < text.length {
            let lineRange = text.lineRange(for: NSRange(location: offset, length: 0))
            let line = text.substring(with: lineRange).trimmingCharacters(in: .newlines)
            let lineLength = (line as NSString).length
            let wholeLine = NSRange(location: 0, length: lineLength)
            let match = fencePattern.firstMatch(in: line, range: wholeLine)
            if let active = fence {
                if let match {
                    let delimiter = (line as NSString).substring(with: match.range(at: 1))
                    let suffix = (line as NSString).substring(with: match.range(at: 2))
                    if delimiter.first == active.delimiter && delimiter.count >= active.count
                        && suffix.trimmingCharacters(in: .whitespaces).isEmpty {
                        result.append(MarkdownBlock(kind: .fencedCode,
                            range: NSRange(location: active.start, length: NSMaxRange(lineRange) - active.start),
                            content: NSRange(location: active.contentStart, length: offset - active.contentStart),
                            markers: [active.marker, NSRange(location: offset, length: lineLength)]))
                        fence = nil
                    }
                }
            } else if let match {
                let delimiter = (line as NSString).substring(with: match.range(at: 1))
                let suffix = (line as NSString).substring(with: match.range(at: 2))
                if delimiter.first != "`" || !suffix.contains("`") {
                    fence = (delimiter.first!, delimiter.count, offset, NSMaxRange(lineRange),
                             NSRange(location: offset, length: lineLength))
                }
            } else if let match = headingPattern.firstMatch(in: line, range: wholeLine) {
                let content = match.range(at: 2)
                var markers = [NSRange(location: offset, length: content.location)]
                if NSMaxRange(content) < lineLength {
                    markers.append(NSRange(location: offset + NSMaxRange(content), length: lineLength - NSMaxRange(content)))
                }
                result.append(MarkdownBlock(kind: .heading(level: match.range(at: 1).length), range: lineRange,
                    content: NSRange(location: offset + content.location, length: content.length), markers: markers))
            }
            offset = NSMaxRange(lineRange)
        }
        if let active = fence {
            result.append(MarkdownBlock(kind: .fencedCode,
                range: NSRange(location: active.start, length: text.length - active.start),
                content: NSRange(location: active.contentStart, length: text.length - active.contentStart),
                markers: [active.marker]))
        }
        return result
    }
}
