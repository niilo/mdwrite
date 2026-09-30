import AppKit

extension NSAttributedString.Key {
    static let mdwriteCodeBackground = NSAttributedString.Key("mdwrite.codeBackground")
    static let mdwriteCodeContinues = NSAttributedString.Key("mdwrite.codeContinues")
}

final class MarkdownLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        if let textStorage, glyphsToShow.length > 0 {
            let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
            textStorage.enumerateAttribute(.mdwriteCodeBackground, in: characters) { value, range, _ in
                guard let color = value as? NSColor else { return }
                let glyphs = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                color.setFill()
                self.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in
                    // Fill the paragraph width, including empty and wrapped code lines.
                    NSBezierPath(rect: rect.offsetBy(dx: origin.x, dy: origin.y)).fill()
                }
            }
            if NSMaxRange(characters) == textStorage.length, textStorage.length > 0,
               textStorage.attribute(.mdwriteCodeContinues, at: textStorage.length - 1, effectiveRange: nil) as? Bool == true,
               let color = textStorage.attribute(.mdwriteCodeBackground, at: textStorage.length - 1,
                                                 effectiveRange: nil) as? NSColor,
               textStorage.string.hasSuffix("\n") {
                color.setFill()
                NSBezierPath(rect: extraLineFragmentRect.offsetBy(dx: origin.x, dy: origin.y)).fill()
            }
        }
        // Keep native selection, find-match, and marked-text highlighting on top.
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }
}
