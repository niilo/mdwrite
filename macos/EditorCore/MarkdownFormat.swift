import Foundation

/// One catalog drives the menu, toolbox, source edits, and command coverage.
public enum MarkdownFormat: Int, CaseIterable, Sendable {
    case bold, italic, boldItalic, strikethrough, inlineCode
    case paragraph, heading1, heading2, heading3, heading4, heading5, heading6
    case setextHeading1, setextHeading2
    case unorderedList, orderedList, taskList, completedTask, indent, outdent
    case blockquote, fencedCode, indentedCode, horizontalRule, table
    case link, image, referenceLink, referenceImage, autolink, linkDefinition
    case footnote, hardBreak, escape, entity, html, comment

    public var title: String {
        switch self {
        case .bold: "Bold"
        case .italic: "Italic"
        case .boldItalic: "Bold and Italic"
        case .strikethrough: "Strikethrough"
        case .inlineCode: "Inline Code"
        case .paragraph: "Paragraph"
        case .heading1: "Heading 1"
        case .heading2: "Heading 2"
        case .heading3: "Heading 3"
        case .heading4: "Heading 4"
        case .heading5: "Heading 5"
        case .heading6: "Heading 6"
        case .setextHeading1: "Setext Heading 1"
        case .setextHeading2: "Setext Heading 2"
        case .unorderedList: "Bulleted List"
        case .orderedList: "Numbered List"
        case .taskList: "Task List"
        case .completedTask: "Completed Task"
        case .indent: "Indent / Nest List"
        case .outdent: "Outdent / Unnest List"
        case .blockquote: "Blockquote"
        case .fencedCode: "Fenced Code Block"
        case .indentedCode: "Indented Code Block"
        case .horizontalRule: "Horizontal Rule"
        case .table: "Table"
        case .link: "Insert Link"
        case .image: "Insert Image"
        case .referenceLink: "Reference Link"
        case .referenceImage: "Reference Image"
        case .autolink: "Automatic Link"
        case .linkDefinition: "Link Reference Definition"
        case .footnote: "Footnote"
        case .hardBreak: "Hard Line Break"
        case .escape: "Escape Markdown Characters"
        case .entity: "HTML Entity"
        case .html: "HTML Block"
        case .comment: "HTML Comment"
        }
    }

    public var group: String {
        switch self {
        case .bold, .italic, .boldItalic, .strikethrough, .inlineCode: "Inline"
        case .paragraph, .heading1, .heading2, .heading3, .heading4, .heading5, .heading6,
             .setextHeading1, .setextHeading2: "Headings"
        case .unorderedList, .orderedList, .taskList, .completedTask, .indent, .outdent: "Lists"
        case .blockquote, .fencedCode, .indentedCode, .horizontalRule, .table: "Blocks"
        case .link, .image, .referenceLink, .referenceImage, .autolink, .linkDefinition: "Links and Images"
        case .footnote, .hardBreak, .escape, .entity, .html, .comment: "Other"
        }
    }

    public static var groups: [(title: String, options: [MarkdownFormat])] {
        ["Inline", "Headings", "Lists", "Blocks", "Links and Images", "Other"].map { title in
            (title, allCases.filter { $0.group == title })
        }
    }
}
