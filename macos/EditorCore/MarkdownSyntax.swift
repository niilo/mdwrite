import Foundation

/// Semantic styles address the original Markdown, never a rewritten editor buffer.
public struct MarkdownSyntaxRun: Sendable {
    public let range: NSRange
    public let inlineIntent: InlinePresentationIntent
    public let presentation: PresentationIntent?
    public let link: URL?
    public let image: URL?

    public var isCodeBlock: Bool {
        presentation?.components.contains {
            if case .codeBlock = $0.kind { return true }
            return false
        } ?? false
    }
}

public enum MarkdownSyntax {
    public static func runs(in source: String) -> [MarkdownSyntaxRun] {
        let source = String(decoding: source.utf8, as: UTF8.self)
        return runsInSnapshot(source)
    }

    static func runsInSnapshot(_ source: String) -> [MarkdownSyntaxRun] {
        guard let parsed = try? AttributedString(markdown: source, options: .init(
            interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible,
            appliesSourcePositionAttributes: true)) else { return [] }
        let bytes = Array(source.utf8)
        let offsets = SourceOffsets(bytes)
        var lineStarts = [0]
        for (offset, byte) in bytes.enumerated() where byte == 10 { lineStarts.append(offset + 1) }
        let byteCount = bytes.count
        return parsed.runs.compactMap { run in
            guard let position = run.markdownSourcePosition,
                  position.startLine > 0, position.endLine >= position.startLine,
                  position.endLine <= lineStarts.count, position.startColumn > 0, position.endColumn >= 0 else { return nil }
            // Foundation's convenience NSRange initializer on the current CLT
            // returns only the first code point. Map inclusive UTF-8 columns
            // explicitly and validate scalar boundaries instead.
            let start = lineStarts[position.startLine - 1] + position.startColumn - 1
            let end = lineStarts[position.endLine - 1] + position.endColumn
            guard start >= 0, end > start, end <= byteCount,
                  let lower = offsets.utf16(start),
                  let upper = offsets.utf16(end) else { return nil }
            let range = NSRange(location: lower, length: upper - lower)
            return MarkdownSyntaxRun(range: range, inlineIntent: run.inlinePresentationIntent ?? [],
                                     presentation: run.presentationIntent, link: run.link, image: run.imageURL)
        }
    }
}

/// Sparse conversion table: ASCII offsets require no entries. Each non-ASCII
/// scalar records the accumulated byte/UTF-16 difference at its end. Lookups
/// never traverse a bridged String and reject offsets inside UTF-8 scalars.
private struct SourceOffsets {
    let bytes: [UInt8]
    let ends: [Int]
    let reductions: [Int]

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
        var ends: [Int] = []
        var reductions: [Int] = []
        var index = 0
        var reduction = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte < 0x80 { index += 1; continue }
            let length = byte < 0xE0 ? 2 : byte < 0xF0 ? 3 : 4
            index += length
            reduction += length - (length == 4 ? 2 : 1)
            ends.append(index)
            reductions.append(reduction)
        }
        self.ends = ends
        self.reductions = reductions
    }

    func utf16(_ offset: Int) -> Int? {
        guard offset >= 0, offset <= bytes.count,
              offset == bytes.count || bytes[offset] & 0xC0 != 0x80 else { return nil }
        var lower = 0
        var upper = ends.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if ends[middle] <= offset { lower = middle + 1 } else { upper = middle }
        }
        return offset - (lower == 0 ? 0 : reductions[lower - 1])
    }
}
