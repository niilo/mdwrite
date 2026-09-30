import Foundation

enum MarkdownFormatting {
    static func edit(_ format: MarkdownFormat, in source: String, selection: NSRange) throws -> SourceEdit {
        let range = try EditorBehavior.checkedRange(selection, in: source)
        let selected = String(source[range])
        func inline(_ before: String, _ after: String, placeholder: String = "text") -> SourceEdit {
            let text = selected.isEmpty ? placeholder : selected
            return replacement(selection, before + text + after, offset: before.utf16.count, length: text.utf16.count)
        }
        switch format {
        case .bold: return inline("**", "**")
        case .italic: return inline("*", "*")
        case .boldItalic: return inline("***", "***")
        case .strikethrough: return inline("~~", "~~")
        case .inlineCode:
            let text = selected.isEmpty ? "code" : selected
            let delimiter = String(repeating: "`", count: longestBacktickRun(text) + 1)
            let pad = text.hasPrefix("`") || text.hasSuffix("`")
                || (text.hasPrefix(" ") && text.hasSuffix(" ") && !text.allSatisfy { $0 == " " }) ? " " : ""
            return replacement(selection, delimiter + pad + text + pad + delimiter,
                               offset: delimiter.utf16.count + pad.utf16.count, length: text.utf16.count)
        case .link:
            return try EditorBehavior.edit(.link(clipboard: ""), in: source, selection: selection)!
        case .image:
            let label = EditorBehavior.escapeLinkText(selected.isEmpty ? "alt text" : selected)
            let text = "![\(label)](image.png)"
            return replacement(selection, text, offset: selected.isEmpty ? 2 : label.utf16.count + 4,
                               length: selected.isEmpty ? label.utf16.count : 9)
        case .referenceLink, .referenceImage:
            let prefix = format == .referenceImage ? "![" : "["
            let label = EditorBehavior.escapeLinkText(selected.isEmpty
                ? (format == .referenceImage ? "alt text" : "link text") : selected)
            var identifier = "reference"
            var number = 1
            while source.range(of: "[\(identifier)]", options: .caseInsensitive) != nil {
                number += 1
                identifier = "reference\(number)"
            }
            let destination = format == .referenceImage ? "image.png" : "https://example.com"
            return appendingDefinition(in: source, selection: selection,
                marker: prefix + label + "][\(identifier)]", definition: "[\(identifier)]: " + destination,
                offset: identifier.utf16.count + 4, length: destination.utf16.count)
        case .autolink:
            let url = EditorBehavior.normalizedLinkURL(selected) ?? "https://example.com"
            return replacement(selection, "<\(url)>", offset: 1, length: url.utf16.count)
        case .hardBreak: return replacement(selection, "  \n")
        case .escape:
            let text = selected.isEmpty ? "*" : selected
            let punctuation = CharacterSet(charactersIn: "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")
            let escaped = text.unicodeScalars.map { punctuation.contains($0) ? "\\" + String($0) : String($0) }.joined()
            return replacement(selection, escaped, offset: 0, length: escaped.utf16.count)
        case .entity: return replacement(selection, "&amp;", offset: 0, length: 5)
        case .comment:
            let text = selected.isEmpty ? "comment" : selected
            return replacement(selection, "<!-- " + text + " -->", offset: 5, length: text.utf16.count)
        default: break
        }

        var linesRange = fullLines(in: source, selection: selection)
        if [.paragraph, .heading1, .heading2, .heading3, .heading4, .heading5, .heading6,
            .setextHeading1, .setextHeading2].contains(format) {
            // A caret on a Setext title converts the underline together with the title.
            let next = NSMaxRange(linesRange) + 1
            if next < source.utf16.count {
                let nextRange = fullLines(in: source, selection: NSRange(location: next, length: 0))
                if matches(#"^[ \t]*(?:=+|-+)[ \t]*$"#, (source as NSString).substring(with: nextRange)) {
                    linesRange.length = NSMaxRange(nextRange) - linesRange.location
                }
            }
        }
        let content = (source as NSString).substring(with: linesRange)
        var lines = content.components(separatedBy: "\n")
        func lineEdit(contentOffset: Int = 0, selectedLength: Int? = nil,
                      _ transform: (String, Int) -> String) -> SourceEdit {
            let text = lines.enumerated().map { transform($0.element, $0.offset) }.joined(separator: "\n")
            return replacement(linesRange, text, offset: contentOffset,
                               length: selectedLength ?? max(0, text.utf16.count - contentOffset))
        }
        switch format {
        case .paragraph, .heading1, .heading2, .heading3, .heading4, .heading5, .heading6,
             .setextHeading1, .setextHeading2:
            // Replace existing Setext underlines when the heading's lines are selected.
            if lines.count > 1 {
                lines = lines.enumerated().filter { index, line in
                    index == 0 || !matches(#"^[ \t]*(?:=+|-+)[ \t]*$"#, line)
                }.map(\.element)
            }
            if format == .setextHeading1 || format == .setextHeading2 {
                let marker = format == .setextHeading1 ? "=" : "-"
                let firstTitle = unprefixed(lines[0]).isEmpty ? "Heading" : unprefixed(lines[0])
                return lineEdit(selectedLength: lines.count == 1 ? firstTitle.utf16.count : nil) { line, _ in
                    let text = unprefixed(line).isEmpty ? "Heading" : unprefixed(line)
                    return text + "\n" + String(repeating: marker, count: max(3, text.count))
                }
            }
            let level = format == .paragraph ? 0 : format.rawValue - MarkdownFormat.heading1.rawValue + 1
            return lineEdit(contentOffset: level == 0 ? 0 : level + 1) { line, _ in
                let text = unprefixed(line)
                return level == 0 ? text : String(repeating: "#", count: level) + " " + (text.isEmpty ? "Heading" : text)
            }
        case .unorderedList, .orderedList, .taskList, .completedTask:
            let indentLength = String(lines[0].prefix(while: { $0 == " " || $0 == "\t" })).utf16.count
            let markerLength = format == .orderedList ? 3 : format == .unorderedList ? 2 : 6
            return lineEdit(contentOffset: indentLength + markerLength) { line, index in
                let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
                let text = unprefixed(String(line.dropFirst(indent.count)))
                let marker: String
                switch format {
                case .orderedList: marker = "\(index + 1). "
                case .taskList: marker = "- [ ] "
                case .completedTask: marker = "- [x] "
                default: marker = "- "
                }
                return indent + marker + text
            }
        case .indent: return lineEdit(contentOffset: 4) { line, _ in "    " + line }
        case .outdent:
            return lineEdit { line, _ in
                if line.hasPrefix("\t") { return String(line.dropFirst()) }
                return String(line.dropFirst(line.prefix(4).prefix(while: { $0 == " " }).count))
            }
        case .blockquote: return lineEdit(contentOffset: 2) { line, _ in "> " + line }
        case .indentedCode:
            let text = content.isEmpty ? "    code" : lines.map { "    " + $0 }.joined(separator: "\n")
            return block(in: source, range: linesRange, text: text, selectedOffset: 4, selectedLength: text.utf16.count - 4)
        case .fencedCode:
            let text = content.isEmpty ? "code" : content
            let fence = String(repeating: "`", count: max(3, longestBacktickRun(text) + 1))
            return block(in: source, range: linesRange, text: fence + "\n" + text + "\n" + fence,
                         selectedOffset: fence.utf16.count + 1, selectedLength: text.utf16.count)
        case .horizontalRule:
            return insertBlock("---", in: source, selection: selection)
        case .table:
            let header = selected.isEmpty ? "Column 1" : selected.replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "|", with: "\\|")
            return insertBlock("| \(header) | Column 2 |\n| --- | --- |\n| Cell | Cell |", in: source, selection: selection,
                               selectedOffset: 2, selectedLength: header.utf16.count)
        case .linkDefinition:
            let destination = EditorBehavior.normalizedLinkURL(selected) ?? "https://example.com"
            return insertBlock("[reference]: \(EditorBehavior.escapeLinkDestination(destination))", in: source,
                               selection: selection, selectedOffset: 1, selectedLength: 9)
        case .footnote:
            // Keep definitions outside the paragraph and avoid colliding with existing labels.
            var number = 1
            while source.contains("[^note\(number)]") { number += 1 }
            let label = "[^note\(number)]"
            let text = (selected.isEmpty ? "Footnote text" : selected).replacingOccurrences(of: "\n", with: "\n    ")
            return appendingDefinition(in: source, selection: selection, marker: label,
                                       definition: label + ": " + text, offset: label.utf16.count + 2,
                                       length: text.utf16.count)
        case .html:
            let text = selected.isEmpty ? "HTML content" : selected
            return insertBlock("<div>\n\(text)\n</div>", in: source, selection: selection,
                               selectedOffset: 6, selectedLength: text.utf16.count)
        default: preconditionFailure("Inline format was not handled")
        }
    }

