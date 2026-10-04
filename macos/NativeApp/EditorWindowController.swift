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
    /// Read-only View-mode projection. Shares the editor's scroll view as an
    /// alternate document view so scrolling and focus stay native.
    let presentationView: MarkdownTablePresentationView
    /// The scroll view that hosts whichever view is currently showing.
    private(set) weak var editorScroll: NSScrollView?

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
        // The presentation view mirrors the editor's configuration so View mode
        // reads identically once tables are projected.
        let presentationStorage = NSTextStorage()
        let presentationManager = MarkdownLayoutManager()
        presentationManager.allowsNonContiguousLayout = true
        let presentationContainer = NSTextContainer(
            size: NSSize(width: 780, height: CGFloat.greatestFiniteMagnitude))
        presentationContainer.widthTracksTextView = true
        presentationStorage.addLayoutManager(presentationManager)
        presentationManager.addTextContainer(presentationContainer)
        presentationView = MarkdownTablePresentationView(
            frame: NSRect(x: 0, y: 0, width: 860, height: 700), textContainer: presentationContainer)
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
        editorScroll = scroll
        // Resizing must re-evaluate the column layout, or a stacked table never
        // becomes a grid when the window grows.
        scroll.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification,
                                               object: scroll, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleLayoutRefresh() }
        }
        // Mirror the source editor's inset so both modes share the same gutters.
        presentationView.textContainerInset = editor.textContainerInset
        presentationView.minSize = editor.minSize
        presentationView.maxSize = editor.maxSize
        presentationView.autoresizingMask = editor.autoresizingMask
        presentationView.isVerticallyResizable = true
        presentationView.isHorizontallyResizable = false
        presentationView.setFrameSize(NSSize(width: scroll.contentSize.width, height: editor.frame.height))
        // E over the projection maps the caret back to the same cell's source.
        presentationView.editRequested = { [weak self] presentationLocation in
            guard let self else { return }
            if let offset = self.presentationView.sourceOffset(forPresentation: presentationLocation) {
                self.editor.setSelectedRange(NSRange(location: min(offset, self.editor.string.utf16.count),
                                                     length: 0))
            }
            self.editor.setMode(.edit)
            self.updateTablePresentation()
            self.window?.makeFirstResponder(self.editor)
            self.editor.scrollRangeToVisible(self.editor.selectedRange())
        }
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
        // Documents open in View mode, so project any tables present at load.
        // Focus only moves to the projection when one is actually installed;
        // otherwise the source editor keeps first responder for command checks.
        updateTablePresentation()
        window.makeFirstResponder(presentationViewInstalled ? presentationView : editor)
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
        updateTablePresentation()
        window?.makeFirstResponder(presentationViewInstalled ? presentationView : editor)
    }

    @objc func enterViewMode(_ sender: Any?) {
        editor.enterViewMode(sender)
        updateTablePresentation()
        window?.makeFirstResponder(presentationViewInstalled ? presentationView : editor)
    }

    /// E and the mode buttons route through here so the source editor regains
    /// first responder; command checks depend on being in the responder chain.
    @objc func enterEditMode(_ sender: Any?) {
        editor.enterEditMode(sender)
        updateTablePresentation()
        window?.makeFirstResponder(editor)
    }

    /// True when the read-only projection is the view currently on screen.
    private(set) var presentationViewInstalled = false
    /// Usable text width used for the last column-layout decision.
    private(set) var presentationAvailableWidth: Double = 0
    /// Scroll width that produced the current layout, and a coalescing flag.
    private var lastLaidOutWidth: CGFloat = 0
    private var layoutRefreshScheduled = false
    /// True when every table in the last projection could use column geometry.
    var tablesUseColumns: Bool { presentationView.columnsFit }

    /// Install or remove the pipe-free table projection for View mode.
    ///
    /// Edit mode always shows `sourceStorage`. The projection is rebuilt from
    /// the current source each time so a stale snapshot can never be shown.
    private func updateTablePresentation() {
        guard let scroll = editorScroll else { return }
        let source = markdownDocument?.sourceStorage.string ?? ""
        let tables = MarkdownTables.parse(source)
        // Usable width is the viewport minus the equal side gutters the editor
        // already applies, minus a small safety margin.
        let inset = editor.textContainerInset.width * 2
        let available = max(120, Double(scroll.contentSize.width) - inset - 8)
        presentationAvailableWidth = available
        lastLaidOutWidth = scroll.contentSize.width
        let advance = MarkdownTableFontMetrics.advance(for: editor.writerFontSize)
        // Decide per table: a grid when the columns fit the available width,
        // otherwise stacked header/value pairs so nothing overflows or collapses.
        var stacked: Set<Int> = []
        if advance > 0 {
            for (index, table) in tables.enumerated() {
                if case .stacked = MarkdownTableLayoutPlanner.layout(
                    for: table, in: source, available: available, advance: advance) {
                    stacked.insert(index)
                }
            }
        }
        let projection = project(source, tables: tables, stacked: stacked)
        guard editor.mode == .view, !tables.isEmpty,
              presentationView.install(projection: projection, source: source,
                                       fontSize: editor.writerFontSize, available: available) else {
            presentationViewInstalled = false
            if scroll.documentView !== editor { showDocumentView(editor) }
            return
        }
        presentationViewInstalled = true
        // Anchor the read position so switching modes does not jump to the top.
        let length = presentationView.string.utf16.count
        let caret = min(editor.selectedRange().location, length)
        let position = presentationView.sourceOffset(forPresentation: caret) ?? 0
        presentationView.setSelectedRange(NSRange(location: min(position, length), length: 0))
        if scroll.documentView !== presentationView {
            showDocumentView(presentationView)
        }
        presentationView.textContainerInset = editor.textContainerInset
    }

    /// Swap the scroll view's document view, keeping its width in step with the
    /// clip view.
    ///
    /// `NSScrollView` does not resize a document view when it is re-attached, and
    /// autoresizing only propagates when the clip view itself changes size. The
    /// editor starts at the scroll view's content width, which is zero before the
    /// window lays out; a document without tables recovered when the clip view
    /// first sized itself, but one whose editor the projection had replaced never
    /// did, because no further resize happened. The editor came back at that zero
    /// width and Edit mode rendered nothing at all. Restoring it explicitly keeps
    /// both modes the same width without depending on a resize that never comes.
    private func showDocumentView(_ view: NSView) {
        guard let scroll = editorScroll else {
            view.removeFromSuperview()
            return
        }
        scroll.documentView = view
        let width = scroll.contentSize.width
        guard width > 0, view.frame.width != width else { return }
        view.setFrameSize(NSSize(width: width, height: view.frame.height))
    }

    /// Rebuild the projection when the usable width changes.
    ///
    /// Resize fires continuously while dragging, so this coalesces onto a short
    /// delay and compares the width against the last one that was laid out.
    /// Without this, a stacked table never becomes a grid when the window grows.
    private func scheduleLayoutRefresh() {
        guard layoutRefreshScheduled == false else { return }
        layoutRefreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.layoutRefreshScheduled = false
            let width = self.editorScroll?.contentSize.width ?? 0
            guard abs(width - self.lastLaidOutWidth) > 1 else { return }
            self.updateTablePresentation()
        }
    }

    /// Source offset for a caret in the presentation, for View -> Edit.
    private func sourceOffset(forPresentation offset: Int) -> Int? {
        presentationView.sourceOffset(forPresentation: offset)
    }

    /// Visible pipes keep columns aligned without relying on tab geometry.
    private var rowStyle: MarkdownTableRowStyle { .pipes }

    /// Core projection with per-table layout decisions applied.
    private func project(_ source: String, tables: [MarkdownTable],
                         stacked: Set<Int>) -> MarkdownTablePresentation.Result {
        stacked.isEmpty
            ? MarkdownTablePresentation.project(source, tables: tables, style: rowStyle)
            : MarkdownTablePresentation.project(source, tables: tables, stacked: stacked,
                                                 style: rowStyle)
    }

    // Keep history commands gated even when a toolbar control has focus.
    @objc func undo(_ sender: Any?) { editor.undo(sender) }
    @objc func redo(_ sender: Any?) { editor.redo(sender) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if [#selector(undo(_:)), #selector(redo(_:)), #selector(enterViewMode(_:)), #selector(enterEditMode(_:)),
            #selector(MarkdownTextView.alignTableSource(_:))]
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
