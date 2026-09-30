import Foundation

/// Commands describe source edits; the AppKit adapter owns applying them and undo.
public enum EditorCommand: Sendable {
    case replace(String)
    case bold
    case italic
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
