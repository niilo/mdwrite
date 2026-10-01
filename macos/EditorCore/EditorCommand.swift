import Foundation

/// Commands describe source edits; the AppKit adapter owns applying them and undo.
public enum EditorCommand: Sendable {
    case replace(String)
    case bold
    case italic
    case format(MarkdownFormat)
    case link(clipboard: String)
    case paste(String)
    case insertReturn(soft: Bool)
    case deleteParagraphBreak
}

/// Ranges are UTF-16 offsets into the original source and the resulting source.
public struct SourceEdit: Equatable, Sendable {
    public let range: NSRange
    public let replacement: String
    public let selection: NSRange

    public init(range: NSRange, replacement: String, selection: NSRange) {
        self.range = range
        self.replacement = replacement
        self.selection = selection
    }

    /// Validate the native mutation without allocating a complete replacement buffer.
    /// Only grapheme clusters touching the splice need reconstruction. Regional
    /// indicators are extended because insertion can change pairing down a run.
    public func validate(in source: NSString) throws {
        let count = source.length
        func bounded(_ value: NSRange, count: Int) throws {
            guard value.location != NSNotFound, value.location >= 0, value.length >= 0,
                  value.location <= count, value.length <= count - value.location else {
                throw EditorError.invalidRange
            }
        }
        func boundary(_ offset: Int, in text: NSString) throws {
            if offset < text.length,
               EditorBehavior.composedCharacterRange(at: offset, in: text).location != offset {
                throw EditorError.invalidRange
            }
        }
        try bounded(range, count: count)
        try boundary(range.location, in: source)
        try boundary(NSMaxRange(range), in: source)
        let replacementLength = (replacement as NSString).length
        guard replacementLength <= Int.max - (count - range.length) else { throw EditorError.invalidRange }
        try bounded(selection, count: count - range.length + replacementLength)
        let left = range.location == 0 ? 0
            : EditorBehavior.composedCharacterRange(at: range.location - 1, in: source).location
        var right = NSMaxRange(range)
        if right < count {
            right = NSMaxRange(EditorBehavior.composedCharacterRange(at: right, in: source))
            // Surrogate pair D83C DDE6...DDFF encodes a regional indicator.
            while right + 1 < count && source.character(at: right) == 0xD83C
                && (0xDDE6...0xDDFF).contains(source.character(at: right + 1)) {
                right += 2
            }
        }
        let joined = (source.substring(with: NSRange(location: left, length: range.location - left))
            + replacement + source.substring(with: NSRange(location: NSMaxRange(range),
                                                            length: right - NSMaxRange(range)))) as NSString
        let delta = replacementLength - range.length
        for offset in [selection.location, NSMaxRange(selection)] {
            if offset >= left && offset <= right + delta {
                try boundary(offset - left, in: joined)
            } else {
                try boundary(offset < left ? offset : offset - delta, in: source)
            }
        }
    }

    public func applying(to source: String) throws -> String {
        let range = try EditorBehavior.checkedRange(range, in: source)
        let result = source.replacingCharacters(in: range, with: replacement)
        _ = try EditorBehavior.checkedRange(selection, in: result)
        return result
    }
}

public enum EditorError: Error, Equatable {
    case invalidRange
}
