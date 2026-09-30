import AppKit
import EditorCore

@MainActor
enum MarkdownPrintRenderer {
    static func makeView(source: String, width: CGFloat) -> NSTextView {
        let normalFont = NSFont.systemFont(ofSize: 12)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 4
        let rendered = NSMutableAttributedString()
        var inFence = false
        for original in source.components(separatedBy: "\n") {
            var text = original
            var font = normalFont
            var foreground = NSColor.black
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            if inFence {
                font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            } else if let match = match(#"^(#{1,6})\s+(.*)$"#, in: text) {
                let level = match.range(at: 1).length
                text = (text as NSString).substring(with: match.range(at: 2))
                font = .systemFont(ofSize: 12 + CGFloat(7 - level) * 2, weight: .semibold)
            } else if let match = match(#"^\s*>+\s?(.*)$"#, in: text) {
                text = (text as NSString).substring(with: match.range(at: 1))
                font = NSFontManager.shared.convert(normalFont, toHaveTrait: .italicFontMask)
                foreground = .darkGray
            } else if let match = match(#"^(\s*)[-+*]\s+(.*)$"#, in: text) {
                let source = text as NSString
                text = source.substring(with: match.range(at: 1)) + "• " + source.substring(with: match.range(at: 2))
            }
            let line = NSMutableAttributedString(string: text + "\n", attributes: [
                .font: font, .foregroundColor: foreground, .paragraphStyle: paragraph
            ])
            if !inFence {
                let spans = MarkdownSpans.inline(in: text)
                for span in spans {
                    switch span.kind {
                    case .bold:
                        line.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask), range: span.content)
                    case .italic:
                        line.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask), range: span.content)
                    case .link:
                        line.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: span.content)
                    }
                }
                let removals = spans.flatMap(\.markers).sorted { $0.location > $1.location }
                var lastStart = line.length
                for range in removals where NSMaxRange(range) <= lastStart {
                    line.deleteCharacters(in: range)
                    lastStart = range.location
                }
            }
            rendered.append(line)
        }
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: max(200, width), height: 100))
        view.isEditable = false
        view.isRichText = true
        view.backgroundColor = .white
        view.textContainerInset = .zero
        view.textContainer?.containerSize = NSSize(width: view.frame.width, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.textStorage?.setAttributedString(rendered)
        if let container = view.textContainer, let manager = view.layoutManager {
            manager.ensureLayout(for: container)
            let height = manager.usedRect(for: container).height
            view.setFrameSize(NSSize(width: view.frame.width, height: max(100, height + 20)))
        }
        return view
    }

    private static func match(_ pattern: String, in source: String) -> NSTextCheckingResult? {
        try! NSRegularExpression(pattern: pattern).firstMatch(in: source, range: NSRange(location: 0, length: (source as NSString).length))
    }
}