    private static func replacement(_ range: NSRange, _ text: String, offset: Int? = nil, length: Int = 0) -> SourceEdit {
        SourceEdit(range: range, replacement: text,
                   selection: NSRange(location: range.location + (offset ?? text.utf16.count), length: length))
    }

    private static func appendingDefinition(in source: String, selection: NSRange, marker: String,
                                            definition: String, offset: Int, length: Int) -> SourceEdit {
        let ns = source as NSString
        let tail = ns.substring(from: NSMaxRange(selection))
        let preceding = ns.substring(to: selection.location) + marker + tail
        let gap = preceding.hasSuffix("\n\n") ? "" : preceding.hasSuffix("\n") ? "\n" : "\n\n"
        return replacement(NSRange(location: selection.location, length: ns.length - selection.location),
                           marker + tail + gap + definition,
                           offset: marker.utf16.count + tail.utf16.count + gap.utf16.count + offset, length: length)
    }

    private static func fullLines(in source: String, selection: NSRange) -> NSRange {
        let ns = source as NSString
        // A selection ending at the next line's start belongs only to the preceding lines.
        let last = selection.length > 0 ? NSMaxRange(selection) - 1 : selection.location
        let start = ns.lineRange(for: NSRange(location: selection.location, length: 0)).location
        let end = NSMaxRange(ns.lineRange(for: NSRange(location: last, length: 0)))
        var length = end - start
        while length > 0 && [10, 13].contains(ns.character(at: start + length - 1)) { length -= 1 }
        return NSRange(location: start, length: length)
    }

