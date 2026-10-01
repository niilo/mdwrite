import AppKit
import EditorCore

enum EditorMode {
    case view, edit
}

@MainActor
final class MarkdownTextView: NSTextView {
    var sourceDidChange: (() -> Void)?
    var onCommandError: ((Error) -> Void)?
    var modeDidChange: ((EditorMode) -> Void)?
    private(set) var mode: EditorMode = .view
    var writerFontSize: CGFloat = 20
    private var coordinator: MarkdownAnalysisCoordinator?
    private var settingMarkedText = false
    var returnCache = MarkdownReturnCache()
    var defersStyling: Bool { settingMarkedText || hasMarkedText() }
    var stylingIsPending: Bool { coordinator?.isPending ?? false }
    var pendingAnalysisDescription: String { coordinator?.pendingDescription ?? "none" }
    var backgroundPhaseMaxima: [String: Double] { coordinator?.backgroundPhaseMaxima ?? [:] }
    var mainThreadStageMaxima: [String: Double] { coordinator?.mainThreadStageMaxima ?? [:] }
    var analysisRevision: UInt64 { coordinator?.revision ?? 0 }
    func stopAnalysis() { coordinator?.shutdown() }
    func didLoadSource() { coordinator?.didLoadSource() }

    /// Keep viewport queries on the active engine. Accessing `layoutManager`
    /// on a TextKit 2 editor can permanently switch it to compatibility mode.
    func visibleSourceRange() -> NSRange {
        let caret = NSRange(location: selectedRange().location, length: 0)
        if let manager = textLayoutManager {
            guard let content = manager.textContentManager,
                  let range = manager.textViewportLayoutController.viewportRange else { return caret }
            let start = content.offset(from: content.documentRange.location, to: range.location)
            let end = content.offset(from: content.documentRange.location, to: range.endLocation)
            guard start != NSNotFound, end != NSNotFound, start >= 0, end >= start,
                  end <= (textStorage?.length ?? 0) else { return caret }
            return NSRange(location: start, length: end - start)
        }
        if let manager = layoutManager, let container = textContainer {
            let glyphs = manager.glyphRange(forBoundingRect: visibleRect, in: container)
            if glyphs.length > 0 { return manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil) }
        }
        return caret
    }

    // A delivery seam lets lifecycle checks hold completed work and reproduce
    // races deterministically. Production delivers immediately on the main actor.
    func configureAnalysisDelivery(_ delivery: @escaping @MainActor (MarkdownAnalysisPhase, @escaping @MainActor () -> Void) -> Void) {
        guard let textStorage else { return }
        coordinator?.shutdown()
        coordinator = MarkdownAnalysisCoordinator(editor: self, storage: textStorage, deliverAnalysis: delivery)
        coordinator?.request()
    }
    func setMode(_ next: EditorMode) {
        guard mode != next || isEditable != (next == .edit) else { return }
        // Finish an existing composition before locking subsequent input.
        if next == .view && hasMarkedText() { unmarkText() }
        mode = next
        isEditable = next == .edit
        isSelectable = true
        setAccessibilityLabel(next == .view ? "Markdown document, view mode" : "Markdown document, edit mode")
        modeDidChange?(next)
    }

    @objc func enterViewMode(_ sender: Any?) { setMode(.view) }
    @objc func enterEditMode(_ sender: Any?) { setMode(.edit) }

    @objc func undo(_ sender: Any?) {
        guard mode == .edit, !hasMarkedText() else { return }
        undoManager?.undo()
    }

    @objc func redo(_ sender: Any?) {
        guard mode == .edit, !hasMarkedText() else { return }
        undoManager?.redo()
    }

    override func keyDown(with event: NSEvent) {
        if mode == .view, event.charactersIgnoringModifiers?.lowercased() == "e",
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           !hasMarkedText() {
            enterEditMode(nil)
            return
        }
        if [36, 76].contains(event.keyCode), event.modifierFlags.contains(.shift),
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           !hasMarkedText() {
            insertLineBreak(nil)
            return
        }
        super.keyDown(with: event)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard mode == .edit else { return }
        super.insertText(string, replacementRange: replacementRange)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard mode == .edit else { return }
        settingMarkedText = true
        defer { settingMarkedText = false }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        mode == .edit && super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }

    override func shouldChangeText(inRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool {
        mode == .edit && super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings)
    }

    override func doCommand(by selector: Selector) {
        if selector == #selector(undo(_:)) { undo(nil); return }
        if selector == #selector(redo(_:)) { redo(nil); return }
        super.doCommand(by: selector)
    }

    override func paste(_ sender: Any?) {
        guard mode == .edit else { return }
        guard !hasMarkedText(), let text = NSPasteboard.general.string(forType: .string) else {
            super.paste(sender)
            return
        }
        apply(.paste(text))
    }

    override func cut(_ sender: Any?) {
        guard mode == .edit else { return }
        super.cut(sender)
    }

    override func insertNewline(_ sender: Any?) {
        guard mode == .edit else { return }
        guard !hasMarkedText() else { super.insertNewline(sender); return }
        apply(.insertReturn(soft: false))
    }

    override func insertLineBreak(_ sender: Any?) {
        guard mode == .edit else { return }
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
        guard mode == .edit else { return }
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
        guard mode == .edit, !hasMarkedText() else { return }
        do {
            if let edit = try EditorBehavior.edit(command, in: string, selection: selectedRange(), returnCache: &returnCache) {
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
        guard mode == .edit, !hasMarkedText(), let textStorage else { return }
        do {
            try edit.validate(in: textStorage.string as NSString)
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

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(applyMarkdownFormat(_:)), #selector(makeBold(_:)), #selector(makeItalic(_:)),
             #selector(insertMarkdownLink(_:)):
            return mode == .edit && !hasMarkedText()
        case #selector(undo(_:)): return mode == .edit && !hasMarkedText() && undoManager?.canUndo == true
        case #selector(redo(_:)): return mode == .edit && !hasMarkedText() && undoManager?.canRedo == true
        case #selector(enterViewMode(_:)):
            item.state = mode == .view ? .on : .off
            return true
        case #selector(enterEditMode(_:)):
            item.state = mode == .edit ? .on : .off
            return true
        case #selector(performTextFinderAction(_:)):
            if mode == .view && Self.isReplacementAction(item.tag) { return false }
        default: break
        }
        return super.validateMenuItem(item)
    }

    override func performTextFinderAction(_ sender: Any?) {
        if mode == .view, let item = sender as? NSMenuItem, Self.isReplacementAction(item.tag) { return }
        super.performTextFinderAction(sender)
    }

    private static func isReplacementAction(_ tag: Int) -> Bool {
        [.showReplaceInterface, .replace, .replaceAll, .replaceAllInSelection, .replaceAndFind]
            .contains(NSTextFinder.Action(rawValue: tag))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if let coordinator { coordinator.invalidatePresentation() }
        else { restyle() }
    }

    override func unmarkText() {
        super.unmarkText()
        restyle()
    }

    func restyle() {
        guard let textStorage else { return }
        if coordinator == nil { coordinator = MarkdownAnalysisCoordinator(editor: self, storage: textStorage) }
        coordinator?.request()
    }
}
