import AppKit

extension NSAttributedString.Key {
    static let mdwriteCodeBackground = NSAttributedString.Key("mdwrite.codeBackground")
    static let mdwriteCodeContinues = NSAttributedString.Key("mdwrite.codeContinues")
    static let mdwriteQuoteDepth = NSAttributedString.Key("mdwrite.quoteDepth")
    static let mdwriteRule = NSAttributedString.Key("mdwrite.rule")
    static let mdwriteTableBackground = NSAttributedString.Key("mdwrite.tableBackground")
    /// Zebra band index for a projected table row, so the layout manager can
    /// alternate row shading without parsing tables while drawing.
    static let mdwriteTableRow = NSAttributedString.Key("mdwrite.tableRow")
    /// Table ordinal, so adjacent tables can restart their banding.
    static let mdwriteTableIndex = NSAttributedString.Key("mdwrite.tableIndex")
    /// Last row of a table, used to close the outline at the bottom edge.
    static let mdwriteTableIsLastRow = NSAttributedString.Key("mdwrite.tableIsLastRow")
    /// First row of a table, used to close the outline at the top edge.
    static let mdwriteTableIsFirstRow = NSAttributedString.Key("mdwrite.tableIsFirstRow")
}

final class MarkdownLayoutManager: NSLayoutManager {

