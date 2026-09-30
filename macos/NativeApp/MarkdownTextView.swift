import AppKit
import EditorCore

@MainActor
final class MarkdownTextView: NSTextView {
    var sourceDidChange: (() -> Void)?
    var onCommandError: ((Error) -> Void)?
    var writerFontSize: CGFloat = 20
    private var editedSourceRange: NSRange?
    private var pendingFullRestyle = false

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
        let affected: NSRange
        if let changedRange, !pendingFullRestyle {
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
        for span in MarkdownSpans.inline(in: source) {
            switch span.kind {
            case .bold:
                textStorage.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask), range: absolute(span.content))
            case .italic:
                textStorage.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask), range: absolute(span.content))
            case .link:
                textStorage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: absolute(span.content))
                textStorage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: absolute(span.content))
            }
            for marker in span.markers {
                textStorage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: absolute(marker))
            }
        }
        let heading = try! NSRegularExpression(pattern: #"(?m)^(#{1,6})\s+(.+)$"#)
        for match in heading.matches(in: source, range: whole) {
            textStorage.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask), range: absolute(match.range(at: 2)))
            textStorage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: absolute(match.range(at: 1)))
        }
        textStorage.endEditing()
        typingAttributes = base
        backgroundColor = .textBackgroundColor
        insertionPointColor = .textColor
    }
}
