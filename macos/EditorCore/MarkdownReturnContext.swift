import Foundation

fileprivate struct ReturnScanState: Sendable {
    var active: (delimiter: unichar, count: Int, quoteDepth: Int, listMinimum: Int, hasContent: Bool)?
    var listIndent: Int?
    var indentedCode = false
    var quotedIndentedCode = false
    var paragraphActive = false
    var previousQuoteDepth = 0
    // Preserve the source-block scanner's top-level fence interpretation,
    // independently of semantic list/quote containers.
    var rawFence: (delimiter: unichar, count: Int)?
    // Foundation source-position code ranges include the first line ending
    // an unclosed container fence once it has content. Smart Return has
    // historically treated that terminating line as literal code too.
    var finalGhostQuote: Int?
}

/// Lexical checkpoints belong to one source revision. Native adapters must
/// invalidate at the earliest character edit and reset on load/replacement.
public struct MarkdownReturnCache: Sendable {
    fileprivate struct Checkpoint: Sendable {
        let offset: Int
        let state: ReturnScanState
    }
    fileprivate var checkpoints = [Checkpoint(offset: 0, state: ReturnScanState())]

    public init() {}

    public static func seeded(in source: String) -> MarkdownReturnCache {
        var cache = MarkdownReturnCache()
        let text = source as NSString
        _ = MarkdownReturnContext.context(in: text, before: text.length, cache: &cache)
        return cache
    }

    public mutating func invalidate(fromUTF16 offset: Int) {
        checkpoints.removeAll { $0.offset >= max(0, offset) && $0.offset != 0 }
    }

    fileprivate func checkpoint(before offset: Int) -> Checkpoint {
        var lower = 0
        var upper = checkpoints.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if checkpoints[middle].offset <= offset { lower = middle + 1 } else { upper = middle }
        }
        return checkpoints[max(0, lower - 1)]
    }
}


/// A cold-cache lexical scan. It reads the original UTF-16 buffer without making
/// a full prefix copy or invoking Foundation's semantic Markdown parser.
enum MarkdownReturnContext {
    struct Context {
        let inFence: Bool
        let quotedFence: Bool
        let indentedCode: Bool
        let quotedIndentedCode: Bool
    }

    static func context(in text: NSString, before caret: Int) -> Context {
        var cache = MarkdownReturnCache()
        return context(in: text, before: caret, cache: &cache)
    }

