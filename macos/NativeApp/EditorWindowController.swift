import AppKit
import EditorCore

@MainActor
final class EditorWindowController: NSWindowController, NSTextViewDelegate {
    let editor: MarkdownTextView
    private let countLabel = NSTextField(labelWithString: "0 words")
    private let statusLabel = NSTextField(labelWithString: "")
    private var footerTimer: Timer?
    private weak var markdownDocument: MarkdownDocument?

    init(document: MarkdownDocument) {
        markdownDocument = document
        let manager = MarkdownLayoutManager()
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
        editor.delegate = self
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
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
        editor.setAccessibilityLabel("Markdown document")
        editor.sourceDidChange = { [weak document] in document?.sourceChanged() }
        editor.onCommandError = { [weak self] error in self?.showStatus(error.localizedDescription) }

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.documentView = editor
        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        for label in [countLabel, statusLabel] {
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
            statusLabel.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: countLabel.leadingAnchor, constant: -20),
            statusLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor)
        ])
        editor.restyle()
        refreshFooter()
        window.makeFirstResponder(editor)
    }

    required init?(coder: NSCoder) { fatalError("Storyboard initialization is not used") }

    func undoManager(for view: NSTextView) -> UndoManager? { markdownDocument?.undoManager }

    func textDidChange(_ notification: Notification) { scheduleFooter() }

    func scheduleFooter() {
        footerTimer?.invalidate()
        footerTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshFooter() }
        }
    }

    func refreshFooter() {
        let count = EditorBehavior.wordCount(editor.string)
        countLabel.stringValue = "\(count) \(count == 1 ? "word" : "words")"
    }

    func showStatus(_ text: String) { statusLabel.stringValue = text }
}
