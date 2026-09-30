import AppKit
import EditorCore

@MainActor
final class MarkdownTextView: NSTextView {
    var sourceDidChange: (() -> Void)?
    var onCommandError: ((Error) -> Void)?
    var writerFontSize: CGFloat = 20

    override func keyDown(with event: NSEvent) {
        if [36, 76].contains(event.keyCode), event.modifierFlags.contains(.shift),
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           !hasMarkedText() {
            insertLineBreak(nil)
            return
        }
        super.keyDown(with: event)
    }

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

    override func insertNewlineIgnoringFieldEditor(_ sender: Any?) {
        insertLineBreak(sender)
    }

    @objc func makeBold(_ sender: Any?) { apply(.bold) }
    @objc func makeItalic(_ sender: Any?) { apply(.italic) }
    @objc func insertMarkdownLink(_ sender: Any?) {
        apply(.link(clipboard: NSPasteboard.general.string(forType: .string) ?? ""))
    }

    @objc func applyMarkdownFormat(_ sender: NSMenuItem) {
        guard let format = MarkdownFormat(rawValue: sender.tag) else { return }
        window?.makeFirstResponder(self)
        if format == .link {
            insertMarkdownLink(sender)
        } else {
            apply(.format(format))
        }
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
                case .format(let format): name = format.title
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
            didChangeText()
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
        // Blocks and reference definitions can change the style of distant source.
        if !hasMarkedText() { restyle() }
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

    func restyle() {
        guard let textStorage, !hasMarkedText() else { return }
        typingAttributes = MarkdownStyler.apply(to: textStorage, fontSize: writerFontSize)
        backgroundColor = .textBackgroundColor
        insertionPointColor = .textColor
        needsDisplay = true
    }
}