    private static func insertBlock(_ text: String, in source: String, selection: NSRange,
                                    selectedOffset: Int? = nil, selectedLength: Int = 0) -> SourceEdit {
        block(in: source, range: selection, text: text, selectedOffset: selectedOffset, selectedLength: selectedLength)
    }

    private static func block(in source: String, range: NSRange, text: String,
                              selectedOffset: Int?, selectedLength: Int) -> SourceEdit {
        let ns = source as NSString
        let before = ns.substring(to: range.location)
        let after = ns.substring(from: NSMaxRange(range))
        let leading = before.isEmpty || before.hasSuffix("\n\n") ? "" : before.hasSuffix("\n") ? "\n" : "\n\n"
        let trailing = after.isEmpty || after.hasPrefix("\n\n") ? "" : after.hasPrefix("\n") ? "\n" : "\n\n"
        return replacement(range, leading + text + trailing,
                           offset: leading.utf16.count + (selectedOffset ?? text.utf16.count), length: selectedLength)
    }

    private static func unprefixed(_ text: String) -> String {
        text.replacingOccurrences(of: #"^(?:#{1,6}[ \t]+|(?:>[ \t]*)+|(?:[-+*]|[0-9]+[.)])[ \t]+(?:\[[ xX]\][ \t]+)?)"#,
                                  with: "", options: .regularExpression)
    }

    private static func longestBacktickRun(_ text: String) -> Int {
        EditorBehavior.matches(#"`+"#, in: text).map(\.range.length).max() ?? 0
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}
