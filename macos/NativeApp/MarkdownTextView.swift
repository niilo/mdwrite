import AppKit
import EditorCore

@MainActor
final class MarkdownTextView: NSTextView {
    var sourceDidChange: (() -> Void)?
    var onCommandError: ((Error) -> Void)?
    var writerFontSize: CGFloat = 20
    private var editedSourceRange: NSRange?
    private var pendingFullRestyle = false
    private var hadCodeFence = false

    override func paste(_ sender: Any?) {
        guard !hasMarkedText(), let text = NSPasteboard.general.string(forType: .string) else {
            super.paste(sender)
            return
        }
        apply(.paste(text))
    }

    override func insertNewline(_ sender: Any?) {
        guard !hasMarkedText() else { super.insertNewline(sender); return }
        apply(.insertReturn(soft: false))
    }

    override func insertLineBreak(_ sender: Any?) {
        guard !hasMarkedText() else { super.insertLineBreak(sender); return }
        apply(.insertReturn(soft: true))
    }

    override func deleteBackward(_ sender: Any?) {
        guard !hasMarkedText() else { super.deleteBackward(sender); return }
        if let edit = try? EditorBehavior.edit(.deleteParagraphBreak, in: string, selection: selectedRange()) {
            apply(edit, name: "Delete Paragraph Break")
        } else {
            super.deleteBackward(sender)
        }
    }

    @objc func makeBold(_ sender: Any?) { apply(.bold) }
    @objc func makeItalic(_ sender: Any?) { apply(.italic) }
    @objc func insertMarkdownLink(_ sender: Any?) {
        apply(.link(clipboard: NSPasteboard.general.string(forType: .string) ?? ""))
    }

    @objc func increaseTextSize(_ sender: Any?) { setWriterFontSize(writerFontSize + 2) }
    @objc func decreaseTextSize(_ sender: Any?) { setWriterFontSize(writerFontSize - 2) }
    @objc func resetTextSize(_ sender: Any?) { setWriterFontSize(20) }

    func setWriterFontSize(_ size: CGFloat) {
        writerFontSize = min(40, max(12, size))
        restyle()
    }

    func apply(_ command: EditorCommand) {
        guard !hasMarkedText() else { return }
        do {
            if let edit = try EditorBehavior.edit(command, in: string, selection: selectedRange()) {
                let name: String
                switch command {
                case .bold: name = "Bold"
                case .italic: name = "Italic"
                case .link: name = "Insert Link"
                case .paste: name = "Paste"
                default: name = "Edit"
                }
                apply(edit, name: name)
            }
        } catch {
            NSSound.beep()
            onCommandError?(error)
        }
    }

    func apply(_ edit: SourceEdit, name: String) {
        guard let textStorage else { return }
        do {
            _ = try edit.applying(to: string)
            guard shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
            undoManager?.beginUndoGrouping()
            textStorage.replaceCharacters(in: edit.range, with: edit.replacement)
            setSelectedRange(edit.selection)
            editedSourceRange = NSRange(location: edit.range.location, length: edit.replacement.utf16.count)
            didChangeText()
            editedSourceRange = nil
            undoManager?.setActionName(name)
            undoManager?.endUndoGrouping()
            scrollRangeToVisible(selectedRange())
        } catch {
            NSSound.beep()
            onCommandError?(error)
        }
    }

