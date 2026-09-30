import Foundation

/// Pure source behavior shared by fixtures and the native text adapter.
public enum EditorBehavior {
    public static func edit(_ command: EditorCommand, in source: String,
                            selection: NSRange) throws -> SourceEdit? {
        let selectedRange = try checkedRange(selection, in: source)
        let selected = String(source[selectedRange])
        switch command {
        case .replace(let text):
            return replacing(selection, with: text)
        case .bold:
            return wrapping(selected, in: selection, before: "**", after: "**")
        case .italic:
            return wrapping(selected, in: selection, before: "*", after: "*")
        case .link(let clipboard):
            let label = escapeLinkText(selected.isEmpty ? "link text" : selected)
            let destination = normalizedLinkURL(clipboard) ?? "https://"
            let replacement = "[\(label)](\(escapeLinkDestination(destination)))"
            if selected.isEmpty {
                return replacing(selection, with: replacement, offset: 1, length: label.utf16.count)
            }
            if normalizedLinkURL(clipboard) == nil {
                return replacing(selection, with: replacement, offset: label.utf16.count + 3,
                                 length: escapeLinkDestination(destination).utf16.count)
            }
            return replacing(selection, with: replacement)
        case .paste(let clipboard):
            guard !clipboard.isEmpty else { return nil }
            if !selected.isEmpty, let url = normalizedLinkURL(clipboard),
               !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let content = selected.trimmingCharacters(in: .whitespacesAndNewlines)
                let leading = String(selected.prefix(while: { $0.isWhitespace }))
                let trailing = String(selected.reversed().prefix(while: { $0.isWhitespace }).reversed())
                return replacing(selection, with: leading + "[" + escapeLinkText(content)
                                 + "](" + escapeLinkDestination(url) + ")" + trailing)
            }
            return replacing(selection, with: clipboard)
        case .insertReturn(let soft):
            if soft { return replacing(selection, with: "\n") }
            return smartReturn(in: source, selection: selection)
        case .deleteParagraphBreak:
            guard selection.length == 0, selection.location >= 2 else { return nil }
            let range = NSRange(location: selection.location - 2, length: 2)
            guard let swiftRange = Range(range, in: source), source[swiftRange] == "\n\n" else { return nil }
            return replacing(range, with: "")
        }
    }

    public static func normalizePlainText(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    public static func wordCount(_ text: String) -> Int {
        matches(#"[\p{L}\p{N}]+(?:['-][\p{L}\p{N}]+)*"#, in: text).count
    }

    public static func suggestedFilename(_ text: String) -> String {
        var name = String(text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)[0])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        name = name.replacingOccurrences(of: #"[/\x00-\x1f\x7f]"#, with: "-", options: .regularExpression)
        // Limit by UTF-16 units like Qt, while keeping an intact grapheme cluster.
        var limited = ""
        for character in name {
            let candidate = String(character)
            if limited.utf16.count + candidate.utf16.count > 120 { break }
            limited += candidate
        }
        name = limited.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "." || name == ".." { name = "Untitled" }
        if !name.lowercased().hasSuffix(".md") { name += ".md" }
        return name
    }

    /// Clipboard link recognition matches the current editor's allowed schemes.
    public static func normalizedLinkURL(_ text: String) -> String? {
        let candidateLine = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).first ?? ""
        var candidate = candidateLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.lowercased().hasPrefix("www.") { candidate = "https://" + candidate }
        guard candidate.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) != nil,
              let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased() else { return nil }
        if ["http", "https", "ftp"].contains(scheme) {
            guard let host = components.host, !host.isEmpty else { return nil }
        } else if scheme != "mailto" {
            return nil
        }
        return components.url?.absoluteString
    }

    /// Opening is deliberately narrower than clipboard recognition (FTP is not opened).
    public static func canOpenLink(_ url: URL) -> Bool {
        ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "")
    }

    static func checkedRange(_ range: NSRange, in source: String) throws -> Range<String.Index> {
        let count = source.utf16.count
        guard range.location != NSNotFound, range.location >= 0, range.length >= 0,
              range.location <= count, range.length <= count - range.location,
              let swiftRange = Range(range, in: source) else { throw EditorError.invalidRange }
        // AppKit offsets must not split a composed character or CRLF pair.
        let nsSource = source as NSString
        for offset in [range.location, NSMaxRange(range)] where offset < count {
            guard nsSource.rangeOfComposedCharacterSequence(at: offset).location == offset else {
                throw EditorError.invalidRange
            }
        }
        return swiftRange
    }

    static func matches(_ pattern: String, in source: String) -> [NSTextCheckingResult] {
        // Patterns are internal constants. An invalid pattern is a programmer error.
        let regex = try! NSRegularExpression(pattern: pattern)
        return regex.matches(in: source, range: NSRange(location: 0, length: source.utf16.count))
    }

    private static func replacing(_ range: NSRange, with text: String,
                                  offset: Int? = nil, length: Int = 0) -> SourceEdit {
        let replacement = normalizePlainText(text)
        return SourceEdit(range: range, replacement: replacement,
                          selection: NSRange(location: range.location + (offset ?? replacement.utf16.count),
                                             length: length))
    }

    private static func wrapping(_ selected: String, in range: NSRange,
                                 before: String, after: String) -> SourceEdit {
        replacing(range, with: before + selected + after,
                  offset: before.utf16.count, length: selected.utf16.count)
    }

    // Return is computed at the replacement start, independent of selection direction.
    private static func smartReturn(in source: String, selection: NSRange) -> SourceEdit {
        let nsSource = source as NSString
        let before = nsSource.substring(to: selection.location)
        let lineStart = (before as NSString).range(of: "\n", options: .backwards).location
        let start = lineStart == NSNotFound ? 0 : lineStart + 1
        let line = nsSource.substring(with: NSRange(location: start, length: selection.location - start))
        let codeContext = MarkdownSyntax.runs(in: source).first {
            $0.isCodeBlock && $0.range.location <= selection.location && NSMaxRange($0.range) >= selection.location
        }
        let code = MarkdownBlocks.parse(before).contains {
            $0.kind == .fencedCode && $0.markers.count == 1 && NSMaxRange($0.range) == before.utf16.count
        } || codeContext != nil
        let indentedContinuation = (line.hasPrefix("    ") || line.hasPrefix("\t"))
            && matches(#"^[ \t]*(?:[-+*]|[0-9]+[.)])[ \t]+"#, in: line).isEmpty
        if code || indentedContinuation {
            let inQuote = codeContext?.presentation?.components.contains { $0.kind == .blockQuote } ?? false
            let quote = inQuote ? matches(#"^[ \t]*(?:>[ \t]?)+"#, in: line).first : nil
            let prefix = quote.map { (line as NSString).substring(with: $0.range) } ?? ""
            let content = (line as NSString).substring(from: prefix.utf16.count)
            let indent = matches(#"^[ \t]*"#, in: content).first.map { (content as NSString).substring(with: $0.range) } ?? ""
            return replacing(selection, with: "\n" + prefix + indent)
        }
        let quote = matches(#"^[ \t]*(?:>[ \t]?)+"#, in: line).first
        let quotePrefix = quote.map { (line as NSString).substring(with: $0.range) } ?? ""
        let contentLine = (line as NSString).substring(from: quotePrefix.utf16.count)
        if !quotePrefix.isEmpty && contentLine.trimmingCharacters(in: .whitespaces).isEmpty {
            return replacing(NSRange(location: start, length: NSMaxRange(selection) - start), with: "\n")
        }
        if let match = matches(#"^([ \t]*)([-+*]|[0-9]+[.)])[ \t]+(?:\[([ xX])\][ \t]+)?(.*)$"#, in: contentLine).first {
            let nsLine = contentLine as NSString
            let indent = nsLine.substring(with: match.range(at: 1))
            var marker = nsLine.substring(with: match.range(at: 2))
            let content = nsLine.substring(with: match.range(at: 4))
            if content.trimmingCharacters(in: .whitespaces).isEmpty {
                // Unlike the Qt handler, also replace a nonempty selection on list exit.
                return replacing(NSRange(location: start,
                                          length: NSMaxRange(selection) - start),
                                 with: quotePrefix.isEmpty ? "\n" : quotePrefix + "\n" + quotePrefix)
            }
            if marker.first?.isNumber == true,
               let number = Int(marker.dropLast()), number < Int.max {
                marker = "\(number + 1)\(marker.suffix(1))"
            }
            let task = match.range(at: 3).location != NSNotFound ? "[ ] " : ""
            return replacing(selection, with: "\n" + quotePrefix + indent + marker + " " + task)
        }
        return replacing(selection, with: "\n" + quotePrefix)
    }

    private static func escapeLinkText(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }

    private static func escapeLinkDestination(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "(", with: "\\(")
            .replacingOccurrences(of: ")", with: "\\)")
    }
}
