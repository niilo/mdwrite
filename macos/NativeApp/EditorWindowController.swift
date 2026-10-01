import AppKit
import EditorCore

@MainActor
final class EditorWindowController: NSWindowController, NSTextViewDelegate, NSToolbarDelegate, NSMenuItemValidation {
    let editor: MarkdownTextView
    private let countLabel = NSTextField(labelWithString: "0 words")
    private let statusLabel = NSTextField(labelWithString: "")
    private let modeLabel = NSTextField(labelWithString: "View only · E to edit")
    private let modeControl = NSSegmentedControl(labels: ["View", "Edit"], trackingMode: .selectOne, target: nil, action: nil)
    private weak var formatControl: NSPopUpButton?
    private var footerTimer: Timer?
    private var countTask: Task<Void, Never>?
    private var countRevision: UInt64 = 0
    private var countRequested = false
    private var servicesStopped = false
    private weak var markdownDocument: MarkdownDocument?

    init(document: MarkdownDocument) {
        markdownDocument = document
        // Establish one base run before attaching layout; semantic decoration is asynchronous.
        document.sourceStorage.setAttributes(MarkdownStyler.baseAttributes(fontSize: 20),
                                             range: NSRange(location: 0, length: document.sourceStorage.length))
        let manager = MarkdownLayoutManager()
        manager.allowsNonContiguousLayout = true
        let container = NSTextContainer(size: NSSize(width: 780, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        document.sourceStorage.addLayoutManager(manager)
        manager.addTextContainer(container)
        editor = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 860, height: 700), textContainer: container)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Untitled — mdwrite"
        window.minSize = NSSize(width: 560, height: 420)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.setFrameAutosaveName("mdwrite.editor")
        let toolbar = NSToolbar(identifier: "mdwrite.editor.toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        editor.delegate = self
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.setMode(.view)
        editor.modeDidChange = { [weak self] _ in self?.refreshModeControls() }
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = true
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.minSize = NSSize(width: 0, height: 700)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainerInset = NSSize(width: 66, height: 45)
        editor.usesFindBar = true
        editor.isIncrementalSearchingEnabled = true
        editor.setAccessibilityIdentifier("sourceEditor")
        editor.sourceDidChange = { [weak document] in document?.sourceChanged() }
        editor.onCommandError = { [weak self] error in self?.showStatus(error.localizedDescription) }

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        // Autoresizing preserves the document/viewport width difference. Start
        // them at the same width before attachment, including a zero-size clip.
        editor.setFrameSize(NSSize(width: scroll.contentSize.width, height: editor.frame.height))
        scroll.documentView = editor
        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        for label in [countLabel, statusLabel, modeLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            footer.addSubview(label)
        }
        countLabel.setAccessibilityIdentifier("wordCount")
        statusLabel.lineBreakMode = .byTruncatingTail
        let content = NSView()
        window.contentView = content
        content.addSubview(scroll)
        content.addSubview(footer)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 30),
            countLabel.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -20),
            countLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            modeLabel.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 20),
            modeLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: modeLabel.trailingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: countLabel.leadingAnchor, constant: -20),
            statusLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor)
        ])
        editor.restyle()
        refreshFooter()
        refreshModeControls()
        window.makeFirstResponder(editor)
    }

    required init?(coder: NSCoder) { fatalError("Storyboard initialization is not used") }

    private static let formatItem = NSToolbarItem.Identifier("mdwrite.format")
    private static let modeItem = NSToolbarItem.Identifier("mdwrite.mode")

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.modeItem, Self.formatItem, .flexibleSpace]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.modeItem, Self.formatItem, .flexibleSpace]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if identifier == Self.modeItem {
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "Mode"
            modeControl.target = self
            modeControl.action = #selector(chooseMode(_:))
            modeControl.selectedSegment = editor.mode == .view ? 0 : 1
            modeControl.setToolTip("Read without modifying the document", forSegment: 0)
            modeControl.setToolTip("Edit the Markdown source", forSegment: 1)
            modeControl.setAccessibilityLabel("Document mode")
            modeControl.setAccessibilityIdentifier("editorMode")
            modeControl.sizeToFit()
            item.view = modeControl
            return item
        }
        guard identifier == Self.formatItem else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Format"
        item.paletteLabel = "Markdown Formatting"
        item.toolTip = "Insert Markdown formatting into the current document"
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 130, height: 28), pullsDown: true)
        let menu = MarkdownFormatMenu.make(target: editor)
        menu.insertItem(NSMenuItem(title: "Format", action: nil, keyEquivalent: ""), at: 0)
        popup.menu = menu
        popup.setAccessibilityLabel("Markdown formatting")
        popup.setAccessibilityIdentifier("formatToolbox")
        popup.isEnabled = editor.mode == .edit
        formatControl = popup
        item.view = popup
        return item
    }

    @objc func chooseMode(_ sender: NSSegmentedControl) {
        editor.setMode(sender.selectedSegment == 1 ? .edit : .view)
        window?.makeFirstResponder(editor)
    }

    @objc func enterViewMode(_ sender: Any?) {
        editor.enterViewMode(sender)
        window?.makeFirstResponder(editor)
    }

    @objc func enterEditMode(_ sender: Any?) {
        editor.enterEditMode(sender)
        window?.makeFirstResponder(editor)
    }

    // Keep history commands gated even when a toolbar control has focus.
    @objc func undo(_ sender: Any?) { editor.undo(sender) }
    @objc func redo(_ sender: Any?) { editor.redo(sender) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if [#selector(undo(_:)), #selector(redo(_:)), #selector(enterViewMode(_:)), #selector(enterEditMode(_:))]
            .contains(item.action) {
            return editor.validateMenuItem(item)
        }
        return true
    }

    private func refreshModeControls() {
        modeControl.selectedSegment = editor.mode == .view ? 0 : 1
        formatControl?.isEnabled = editor.mode == .edit
        modeLabel.stringValue = editor.mode == .view ? "View only · E to edit" : "Edit mode"
    }

    func undoManager(for view: NSTextView) -> UndoManager? { markdownDocument?.undoManager }

    func textDidChange(_ notification: Notification) { scheduleFooter() }

    func scheduleFooter() {
        guard !servicesStopped else { return }
        countRevision &+= 1
        if countTask != nil { countRequested = true; return }
        guard footerTimer == nil else { return }
        footerTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.footerTimer = nil
                self?.refreshFooter()
            }
        }
    }

    func refreshFooter() {
        guard !servicesStopped else { return }
        if countTask != nil { countRequested = true; return }
        let revision = countRevision
        let snapshot = editor.string
        countTask = Task { [weak self] in
            let count = await DocumentBackgroundServices.wordCount(snapshot: snapshot)
            guard let self else { return }
            self.countTask = nil
            if !self.servicesStopped, self.countRevision == revision {
                self.countLabel.stringValue = "\(count) \(count == 1 ? "word" : "words")"
            }
            if self.countRequested {
                self.countRequested = false
                self.scheduleFooter()
            }
        }
    }

    func stopServices() {
        servicesStopped = true
        countRevision &+= 1
        footerTimer?.invalidate(); footerTimer = nil
        countTask?.cancel()
    }

    func showStatus(_ text: String) { statusLabel.stringValue = text }
}
