import AppKit
import EditorCore

@MainActor
enum MarkdownFormatMenu {
    static func make(target: MarkdownTextView? = nil) -> NSMenu {
        let menu = NSMenu(title: "Format")
        for group in MarkdownFormat.groups {
            let parent = NSMenuItem(title: group.title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: group.title)
            for format in group.options {
                let entry = NSMenuItem(title: format.title,
                                       action: #selector(MarkdownTextView.applyMarkdownFormat(_:)),
                                       keyEquivalent: "")
                entry.tag = format.rawValue
                entry.target = target
                switch format {
                case .bold: entry.keyEquivalent = "b"
                case .italic: entry.keyEquivalent = "i"
                case .link: entry.keyEquivalent = "k"
                case .heading1, .heading2, .heading3, .heading4, .heading5, .heading6:
                    entry.keyEquivalent = String(format.rawValue - MarkdownFormat.heading1.rawValue + 1)
                    entry.keyEquivalentModifierMask = [.command, .option]
                default: break
                }
                submenu.addItem(entry)
            }
            parent.submenu = submenu
            menu.addItem(parent)
        }
        return menu
    }
}
