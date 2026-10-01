import AppKit
import EditorCore

@MainActor
enum MarkdownStyler {
    private static var regexCache: [String: NSRegularExpression] = [:]
    static func apply(to storage: NSTextStorage, fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        let source = storage.string
        let text = source as NSString
        let whole = NSRange(location: 0, length: text.length)
        let font = NSFont(name: "iAWriterMonoS-Regular", size: fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = fontSize * 0.25
        // Explicit newlines determine paragraph gaps. Enter never inserts a gap for styling.
        paragraph.paragraphSpacing = 0
        let base: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.textColor, .paragraphStyle: paragraph
        ]
        let runs = MarkdownSyntax.runs(in: source)
        let fences = MarkdownBlocks.parse(source).filter { $0.kind == .fencedCode }
        var codeRanges = fences.map(\.range)
        for run in runs where run.isCodeBlock { codeRanges.append(text.paragraphRange(for: run.range)) }
        func isCode(_ range: NSRange) -> Bool { codeRanges.contains { NSIntersectionRange($0, range).length > 0 } }
        let codeFont = NSFont.monospacedSystemFont(ofSize: fontSize * 0.9, weight: .regular)
        let codeColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.95, alpha: 1)
        }
        let tableColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 0.14, alpha: 1) : NSColor(white: 0.97, alpha: 1)
        }
        let headingScales: [CGFloat] = [1.8, 1.5, 1.3, 1.18, 1.1, 1.04]
        var headingLines: Set<Int> = []
        var tableHeaders: Set<Int> = []
        var nonRuleLines: Set<Int> = []
        func dim(_ range: NSRange) {
            storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: range)
        }
        storage.beginEditing()
        defer { storage.endEditing() }
        storage.setAttributes(base, range: whole)

        for run in runs {
            let line = text.paragraphRange(for: run.range)
            let kinds = run.presentation?.components.map(\.kind) ?? []
            let quoteDepth = kinds.filter { $0 == .blockQuote }.count
            let listDepth = kinds.filter { $0 == .orderedList || $0 == .unorderedList }.count
            let style = paragraph.mutableCopy() as! NSMutableParagraphStyle
            style.firstLineHeadIndent = CGFloat(quoteDepth) * 24 + CGFloat(max(0, listDepth - 1)) * 20
            style.headIndent = CGFloat(quoteDepth) * 24 + CGFloat(listDepth) * 20
            storage.addAttribute(.paragraphStyle, value: style, range: line)
            var runFont = font
            if quoteDepth > 0 {
                runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .italicFontMask)
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: line)
                storage.addAttribute(.mdwriteQuoteDepth, value: quoteDepth, range: line)
            }
            for kind in kinds {
                if case let .header(level) = kind {
                    runFont = NSFontManager.shared.convert(font, toSize: fontSize * headingScales[min(6, max(1, level)) - 1])
                    runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .boldFontMask)
                    style.paragraphSpacingBefore = fontSize * 0.5
                    style.paragraphSpacing = fontSize * 0.25
                    storage.addAttribute(.paragraphStyle, value: style, range: line)
                    headingLines.insert(line.location)
                }
                if kind == .tableHeaderRow {
                    runFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                    tableHeaders.insert(line.location)
                }
                if case .table = kind {
                    storage.addAttribute(.mdwriteTableBackground, value: tableColor, range: line)
                }
            }
            if run.inlineIntent.contains(.stronglyEmphasized) {
                runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .boldFontMask)
            }
            if run.inlineIntent.contains(.emphasized) {
                runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .italicFontMask)
            }
            storage.addAttribute(.font, value: runFont, range: run.range)
            if run.inlineIntent.contains(.strikethrough) {
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: run.range)
            }
            if run.link != nil || run.image != nil {
                storage.addAttributes([.foregroundColor: NSColor.linkColor,
                                       .underlineStyle: NSUnderlineStyle.single.rawValue], range: run.range)
            }
            if run.inlineIntent.contains(.code) {
                storage.addAttributes([.font: codeFont, .foregroundColor: NSColor.textColor,
                                       .backgroundColor: codeColor], range: run.range)
            }
            if run.inlineIntent.contains(.inlineHTML) || run.inlineIntent.contains(.blockHTML) {
                storage.addAttributes([.font: codeFont, .foregroundColor: NSColor.secondaryLabelColor], range: run.range)
            }
        }

        // Decorate source-only markers omitted from Foundation's rendered runs.
        for block in MarkdownBlocks.parse(source) where !isCode(block.range) {
            for marker in block.markers { dim(marker) }
        }
        for span in MarkdownSpans.inline(in: source) where !isCode(span.content) {
            let semantic = runs.contains {
                NSIntersectionRange($0.range, span.content).length > 0 &&
                    (!$0.inlineIntent.intersection([.emphasized, .stronglyEmphasized]).isEmpty || $0.link != nil || $0.image != nil)
            }
            if semantic { for marker in span.markers { dim(marker) } }
        }
        for location in headingLines {
            let line = text.paragraphRange(for: NSRange(location: location, length: 0))
            let next = NSMaxRange(line)
            if next < text.length {
                let underline = text.lineRange(for: NSRange(location: next, length: 0))
                if matches(#"^ {0,3}(?:=+|-+)[ \t]*$"#, in: text.substring(with: underline).trimmingCharacters(in: .newlines)).first != nil {
                    dim(underline)
                    nonRuleLines.insert(underline.location)
                }
            }
        }
        for location in tableHeaders {
            let header = text.lineRange(for: NSRange(location: location, length: 0))
            let next = NSMaxRange(header)
            if next < text.length {
                let delimiter = text.lineRange(for: NSRange(location: next, length: 0))
                dim(delimiter)
                storage.addAttribute(.mdwriteTableBackground, value: tableColor, range: delimiter)
                nonRuleLines.insert(delimiter.location)
            }
        }
        var offset = 0
        while offset < text.length {
            let lineRange = text.lineRange(for: NSRange(location: offset, length: 0))
            let line = text.substring(with: lineRange).trimmingCharacters(in: .newlines)
            if !isCode(lineRange) {
                func absolute(_ range: NSRange) -> NSRange { NSRange(location: offset + range.location, length: range.length) }
                if let quote = matches(#"^([ \t]*(?:>[ \t]?)+)"#, in: line).first {
                    dim(absolute(quote.range))
                    if storage.attribute(.mdwriteQuoteDepth, at: offset, effectiveRange: nil) == nil {
                        let depth = (line as NSString).substring(with: quote.range).filter { $0 == ">" }.count
                        let style = paragraph.mutableCopy() as! NSMutableParagraphStyle
                        style.firstLineHeadIndent = CGFloat(depth) * 24
                        style.headIndent = style.firstLineHeadIndent
                        storage.addAttributes([.paragraphStyle: style, .mdwriteQuoteDepth: depth], range: lineRange)
                    }
                }
                if let list = matches(#"^([ \t]*)([-+*]|[0-9]+[.)])[ \t]+(?:\[([ xX])\][ \t]+)?"#, in: line).first {
                    dim(absolute(list.range))
                    let existing = storage.attribute(.paragraphStyle, at: offset, effectiveRange: nil) as? NSParagraphStyle
                    if existing?.headIndent == 0 {
                        let style = paragraph.mutableCopy() as! NSMutableParagraphStyle
                        let indentation = (line as NSString).substring(with: list.range(at: 1))
                        style.firstLineHeadIndent = CGFloat(indentation.count / 2) * 20
                        style.headIndent = style.firstLineHeadIndent + 20
                        storage.addAttribute(.paragraphStyle, value: style, range: lineRange)
                    }
                    if list.range(at: 3).location != NSNotFound,
                       (line as NSString).substring(with: list.range(at: 3)).lowercased() == "x" {
                        let content = NSRange(location: offset + NSMaxRange(list.range), length: (line as NSString).length - NSMaxRange(list.range))
                        storage.addAttributes([.foregroundColor: NSColor.secondaryLabelColor,
                                               .strikethroughStyle: NSUnderlineStyle.single.rawValue], range: content)
                    }
                }
                if !nonRuleLines.contains(offset), matches(#"^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$"#, in: line).first != nil {
                    dim(lineRange)
                    storage.addAttributes([.mdwriteRule: true, .font: NSFontManager.shared.convert(font, toSize: fontSize * 0.65)], range: lineRange)
                }
                if let prefix = matches(#"^ {0,3}(?:>[ \t]?)+"#, in: line).first,
                   matches(#"^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$"#,
                           in: (line as NSString).substring(from: NSMaxRange(prefix.range))).first != nil {
                    dim(lineRange)
                    storage.addAttribute(.mdwriteRule, value: true, range: lineRange)
                }
                if storage.attribute(.mdwriteTableBackground, at: offset, effectiveRange: nil) != nil {
                    for pipe in matches(#"(?<!\\)\|"#, in: line) { dim(absolute(pipe.range)) }
                }
                if let definition = matches(#"^ {0,3}\[[^\]]+\]:[ \t]*"#, in: line).first { dim(absolute(definition.range)) }
                for url in matches(#"(?:https?://|mailto:)[^\s<>]+"#, in: line) {
                    let range = absolute(url.range)
                    if !runs.contains(where: { $0.inlineIntent.contains(.code) && NSIntersectionRange($0.range, range).length > 0 }) {
                        storage.addAttributes([.foregroundColor: NSColor.linkColor,
                                               .underlineStyle: NSUnderlineStyle.single.rawValue], range: range)
                    }
                }
                if let hardBreak = matches(#"(?: {2,}|\\)$"#, in: line).first {
                    storage.addAttribute(.backgroundColor, value: NSColor.separatorColor.withAlphaComponent(0.15), range: absolute(hardBreak.range))
                }
                for note in matches(#"\[\^[^\]]+\]"#, in: line) {
                    storage.addAttributes([.foregroundColor: NSColor.linkColor,
                                           .font: NSFontManager.shared.convert(font, toSize: fontSize * 0.85)], range: absolute(note.range))
                }
                for escape in matches(##"\\[!"#$%&'()*+,\-./:;<=>?@\[\]\\^_`{|}~]|&(?:#[0-9]+|#x[0-9a-fA-F]+|[A-Za-z][A-Za-z0-9]+);"##, in: line) {
                    dim(absolute(escape.range))
                }
            }
            offset = NSMaxRange(lineRange)
        }

        let codeParagraph = paragraph.mutableCopy() as! NSMutableParagraphStyle
        codeParagraph.lineSpacing = fontSize * 0.2
        for range in codeRanges {
            let existing = storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            let style = codeParagraph.mutableCopy() as! NSMutableParagraphStyle
            style.headIndent = existing?.headIndent ?? 0
            style.firstLineHeadIndent = existing?.firstLineHeadIndent ?? 0
            storage.addAttributes([.font: codeFont, .foregroundColor: NSColor.textColor,
                .backgroundColor: codeColor, .mdwriteCodeBackground: codeColor,
                .paragraphStyle: style, .underlineStyle: 0, .strikethroughStyle: 0], range: range)
        }
        for fence in fences {
            storage.addAttribute(.mdwriteCodeContinues, value: fence.markers.count == 1, range: fence.range)
            for marker in fence.markers { dim(marker) }
        }
        return base
    }

    static func baseAttributes(fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        let font = NSFont(name: "iAWriterMonoS-Regular", size: fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = fontSize * 0.25
        return [.font: font, .foregroundColor: NSColor.textColor, .paragraphStyle: paragraph]
    }

    static func attributes(for style: MarkdownStyle, fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        var font = style.font.family == .code
            ? NSFont.monospacedSystemFont(ofSize: style.font.size * fontSize, weight: .regular)
            : (NSFont(name: "iAWriterMonoS-Regular", size: style.font.size * fontSize)
                ?? NSFont.monospacedSystemFont(ofSize: style.font.size * fontSize, weight: .regular))
        if style.font.traits & 1 != 0 { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        if style.font.traits & 2 != 0 { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = style.paragraph.lineSpacing * fontSize
        paragraph.paragraphSpacing = style.paragraph.paragraphSpacing * fontSize
        paragraph.paragraphSpacingBefore = style.paragraph.paragraphSpacingBefore * fontSize
        paragraph.headIndent = style.paragraph.headIndent
        paragraph.firstLineHeadIndent = style.paragraph.firstLineHeadIndent
        var result: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color(style.color), .paragraphStyle: paragraph]
        if let value = style.background { result[.backgroundColor] = color(value) }
        if let value = style.tableBackground { result[.mdwriteTableBackground] = color(value) }
        if let value = style.codeBackground { result[.mdwriteCodeBackground] = color(value) }
        if let value = style.quoteDepth { result[.mdwriteQuoteDepth] = value }
        if let value = style.rule { result[.mdwriteRule] = value }
        if let value = style.codeContinues { result[.mdwriteCodeContinues] = value }
        if let value = style.underline { result[.underlineStyle] = value }
        if let value = style.strikethrough { result[.strikethroughStyle] = value }
        return result
    }

    private static let codeColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.95, alpha: 1)
    }
    private static let tableColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.14, alpha: 1) : NSColor(white: 0.97, alpha: 1)
    }
    private static func color(_ color: StyleColor) -> NSColor {
        switch color {
        case .text: return .textColor
        case .secondary: return .secondaryLabelColor
        case .tertiary: return .tertiaryLabelColor
        case .link: return .linkColor
        case .code: return codeColor
        case .table: return tableColor
        case .hardBreak: return NSColor.separatorColor.withAlphaComponent(0.15)
        }
    }

    static let ownedKeys: [NSAttributedString.Key] = [
        .font, .foregroundColor, .paragraphStyle, .backgroundColor, .underlineStyle, .strikethroughStyle,
        .mdwriteTableBackground, .mdwriteCodeBackground, .mdwriteQuoteDepth, .mdwriteRule, .mdwriteCodeContinues
    ]
    static func applyChanged(_ desired: [NSAttributedString.Key: Any], to storage: NSTextStorage, range: NSRange) {
        var changes: [(NSRange, [NSAttributedString.Key: Any], [NSAttributedString.Key])] = []
        let text = storage.string as NSString
        storage.enumerateAttributes(in: range) { current, part, _ in
            var additions: [NSAttributedString.Key: Any] = [:]
            var removals: [NSAttributedString.Key] = []
            for key in ownedKeys {
                if let wanted = desired[key] as? NSObject {
                    if (current[key] as? NSObject)?.isEqual(wanted) != true { additions[key] = wanted }
                } else if current[key] != nil { removals.append(key) }
            }
            // Paragraph geometry belongs to the complete paragraph even when
            // font/color differences divide it into several canonical runs.
            if let paragraph = additions.removeValue(forKey: .paragraphStyle) {
                changes.append((text.paragraphRange(for: part), [.paragraphStyle: paragraph], []))
            }
            if !additions.isEmpty || !removals.isEmpty { changes.append((part, additions, removals)) }
        }
        for (part, additions, removals) in changes {
            for key in removals { storage.removeAttribute(key, range: part) }
            if !additions.isEmpty { storage.addAttributes(additions, range: part) }
        }
    }

    private static func matches(_ pattern: String, in source: String) -> [NSTextCheckingResult] {
        let regex: NSRegularExpression
        if let cached = regexCache[pattern] { regex = cached }
        else {
            regex = try! NSRegularExpression(pattern: pattern)
            regexCache[pattern] = regex
        }
        return regex.matches(in: source, range: NSRange(location: 0, length: source.utf16.count))
    }
}