        // The origin the last draw used. `debugRowRects` has to report bands in
        // the same coordinate space the bands were painted in, and that origin
        // is only known at draw time, so it is recorded here rather than
        // recomputed. Without it the debug rects sit at raw container
        // coordinates while the pixels sit `origin` away, which leaves the
        // geometry assertions intact (a uniform offset preserves widths, right
        // edges, and order) while making any pixel sampled against them land on
        // the wrong row.
        private(set) var lastTableDrawOrigin: NSPoint = .zero

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        lastTableDrawOrigin = origin
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
            drawTableDecoration(forCharacterRange: characters, origin: origin)
        }
        // Keep native selection, find-match, and marked-text highlighting on top.
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    /// Row range with trailing spaces removed. Cells are padded to a shared
    /// width, so the padding must not count toward the band's visible extent.
    private func trimmedRow(_ range: NSRange, in storage: NSTextStorage) -> NSRange {
        let text = storage.string as NSString
        var end = NSMaxRange(range)
        while end > range.location {
            let unit = text.character(at: end - 1)
            if unit == 32 || unit == 9 || unit == 10 || unit == 13 {
                end -= 1
            } else {
                break
            }
        }
        guard end < NSMaxRange(range) else { return range }
        return NSRange(location: range.location, length: end - range.location)
    }

    /// Real ink extent of a glyph range. Trailing padding produces no glyphs,
    /// so this is what keeps a band from extending to the container edge.
    /// A wrapped row unions its line fragments, so one row is still one band.
    private func usedRect(forCharacterRange range: NSRange, container: NSTextContainer,
                          storage: NSTextStorage) -> NSRect {
        guard range.length > 0 else { return .zero }
        let text = storage.string as NSString
        guard range.location < text.length else { return .zero }
        let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return .zero }
        // Walk the row line by line so wrapped continuations are covered too;
        // measuring only the first fragment left the rest of the row unshaded.
        //
        // Each fragment is measured from its own used glyph range. Measuring the
        // whole row and applying that width to every fragment is wrong: for a
        // wrapped row the unwrapped text is much wider than the container, so
        // the band overshot the last cell and painted empty space. Because the
        // row still reports its widest line, the table-wide width below is
        // unaffected.
        //
        // Width comes from measuring the characters, not from a glyph box. A
        // bounding rect for glyphs near the end of a line can stretch to the
        // container edge, which would paint the band past the last cell.
        func measuredWidth(of characters: NSRange) -> CGFloat {
            guard characters.length > 0, characters.location < text.length else { return 0 }
            let piece = text.substring(with: characters)
            let font = storage.attribute(.font, at: characters.location,
                                         effectiveRange: nil) as? NSFont
                ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
            let trimmed = (piece as NSString).substring(
                to: (piece as NSString).length - trailingWhitespaceLength(piece))
            guard !trimmed.isEmpty else { return 0 }
            return (trimmed as NSString).size(withAttributes: [.font: font]).width
        }
        var union: NSRect?
        enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, usedGlyphRange, _ in
            let characters = self.characterRange(forGlyphRange: usedGlyphRange,
                                                 actualGlyphRange: nil)
            let width = measuredWidth(of: characters)
            guard width > 0 else { return }
            let rect = NSRect(x: fragment.minX, y: fragment.minY,
                              width: width, height: fragment.height)
            union = union.map { $0.union(rect) } ?? rect
        }
        guard let result = union, result.width > 0 else { return .zero }
        return result
    }

    /// Number of trailing whitespace characters in a string.
    private func trailingWhitespaceLength(_ text: String) -> Int {
        var count = 0
        for character in text.reversed() {
            if character == " " || character == "\t" { count += 1 } else { break }
        }
        return count
    }

    /// Computes row band rectangles without drawing. Used by tests so
    /// assertions do not depend on when AppKit last painted.
    func debugRowRects(in storage: NSTextStorage) -> [(owner: Int, rect: NSRect)] {
        let attached: [NSTextContainer] = self.textContainers
        guard let container = attached.first else { return [] }
        // The caller passes the exact storage it wants measured: the smoke
        // suite opens several documents, and a shared layout manager can still
        // reference an earlier document's rows.
        let full = NSRange(location: 0, length: storage.length)
        var order: [Int] = []
        var merged: [Int: (owner: Int, rect: NSRect)] = [:]
        storage.enumerateAttributes(in: full) { attrs, range, _ in
            guard let rowID = attrs[.mdwriteTableRow] as? Int else { return }
            let owner = (attrs[.mdwriteTableIndex] as? Int) ?? -1
            let used = self.usedRect(forCharacterRange: self.trimmedRow(range, in: storage),
                                     container: container, storage: storage)
            guard used.width > 0, used.height > 0 else { return }
            if let existing = merged[rowID] {
                merged[rowID] = (owner, existing.rect.union(used))
            } else {
                merged[rowID] = (owner, used)
                order.append(rowID)
            }
        }
        var widest: [Int: CGFloat] = [:]
        for rowID in order {
            guard let entry = merged[rowID] else { continue }
            widest[entry.owner] = max(widest[entry.owner] ?? 0, entry.rect.width)
        }
        // Drawing offsets the band by the container origin, so the debug rects
        // have to as well. Returning raw container coordinates silently shifts
        // every rectangle by the text container inset, which leaves the
        // geometry assertions intact (a uniform offset preserves widths, right
        // edges, and relative order) while making any pixel sampled against
        // these rects land on the wrong row entirely.
        let origin = lastTableDrawOrigin
        return order.compactMap { rowID -> (owner: Int, rect: NSRect)? in
            guard let entry = merged[rowID] else { return nil }
            let width = widest[entry.owner] ?? entry.rect.width
            return (entry.owner, NSRect(x: entry.rect.minX + origin.x,
                                        y: entry.rect.minY + origin.y,
                                        width: width, height: entry.rect.height))
        }
    }

    /// Zebra banding and a hairline outline for projected table rows.
    ///
    /// Rows are decorated through storage attributes rather than by re-parsing,
    /// so scrolling stays cheap and matches the plan's bounded-work requirement.
    private func drawTableDecoration(forCharacterRange characters: NSRange, origin: NSPoint) {
        guard let storage = textStorage else { return }
        // `textContainer` is ambiguous on NSLayoutManager (property vs. method)
        // under Swift 6.4 and fails to type-check; the plural property does not
        // collide, so take the first container explicitly.
        let attached: [NSTextContainer] = self.textContainers
        guard let container = attached.first else { return }
        // A single row is reported as several attribute runs (paragraph style,
        // font, inline emphasis all split it), so every run sharing a row id is
        // merged before colour is chosen. Without this, one row would be striped.
        var order: [Int] = []
        var merged: [Int: (owner: Int, rect: NSRect)] = [:]
        storage.enumerateAttributes(in: characters) { attrs, range, _ in
            guard let rowID = attrs[.mdwriteTableRow] as? Int else { return }
            let owner = (attrs[.mdwriteTableIndex] as? Int) ?? -1
            // Trailing padding is real glyphs, so trim it before measuring or
            // the band would extend to the table's padded width.
            let content = self.trimmedRow(range, in: storage)
            let used = self.usedRect(forCharacterRange: content, container: container,
                                     storage: storage)
            guard used.width > 0, used.height > 0 else { return }
            let rect = NSRect(x: used.minX + origin.x, y: used.minY + origin.y,
                              width: used.width, height: used.height)
            if let existing = merged[rowID] {
                merged[rowID] = (owner, existing.rect.union(rect))
            } else {
                merged[rowID] = (owner, rect)
                order.append(rowID)
            }

        }
        guard !order.isEmpty else { return }
        // One width for the whole table, so every row lines up and the shading
        // stops at the same right edge.
        var widest: [Int: CGFloat] = [:]
        for rowID in order {
            guard let entry = merged[rowID] else { continue }
            widest[entry.owner] = max(widest[entry.owner] ?? 0, entry.rect.width)
        }
        // Exactly two row colours: alternate per table.
        //
        // Parity comes from the row's ordinal *within its own table*, not from
        // the order rows happen to be met in this draw call. AppKit splits
        // `drawBackground` into several calls whose boundaries depend on
        // scrolling, clipping, and the current layout, so counting within the
        // chunk restarts the alternation at an arbitrary row. Two rows that
        // should differ then both paint shaded. `.mdwriteTableIsFirstRow`
        // marks where each table begins, so the ordinal is recoverable by
        // walking the storage in document order.
        var ordinal: [Int: Int] = [:]
        var running: [Int: Int] = [:]
        var isFirst: Set<Int> = []
        storage.enumerateAttribute(.mdwriteTableIsFirstRow, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let rowID = storage.attribute(.mdwriteTableRow, at: range.location, effectiveRange: nil) as? Int,
                  (value as? Bool) == true else { return }
            isFirst.insert(rowID)
        }
        storage.enumerateAttribute(.mdwriteTableRow, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let rowID = value as? Int,
                  let owner = storage.attribute(.mdwriteTableIndex, at: range.location, effectiveRange: nil) as? Int else { return }
            let position = isFirst.contains(rowID) ? 0 : (running[owner] ?? 0)
            ordinal[rowID] = position
            running[owner] = position + 1
        }
        var bands: [NSRect] = []
        for rowID in order {
            guard let entry = merged[rowID] else { continue }
            let row = ordinal[rowID] ?? 0
            let width = widest[entry.owner] ?? entry.rect.width
            let rect = NSRect(x: entry.rect.minX, y: entry.rect.minY,
                              width: width, height: entry.rect.height)
            bands.append(rect)
            guard row % 2 == 0 else { continue }
            NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? NSColor(white: 1, alpha: 0.04) : NSColor(white: 0, alpha: 0.035)
            }.setFill()
            NSBezierPath(rect: rect).fill()
        }
        guard !bands.isEmpty else { return }
        // Merge rows that share a table into one box, so a table reads as a single
        // outlined grid rather than a stack of separate row boxes.
        var boxes: [NSRect] = []
        for band in bands {
            if let last = boxes.last,
               abs(last.maxY - band.minY) <= 2, abs(last.minX - band.minX) <= 2 {
                boxes[boxes.count - 1] = last.union(band)
            } else {
                boxes.append(band)
            }
        }
        guard !boxes.isEmpty else { return }
        let separator = NSColor.separatorColor.withAlphaComponent(0.35)
        separator.setStroke()
        for box in boxes {
            let path = NSBezierPath()
            path.lineWidth = 1
            // Crisp hairlines: inset by half a point so a 1pt stroke lands on
            // the pixel grid instead of smearing across two rows.
            let rect = NSRect(x: box.minX.rounded(), y: box.minY.rounded(),
                              width: box.width.rounded(), height: box.height.rounded())
            path.appendRect(NSInsetRect(rect, 0.5, 0.5))
            path.stroke()
        }
    }
}