    override func didChangeText() {
        super.didChangeText()
        // System edits (including Replace All and undo) can affect distant ranges.
        // Only our source commands provide a trustworthy bounded changed range.
        if !hasMarkedText() { restyle(near: editedSourceRange) }
        sourceDidChange?()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    override func unmarkText() {
        super.unmarkText()
        restyle()
    }

    func restyle(near changedRange: NSRange? = nil) {
        guard let textStorage else { return }
        if hasMarkedText() {
            if changedRange == nil { pendingFullRestyle = true }
            return
        }
        let fullSource = string as NSString
        let blocks = MarkdownBlocks.parse(string)
        let codeBlocks = blocks.filter { $0.kind == .fencedCode }
        // Adding or removing a delimiter changes the interpretation of later lines.
        let needsFullRestyle = pendingFullRestyle || hadCodeFence || !codeBlocks.isEmpty
        hadCodeFence = !codeBlocks.isEmpty
        let affected: NSRange
        if let changedRange, !needsFullRestyle {
            let start = min(changedRange.location, fullSource.length)
            let length = min(changedRange.length, fullSource.length - start)
            affected = fullSource.lineRange(for: NSRange(location: start, length: length))
        } else {
            affected = NSRange(location: 0, length: fullSource.length)
        }
        pendingFullRestyle = false
        let source = fullSource.substring(with: affected)
        let whole = NSRange(location: 0, length: (source as NSString).length)
        func absolute(_ range: NSRange) -> NSRange {
            NSRange(location: affected.location + range.location, length: range.length)
        }
        let font = NSFont(name: "iAWriterMonoS-Regular", size: writerFontSize)
            ?? NSFont.monospacedSystemFont(ofSize: writerFontSize, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = writerFontSize * 0.35
        paragraph.paragraphSpacing = writerFontSize * 0.2
        let base: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.textColor, .paragraphStyle: paragraph
        ]
        // Display attributes must not register undo or alter the source text.
        textStorage.beginEditing()
        textStorage.setAttributes(base, range: affected)
        let headingScales: [CGFloat] = [1.8, 1.5, 1.3, 1.18, 1.1, 1.04]
        for block in blocks where NSIntersectionRange(block.range, affected).length > 0 {
            guard case let .heading(level) = block.kind else { continue }
            let headingFont = NSFontManager.shared.convert(font, toSize: writerFontSize * headingScales[level - 1])
            textStorage.addAttribute(.font, value: NSFontManager.shared.convert(headingFont, toHaveTrait: .boldFontMask), range: block.content)
            let headingParagraph = paragraph.mutableCopy() as! NSMutableParagraphStyle
            headingParagraph.paragraphSpacingBefore = writerFontSize * (level <= 2 ? 0.8 : 0.5)
            headingParagraph.paragraphSpacing = writerFontSize * 0.35
            textStorage.addAttribute(.paragraphStyle, value: headingParagraph, range: block.range)
            for marker in block.markers {
                textStorage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: marker)
            }
        }
        let inlineCodePattern = try! NSRegularExpression(pattern: #"(?<!`)(`+)([^`\n]+)\1(?!`)"#)
        let inlineCode = inlineCodePattern.matches(in: source, range: whole).map { absolute($0.range) }
            .filter { range in !codeBlocks.contains { NSIntersectionRange($0.range, range).length > 0 } }
        for span in MarkdownSpans.inline(in: source) {
            let content = absolute(span.content)
            guard !codeBlocks.contains(where: { NSIntersectionRange($0.range, content).length > 0 }),
                  !inlineCode.contains(where: { NSIntersectionRange($0, content).length > 0 }) else { continue }
            let contentFont = textStorage.attribute(.font, at: content.location, effectiveRange: nil) as? NSFont ?? font
            switch span.kind {
            case .bold:
                textStorage.addAttribute(.font, value: NSFontManager.shared.convert(contentFont, toHaveTrait: .boldFontMask), range: content)
            case .italic:
                textStorage.addAttribute(.font, value: NSFontManager.shared.convert(contentFont, toHaveTrait: .italicFontMask), range: content)
            case .link:
                textStorage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: absolute(span.content))
                textStorage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: absolute(span.content))
            }
            for marker in span.markers {
                textStorage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: absolute(marker))
            }
        }
        let codeFont = NSFont.monospacedSystemFont(ofSize: writerFontSize * 0.9, weight: .regular)
        let codeColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.95, alpha: 1)
        }
        let codeParagraph = paragraph.mutableCopy() as! NSMutableParagraphStyle
        codeParagraph.lineSpacing = writerFontSize * 0.2
        codeParagraph.paragraphSpacing = 0
        for block in codeBlocks {
            textStorage.addAttributes([
                .font: codeFont, .foregroundColor: NSColor.textColor,
                .backgroundColor: codeColor, .mdwriteCodeBackground: codeColor,
                .mdwriteCodeContinues: block.markers.count == 1,
                .paragraphStyle: codeParagraph, .underlineStyle: 0
            ], range: block.range)
            for marker in block.markers {
                textStorage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: marker)
            }
        }
        for range in inlineCode {
            textStorage.addAttributes([.font: codeFont, .foregroundColor: NSColor.textColor,
                                      .backgroundColor: codeColor, .underlineStyle: 0], range: range)
        }
        textStorage.endEditing()
        typingAttributes = base
        backgroundColor = .textBackgroundColor
        insertionPointColor = .textColor
        needsDisplay = true
    }
}
