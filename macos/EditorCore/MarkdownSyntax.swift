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
        guard let parsed = try? AttributedString(markdown: source, options: .init(
            interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible,
            appliesSourcePositionAttributes: true)) else { return [] }
        let bytes = source.utf8
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
                  let lower = String.Index(bytes.index(bytes.startIndex, offsetBy: start), within: source),
                  let upper = String.Index(bytes.index(bytes.startIndex, offsetBy: end), within: source) else { return nil }
            let range = NSRange(lower..<upper, in: source)
            return MarkdownSyntaxRun(range: range, inlineIntent: run.inlinePresentationIntent ?? [],
                                     presentation: run.presentationIntent, link: run.link, image: run.imageURL)
        }
    }
}
