import AppKit

extension NSAttributedString.Key {
    static let mdwriteCodeBackground = NSAttributedString.Key("mdwrite.codeBackground")
    static let mdwriteCodeContinues = NSAttributedString.Key("mdwrite.codeContinues")
    static let mdwriteQuoteDepth = NSAttributedString.Key("mdwrite.quoteDepth")
    static let mdwriteRule = NSAttributedString.Key("mdwrite.rule")
    static let mdwriteTableBackground = NSAttributedString.Key("mdwrite.tableBackground")
}

final class MarkdownLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        if let textStorage, glyphsToShow.length > 0 {
            let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
            textStorage.enumerateAttribute(.mdwriteTableBackground, in: characters) { value, range, _ in
                guard let color = value as? NSColor else { return }
                color.setFill()
                self.enumerateLineFragments(forGlyphRange: self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)) { rect, _, _, _, _ in
                    NSBezierPath(rect: rect.offsetBy(dx: origin.x, dy: origin.y)).fill()
                }
            }
            textStorage.enumerateAttribute(.mdwriteCodeBackground, in: characters) { value, range, _ in
                guard let color = value as? NSColor else { return }
                let glyphs = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                color.setFill()
                self.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in
                    // Fill the paragraph width, including empty and wrapped code lines.
                    NSBezierPath(rect: rect.offsetBy(dx: origin.x, dy: origin.y)).fill()
                }
            }
            textStorage.enumerateAttribute(.mdwriteQuoteDepth, in: characters) { value, range, _ in
                guard let depth = value as? Int, depth > 0 else { return }
                NSColor.separatorColor.setFill()
                self.enumerateLineFragments(forGlyphRange: self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)) { rect, _, _, _, _ in
                    for level in 0..<depth {
                        NSBezierPath(rect: NSRect(x: origin.x + CGFloat(level) * 14 + 4,
                                                 y: origin.y + rect.minY, width: 2, height: rect.height)).fill()
                    }
                }
            }
            textStorage.enumerateAttribute(.mdwriteRule, in: characters) { value, range, _ in
                guard value as? Bool == true else { return }
                NSColor.separatorColor.setFill()
                self.enumerateLineFragments(forGlyphRange: self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)) { rect, _, _, _, _ in
                    NSBezierPath(rect: NSRect(x: origin.x + rect.minX, y: origin.y + rect.maxY - 2,
                                             width: rect.width, height: 1)).fill()
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
