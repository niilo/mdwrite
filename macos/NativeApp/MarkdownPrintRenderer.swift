import AppKit
import EditorCore

@MainActor
enum MarkdownPrintRenderer {
    static func makeView(source: String, width: CGFloat) -> NSTextView {
        let normalFont = NSFont.systemFont(ofSize: 12)
        let codeFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let rendered = NSMutableAttributedString()
        let parsed = try? AttributedString(markdown: source, options: .init(
            interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible))
        var lastLeaf: Int?
        var lastRow: Int?
        var seenListItems: Set<Int> = []
        if let parsed {
            for run in parsed.runs {
                let kinds = run.presentationIntent?.components ?? []
                let leaf = kinds.first?.identity
                let row = kinds.first {
                    if case .tableRow = $0.kind { return true }
                    return $0.kind == .tableHeaderRow
                }?.identity
                let inline = run.inlinePresentationIntent ?? []
                if inline.contains(.blockHTML), rendered.length > 0, !rendered.string.hasSuffix("\n") {
                    rendered.append(NSAttributedString(string: "\n"))
                }
                if let leaf, leaf != lastLeaf, rendered.length > 0 {
                    let separator = row != nil && row == lastRow ? "\t" : "\n"
                    if separator == "\t" || !rendered.string.hasSuffix("\n") {
                        rendered.append(NSAttributedString(string: separator))
                    }
                }
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = 3
                paragraph.paragraphSpacing = 4
                var font = normalFont
                var foreground = NSColor.black
                var attributes: [NSAttributedString.Key: Any] = [:]
                let quoteDepth = kinds.filter { $0.kind == .blockQuote }.count
                let listDepth = kinds.filter { $0.kind == .unorderedList || $0.kind == .orderedList }.count
                paragraph.firstLineHeadIndent = CGFloat(quoteDepth * 18 + max(0, listDepth - 1) * 18)
                paragraph.headIndent = CGFloat(quoteDepth * 18 + listDepth * 18)
                if quoteDepth > 0 {
                    font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                    foreground = .darkGray
                    attributes[.mdwriteQuoteDepth] = quoteDepth
                }
                var code = false
                for component in kinds {
                    switch component.kind {
                    case let .header(level):
                        font = .systemFont(ofSize: 12 + CGFloat(7 - min(6, max(1, level))) * 2, weight: .semibold)
                    case .codeBlock:
                        code = true
                        font = codeFont
                        paragraph.paragraphSpacing = 0
                        attributes[.backgroundColor] = NSColor(white: 0.95, alpha: 1)
                        attributes[.mdwriteCodeBackground] = NSColor(white: 0.95, alpha: 1)
                    case .tableHeaderRow:
                        font = .systemFont(ofSize: 12, weight: .semibold)
                    case let .table(columns):
                        paragraph.tabStops = (1..<max(1, columns.count)).map {
                            NSTextTab(textAlignment: .left, location: max(200, width) * CGFloat($0) / CGFloat(columns.count))
                        }
                        attributes[.mdwriteTableBackground] = NSColor(white: 0.97, alpha: 1)
                    case .thematicBreak:
                        foreground = .lightGray
                        attributes[.mdwriteRule] = true
                    default: break
                    }
                }
                if !code {
                    if inline.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
                    if inline.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                    if inline.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                    if inline.contains(.code) {
                        font = codeFont
                        attributes[.backgroundColor] = NSColor(white: 0.95, alpha: 1)
                    }
                    if run.link != nil || run.imageURL != nil { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                    if inline.contains(.inlineHTML) || inline.contains(.blockHTML) {
                        font = codeFont
                        foreground = .darkGray
                    }
                }
                attributes[.font] = font
                attributes[.foregroundColor] = foreground
                attributes[.paragraphStyle] = paragraph
                var text = String(parsed.characters[run.range])
                if kinds.contains(where: { $0.kind == .thematicBreak }) { text = " " }
                if let item = kinds.first(where: {
                    if case .listItem = $0.kind { return true }
                    return false
                }), !seenListItems.contains(item.identity) {
                    let list = kinds.first { $0.kind == .orderedList || $0.kind == .unorderedList }
                    if text.hasPrefix("[x] ") || text.hasPrefix("[X] ") { text = "☑ " + text.dropFirst(4) }
                    else if text.hasPrefix("[ ] ") { text = "☐ " + text.dropFirst(4) }
                    else if list?.kind == .orderedList, case let .listItem(ordinal) = item.kind {
                        text = "\(ordinal). " + text
                    } else { text = "• " + text }
                    seenListItems.insert(item.identity)
                }
                rendered.append(NSAttributedString(string: text, attributes: attributes))
                lastLeaf = leaf
                lastRow = row
            }
        } else {
            rendered.append(NSAttributedString(string: source, attributes: [.font: normalFont, .foregroundColor: NSColor.black]))
        }
        let storage = NSTextStorage(attributedString: rendered)
        let manager = MarkdownLayoutManager()
        let container = NSTextContainer(size: NSSize(width: max(200, width), height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: max(200, width), height: 100), textContainer: container)
        view.isEditable = false
        view.isRichText = true
        view.backgroundColor = .white
        view.textContainerInset = .zero
        container.widthTracksTextView = true
        view.isVerticallyResizable = true
        manager.ensureLayout(for: container)
        let height = manager.usedRect(for: container).height
        view.setFrameSize(NSSize(width: view.frame.width, height: max(100, height + 20)))
        return view
    }
}
