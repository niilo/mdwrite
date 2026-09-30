import AppKit
import CoreText

@MainActor
final class MarkdownDocumentController: NSDocumentController {
    override func makeUntitledDocument(ofType typeName: String) throws -> NSDocument {
        let document = MarkdownDocument()
        document.fileType = typeName
        return document
    }

    override func makeDocument(withContentsOf url: URL, ofType typeName: String) throws -> NSDocument {
        let document = MarkdownDocument()
        try document.read(from: url, ofType: typeName)
        document.fileURL = url
        document.fileType = typeName
        return document
    }
}

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    let documents = MarkdownDocumentController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let records = try RecoveryStore.applicationStore().records()
            for record in records {
                let document = MarkdownDocument()
                document.restore(record)
                documents.addDocument(document)
                document.makeWindowControllers()
                document.showWindows()
                document.editorController?.showStatus("Recovered unsaved text as a copy")
            }
        } catch {
            NSApp.presentError(error)
        }
        if documents.documents.isEmpty { documents.newDocument(nil) }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        for filename in filenames {
            documents.openDocument(withContentsOf: URL(fileURLWithPath: filename), display: true) { _, _, error in
                if let error { NSApp.presentError(error) }
            }
        }
        sender.reply(toOpenOrPrint: .success)
    }

    @objc func showAbout(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "mdwrite", .applicationVersion: "0.1.0"])
    }
}

@MainActor
func installMenus(delegate: ApplicationDelegate) {
    let bar = NSMenu()
    func submenu(_ title: String) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        item.submenu = menu
        bar.addItem(item)
        return menu
    }
    func item(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "",
              modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.keyEquivalentModifierMask = modifiers
        entry.target = target
        menu.addItem(entry)
    }
    let app = submenu("mdwrite")
    item(app, "About mdwrite", #selector(ApplicationDelegate.showAbout(_:)), target: delegate)
    app.addItem(.separator())
    item(app, "Hide mdwrite", #selector(NSApplication.hide(_:)), "h")
    item(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", modifiers: [.command, .option])
    item(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
    app.addItem(.separator())
    item(app, "Quit mdwrite", #selector(NSApplication.terminate(_:)), "q")
    let file = submenu("File")
    item(file, "New", #selector(NSDocumentController.newDocument(_:)), "n", target: delegate.documents)
    item(file, "Open…", #selector(NSDocumentController.openDocument(_:)), "o", target: delegate.documents)
    item(file, "Close", #selector(NSWindow.performClose(_:)), "w")
    file.addItem(.separator())
    item(file, "Save", #selector(NSDocument.save(_:)), "s")
    item(file, "Save As…", #selector(NSDocument.saveAs(_:)), "s", modifiers: [.command, .shift])
    file.addItem(.separator())
    item(file, "Print…", #selector(NSDocument.printDocument(_:)), "p")
    let edit = submenu("Edit")
    item(edit, "Undo", Selector(("undo:")), "z")
    item(edit, "Redo", Selector(("redo:")), "z", modifiers: [.command, .shift])
    edit.addItem(.separator())
    item(edit, "Cut", #selector(NSText.cut(_:)), "x")
    item(edit, "Copy", #selector(NSText.copy(_:)), "c")
    item(edit, "Paste", #selector(NSText.paste(_:)), "v")
    item(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
    edit.addItem(.separator())
    for (title, key, tag, modifiers) in [
        ("Find…", "f", NSTextFinder.Action.showFindInterface, NSEvent.ModifierFlags.command),
        ("Find Next", "g", .nextMatch, .command),
        ("Find Previous", "g", .previousMatch, [.command, .shift]),
        ("Find and Replace…", "f", .showReplaceInterface, [.command, .option])
    ] {
        item(edit, title, #selector(NSTextView.performTextFinderAction(_:)), key, modifiers: modifiers)
        edit.items.last?.tag = tag.rawValue
    }
    let format = submenu("Format")
    item(format, "Bold", #selector(MarkdownTextView.makeBold(_:)), "b")
    item(format, "Italic", #selector(MarkdownTextView.makeItalic(_:)), "i")
    item(format, "Insert Link", #selector(MarkdownTextView.insertMarkdownLink(_:)), "k")
    let view = submenu("View")
    item(view, "Larger Text", #selector(MarkdownTextView.increaseTextSize(_:)), "+")
    item(view, "Smaller Text", #selector(MarkdownTextView.decreaseTextSize(_:)), "-")
    item(view, "Reset Text Size", #selector(MarkdownTextView.resetTextSize(_:)), "0")
    view.addItem(.separator())
    item(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", modifiers: [.command, .control])
    let window = submenu("Window")
    item(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
    item(window, "Zoom", #selector(NSWindow.performZoom(_:)))
    item(window, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
    NSApp.windowsMenu = window
    NSApp.mainMenu = bar
}

@main
@MainActor
struct MDWriteApplication {
    static func main() {
        let app = NSApplication.shared
        if let resources = Bundle.main.resourceURL {
            for file in ["Regular", "Bold", "Italic", "BoldItalic"] {
                let url = resources.appendingPathComponent("iAWriterMonoS-\(file).ttf")
                if FileManager.default.fileExists(atPath: url.path) {
                    CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
                }
            }
        }
        let delegate = ApplicationDelegate()
        app.delegate = delegate
        installMenus(delegate: delegate)
        if CommandLine.arguments.contains("--smoke-test") || CommandLine.arguments.contains("--style-test") {
            app.setActivationPolicy(.prohibited)
            do {
                if CommandLine.arguments.contains("--style-test") {
                    try NativeSmoke.runFormatting()
                } else {
                    try NativeSmoke.run()
                }
                exit(0)
            } catch {
                fputs("FAIL: \(error)\n", stderr)
                exit(1)
            }
        }
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
