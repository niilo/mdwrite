import Foundation

/// Immutable, source-addressed analysis shared by background workers and AppKit.
/// AppKit objects and presentation attributes never cross this boundary.
public struct MarkdownAnalysis: Sendable {
    public let source: String
    public let runs: [MarkdownSyntaxRun]
    public let blocks: [MarkdownBlock]
    public let inlineSpans: [InlineMarkup]
    public let codeRanges: [NSRange]
    public let wordCount: Int
    public let returnCache: MarkdownReturnCache
    /// GFM tables discovered in the same snapshot, for View-mode presentation.
    public let tables: [MarkdownTable]

    public static func analyze(_ source: String) -> MarkdownAnalysis {
        let snapshot = String(decoding: source.utf8, as: UTF8.self)
        let runs = MarkdownSyntax.runsInSnapshot(snapshot)
        let blocks = MarkdownBlocks.parse(snapshot)
        let candidates = runs.filter(\.isCodeBlock).map(\.range)
            + blocks.filter { $0.kind == .fencedCode }.map(\.range)
        var merged: [NSRange] = []
        for range in candidates.sorted(by: { $0.location < $1.location }) where range.length > 0 {
            if let previous = merged.last, range.location <= NSMaxRange(previous) {
                merged[merged.count - 1] = NSUnionRange(previous, range)
            } else {
                merged.append(range)
            }
        }
        return MarkdownAnalysis(source: snapshot, runs: runs, blocks: blocks,
                                inlineSpans: MarkdownSpans.inline(in: snapshot),
                                codeRanges: merged, wordCount: EditorBehavior.wordCount(snapshot),
                                returnCache: MarkdownReturnCache.seeded(in: snapshot),
                                tables: MarkdownTables.parse(snapshot))
    }
}

/// Foundation regular expressions are immutable and safe for concurrent matching.
/// The small constant-pattern cache is protected only while fetching/compiling.
enum MarkdownRegex {
    private struct State: Sendable {
        var patterns: [String: NSRegularExpression] = [:]
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var state = State()

    static func expression(_ pattern: String) -> NSRegularExpression {
        lock.lock()
        defer { lock.unlock() }
        if let regex = state.patterns[pattern] { return regex }
        let regex = try! NSRegularExpression(pattern: pattern)
        state.patterns[pattern] = regex
        return regex
    }
}