    static func context(in text: NSString, before caret: Int,
                        cache: inout MarkdownReturnCache) -> Context {
        let checkpoint = cache.checkpoint(before: caret)
        var offset = checkpoint.offset
        var state = checkpoint.state
        while offset < caret {
            let lineRange = text.lineRange(for: NSRange(location: offset, length: 0))
            let end = min(NSMaxRange(lineRange), caret)
            state.finalGhostQuote = nil
            var rawCursor = offset
            var rawSpaces = 0
            while rawCursor < end && text.character(at: rawCursor) == 32 && rawSpaces < 4 {
                rawCursor += 1; rawSpaces += 1
            }
            if rawSpaces <= 3, rawCursor < end,
               [96, 126].contains(text.character(at: rawCursor)) {
                let delimiter = text.character(at: rawCursor)
                let marker = rawCursor
                while rawCursor < end && text.character(at: rawCursor) == delimiter { rawCursor += 1 }
                let count = rawCursor - marker
                if count >= 3 {
                    var suffix = rawCursor
                    while suffix < end && [32, 9, 10, 13].contains(text.character(at: suffix)) { suffix += 1 }
                    if let fence = state.rawFence {
                        if delimiter == fence.delimiter && count >= fence.count && suffix == end { state.rawFence = nil }
                    } else {
                        var valid = true
                        if delimiter == 96 {
                            while rawCursor < end {
                                if text.character(at: rawCursor) == 96 { valid = false; break }
                                rawCursor += 1
                            }
                        }
                        if valid { state.rawFence = (delimiter, count) }
                    }
                }
            }
            var cursor = offset
            var spaces = 0
            while cursor < end && text.character(at: cursor) == 32 && spaces < 4 {
                cursor += 1; spaces += 1
            }
            var depth = 0
            // A top-level fence treats quote markers in its contents literally.
            if state.active?.quoteDepth != 0 {
                while cursor < end && text.character(at: cursor) == 62 {
                    depth += 1; cursor += 1
                    if cursor < end && [32, 9].contains(text.character(at: cursor)) { cursor += 1 }
                    var padding = 0
                    while cursor < end && text.character(at: cursor) == 32 && padding < 3 {
                        cursor += 1; padding += 1
                    }
                }
            }
            var listOpeningCursor: Int?
            var indentation = 0
            var content = offset
            // For indentation, remove quote markers and their optional separator.
            var quoteCount = 0
            while content < end {
                var probe = content
                var padding = 0
                while probe < end && text.character(at: probe) == 32 && padding < 3 {
                    probe += 1; padding += 1
                }
                guard probe < end && text.character(at: probe) == 62 else { break }
                quoteCount += 1
                content = probe + 1
                if content < end && [32, 9].contains(text.character(at: content)) { content += 1 }
            }
            while content < end && [32, 9].contains(text.character(at: content)) {
                indentation += text.character(at: content) == 9 ? 4 - indentation % 4 : 1
                content += 1
            }
            let nonempty = content < end && ![10, 13].contains(text.character(at: content))
            if quoteCount > state.previousQuoteDepth { state.paragraphActive = false; state.listIndent = nil; state.indentedCode = false }
            else if quoteCount < state.previousQuoteDepth { state.listIndent = nil; state.indentedCode = false }
            state.previousQuoteDepth = quoteCount
            if nonempty {
                if let minimum = state.listIndent, indentation < minimum { state.listIndent = nil }
                state.indentedCode = (!state.paragraphActive || state.indentedCode)
                    && indentation >= (state.listIndent.map { $0 + 4 } ?? 4)
                state.quotedIndentedCode = state.indentedCode && quoteCount > 0
                if !state.indentedCode {
                    let marker = text.character(at: content)
                    var markerEnd = content
                    if [45, 43, 42].contains(marker) { markerEnd += 1 }
                    else if (48...57).contains(marker) {
                        while markerEnd < end && (48...57).contains(text.character(at: markerEnd)) { markerEnd += 1 }
                        if markerEnd < end && [46, 41].contains(text.character(at: markerEnd)) { markerEnd += 1 }
                        else { markerEnd = content }
                    }
                    if markerEnd > content && markerEnd < end && [32, 9].contains(text.character(at: markerEnd)) {
                        state.listIndent = indentation + markerEnd - content + 1
                        var candidate = markerEnd + 1
                        while candidate < end && [32, 9].contains(text.character(at: candidate)) { candidate += 1 }
                        listOpeningCursor = candidate
                    }
                }
            }
            if !nonempty { state.paragraphActive = false }
            else if !state.indentedCode { state.paragraphActive = true }
            if let fence = state.active, fence.listMinimum > 0 {
                var prefix = offset
                for _ in 0..<fence.quoteDepth {
                    var padding = 0
                    while prefix < end && text.character(at: prefix) == 32 && padding < 3 {
                        prefix += 1; padding += 1
                    }
                    if prefix < end && text.character(at: prefix) == 62 { prefix += 1 }
                    if prefix < end && [32, 9].contains(text.character(at: prefix)) { prefix += 1 }
                }
                var containerIndent = 0
                while prefix < end && [32, 9].contains(text.character(at: prefix)) {
                    containerIndent += text.character(at: prefix) == 9 ? 4 - containerIndent % 4 : 1
                    prefix += 1
                }
                if prefix < end && ![10, 13].contains(text.character(at: prefix))
                    && containerIndent < fence.listMinimum {
                    if fence.hasContent { state.finalGhostQuote = fence.quoteDepth }
                    state.active = nil
                }
            }
            if let fence = state.active, fence.quoteDepth > 0 && depth < fence.quoteDepth {
                // A quote container ends before an unquoted line, including its fence.
                if fence.hasContent { state.finalGhostQuote = fence.quoteDepth }
                state.active = nil
            }
            let previousFence = state.active
            if state.active == nil, let candidate = listOpeningCursor { cursor = candidate }
            if cursor < end && (text.character(at: cursor) == 96 || text.character(at: cursor) == 126)
                && (spaces <= 3 || depth > 0) {
                let delimiter = text.character(at: cursor)
                let markerStart = cursor
                while cursor < end && text.character(at: cursor) == delimiter { cursor += 1 }
                let count = cursor - markerStart
                if count >= 3 {
                    if let fence = state.active {
                        var suffix = cursor
                        while suffix < end && [32, 9, 10, 13].contains(text.character(at: suffix)) { suffix += 1 }
                        if delimiter == fence.delimiter && count >= fence.count
                            && depth == fence.quoteDepth && suffix == end { state.active = nil }
                    } else {
                        var valid = true
                        if delimiter == 96 {
                            while cursor < end {
                                if text.character(at: cursor) == 96 { valid = false; break }
                                cursor += 1
                            }
                        }
                        if valid {
                            state.active = (delimiter, count, depth, state.listIndent ?? 0, false)
                            state.paragraphActive = false
                        }
                    }
                }
            }
            if let previousFence, state.active != nil {
                state.active = (previousFence.delimiter, previousFence.count, previousFence.quoteDepth,
                          previousFence.listMinimum, true)
            }
            offset = NSMaxRange(lineRange)
            if offset <= caret && offset - (cache.checkpoints.last?.offset ?? 0) >= 16_384 {
                cache.checkpoints.append(.init(offset: offset, state: state))
            }
        }
        return Context(inFence: state.rawFence != nil || state.active?.hasContent == true || state.finalGhostQuote != nil,
                       quotedFence: (state.finalGhostQuote ?? (state.active?.hasContent == true ? state.active?.quoteDepth : nil) ?? 0) > 0,
                       indentedCode: state.indentedCode,
                       quotedIndentedCode: state.active?.hasContent != true && state.finalGhostQuote == nil && state.quotedIndentedCode)
    }
}
