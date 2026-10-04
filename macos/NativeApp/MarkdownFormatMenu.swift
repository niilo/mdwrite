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
        // Source tools that act on an existing table sit outside the formatting
        // catalog, so the Format menu keeps exactly one item per MarkdownFormat.
        // A nil target routes through the responder chain to the focused document.
        menu.addItem(.separator())
        let align = NSMenuItem(title: "Align Table Source",
                               action: #selector(MarkdownTextView.alignTableSource(_:)),
                               keyEquivalent: "")
        align.target = target
        menu.addItem(align)
        return menu
    }
}
