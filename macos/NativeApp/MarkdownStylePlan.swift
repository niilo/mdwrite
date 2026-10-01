import AppKit
import EditorCore

// Only Foundation objects are used while building plans. AppKit values are
// resolved on the main actor from these immutable, Sendable descriptions.
struct StyleFont: Hashable, Sendable {
    enum Family: Int, Sendable { case body, code }
    var size: CGFloat
    var family: Family
    var traits: Int = 0
}

private enum StyleFontTrait { case boldFontMask, italicFontMask }
private struct StyleFontManager {
    static let shared = StyleFontManager()
    func convert(_ font: StyleFont, toSize size: CGFloat) -> StyleFont {
        var result = font; result.size = size; return result
    }
    func convert(_ font: StyleFont, toHaveTrait trait: StyleFontTrait) -> StyleFont {
        var result = font; result.traits |= trait == .boldFontMask ? 1 : 2; return result
    }
}

enum StyleColor: Int, Hashable, Sendable { case text, secondary, tertiary, link, code, table, hardBreak }
struct StyleParagraphValue: Hashable, Sendable {
    var lineSpacing: CGFloat = 0.25
    var paragraphSpacing: CGFloat = 0
    var paragraphSpacingBefore: CGFloat = 0
    var firstLineHeadIndent: CGFloat = 0
    var headIndent: CGFloat = 0
}
private final class StyleParagraph: NSObject, NSCopying, NSMutableCopying {
    var value = StyleParagraphValue()
    var lineSpacing: CGFloat { get { value.lineSpacing } set { value.lineSpacing = newValue } }
    var paragraphSpacing: CGFloat { get { value.paragraphSpacing } set { value.paragraphSpacing = newValue } }
    var paragraphSpacingBefore: CGFloat { get { value.paragraphSpacingBefore } set { value.paragraphSpacingBefore = newValue } }
    var firstLineHeadIndent: CGFloat { get { value.firstLineHeadIndent } set { value.firstLineHeadIndent = newValue } }
    var headIndent: CGFloat { get { value.headIndent } set { value.headIndent = newValue } }
    func copy(with zone: NSZone? = nil) -> Any { let copy = StyleParagraph(); copy.value = value; return copy }
    func mutableCopy(with zone: NSZone? = nil) -> Any { copy(with: zone) }
    override func isEqual(_ object: Any?) -> Bool { (object as? StyleParagraph)?.value == value }
    override var hash: Int { value.hashValue }
}

struct MarkdownStyle: Hashable, Sendable {
    let font: StyleFont
    let color: StyleColor
    let paragraph: StyleParagraphValue
    let background: StyleColor?
    let tableBackground: StyleColor?
    let codeBackground: StyleColor?
    let quoteDepth: Int?
    let rule: Bool?
    let codeContinues: Bool?
    let underline: Int?
    let strikethrough: Int?

    fileprivate init(_ attributes: [NSAttributedString.Key: Any]) {
        font = attributes[.font] as! StyleFont
        color = attributes[.foregroundColor] as! StyleColor
        paragraph = (attributes[.paragraphStyle] as! StyleParagraph).value
        background = attributes[.backgroundColor] as? StyleColor
        tableBackground = attributes[.mdwriteTableBackground] as? StyleColor
        codeBackground = attributes[.mdwriteCodeBackground] as? StyleColor
        quoteDepth = attributes[.mdwriteQuoteDepth] as? Int
        rule = attributes[.mdwriteRule] as? Bool
        codeContinues = attributes[.mdwriteCodeContinues] as? Bool
        underline = attributes[.underlineStyle] as? Int
        strikethrough = attributes[.strikethroughStyle] as? Int
    }
}
fileprivate final class MarkdownStyleReference: Sendable {
    let value: MarkdownStyle
    init(_ value: MarkdownStyle) { self.value = value }
}

struct MarkdownStyleRun: Sendable {
    let range: NSRange
    fileprivate let reference: MarkdownStyleReference
    var style: MarkdownStyle { reference.value }

    init(range: NSRange, style: MarkdownStyle) {
        self.range = range
        reference = MarkdownStyleReference(style)
    }

    fileprivate init(range: NSRange, reference: MarkdownStyleReference) {
        self.range = range
        self.reference = reference
    }
}
struct MarkdownStylePlan: Sendable { let length: Int; let runs: [MarkdownStyleRun]; let wordCount: Int }

private final class StyleRegexCache: @unchecked Sendable {
    static let shared = StyleRegexCache()
    let lock = NSLock()
    var expressions: [String: NSRegularExpression] = [:]
    static func matches(_ pattern: String, in source: String) -> [NSTextCheckingResult] {
        shared.lock.lock()
        let expression: NSRegularExpression
        if let cached = shared.expressions[pattern] { expression = cached }
        else { expression = try! NSRegularExpression(pattern: pattern); shared.expressions[pattern] = expression }
        shared.lock.unlock()
        return expression.matches(in: source, range: NSRange(location: 0, length: (source as NSString).length))
    }
}

/// Builder-owned ordered attribute overlays. Native attributed-string mutation
/// repeatedly splits dense style runs; this buffer logs writes and resolves their
/// precedence once, without boxing descriptor values into Objective-C objects.
/// Mutable paragraph objects remain local until immutable styles are extracted.
private final class MarkdownStyleBuffer {
    private enum Value { case assigned(Any), removed }
    private struct Write {
        let key: NSAttributedString.Key
        let value: Value
        let range: NSRange
    }
    private struct Event { let offset: Int; let index: Int; let starts: Bool }
    private struct Node {
        let index: Int
        let priority: UInt64
        var left: Int? = nil
        var right: Int? = nil
        var maxEnd: Int
        var maxSequence: Int
    }
    private struct Heap {
        var values: [Int] = []
        mutating func push(_ value: Int) {
            values.append(value)
            var index = values.count - 1
            while index > 0 {
                let parent = (index - 1) / 2
                if values[parent] >= values[index] { break }
                values.swapAt(parent, index); index = parent
            }
        }
        mutating func pop() {
            guard !values.isEmpty else { return }
            if values.count == 1 { values.removeLast(); return }
            values[0] = values.removeLast()
            var index = 0
            while index * 2 + 1 < values.count {
                let left = index * 2 + 1, right = left + 1
                let child = right < values.count && values[right] > values[left] ? right : left
                if values[index] >= values[child] { break }
                values.swapAt(index, child); index = child
            }
        }
    }
    private let length: Int
    private var writes: [Write] = []
    private var perKey: [NSAttributedString.Key: [Int]] = [:]
    private var roots: [NSAttributedString.Key: Int] = [:]
    private var indexedKeys: Set<NSAttributedString.Key> = []
    private var nodes: [Node] = []

    init(string: String) { length = (string as NSString).length }
    func beginEditing() {}
    func endEditing() {}

    func setAttributes(_ attributes: [NSAttributedString.Key: Any], range: NSRange) {
        for key in perKey.keys where attributes[key] == nil { append(key, value: .removed, range: range) }
        addAttributes(attributes, range: range)
    }
    func addAttributes(_ attributes: [NSAttributedString.Key: Any], range: NSRange) {
        for (key, value) in attributes { addAttribute(key, value: value, range: range) }
    }
    func addAttribute(_ key: NSAttributedString.Key, value: Any, range: NSRange) {
        append(key, value: .assigned(value), range: range)
    }
    private func append(_ key: NSAttributedString.Key, value: Value, range: NSRange) {
        precondition(range.location >= 0 && NSMaxRange(range) <= length)
        guard range.length > 0 else { return }
        let index = writes.count
        writes.append(Write(key: key, value: value, range: range))
        perKey[key, default: []].append(index)
        if indexedKeys.contains(key) { roots[key] = insert(index, into: roots[key]) }
    }

    func value(for key: NSAttributedString.Key, at location: Int) -> Any? {
        precondition(location >= 0 && location < length)
        if !indexedKeys.contains(key) {
            indexedKeys.insert(key)
            for index in perKey[key] ?? [] { roots[key] = insert(index, into: roots[key]) }
        }
        var best = -1
        query(roots[key], at: location, best: &best)
        guard best >= 0 else { return nil }
        if case let .assigned(value) = writes[best].value { return value }
        return nil
    }

    private func refresh(_ node: Int) {
        let left = nodes[node].left, right = nodes[node].right, index = nodes[node].index
        nodes[node].maxEnd = max(NSMaxRange(writes[index].range), max(left.map { nodes[$0].maxEnd } ?? 0,
                                                                   right.map { nodes[$0].maxEnd } ?? 0))
        nodes[node].maxSequence = max(index, max(left.map { nodes[$0].maxSequence } ?? -1,
                                                 right.map { nodes[$0].maxSequence } ?? -1))
    }
    private func before(_ a: Int, _ b: Int) -> Bool {
        let x = writes[a].range.location, y = writes[b].range.location
        return x < y || x == y && a < b
    }
    private func rotateRight(_ root: Int) -> Int {
        let next = nodes[root].left!
        nodes[root].left = nodes[next].right
        nodes[next].right = root
        refresh(root); refresh(next)
        return next
    }
    private func rotateLeft(_ root: Int) -> Int {
        let next = nodes[root].right!
        nodes[root].right = nodes[next].left
        nodes[next].left = root
        refresh(root); refresh(next)
        return next
    }
    private func insert(_ index: Int, into root: Int?) -> Int {
        guard let root else {
            // Deterministic SplitMix64 priorities keep source-ordered writes balanced.
            var priority = UInt64(index) &+ 0x9e3779b97f4a7c15
            priority = (priority ^ (priority >> 30)) &* 0xbf58476d1ce4e5b9
            priority = (priority ^ (priority >> 27)) &* 0x94d049bb133111eb
            priority ^= priority >> 31
            nodes.append(Node(index: index, priority: priority, maxEnd: NSMaxRange(writes[index].range), maxSequence: index))
            return nodes.count - 1
        }
        if before(index, nodes[root].index) {
            let child = insert(index, into: nodes[root].left)
            nodes[root].left = child
            if nodes[child].priority > nodes[root].priority { return rotateRight(root) }
        } else {
            let child = insert(index, into: nodes[root].right)
            nodes[root].right = child
            if nodes[child].priority > nodes[root].priority { return rotateLeft(root) }
        }
        refresh(root)
        return root
    }
    private func query(_ root: Int?, at location: Int, best: inout Int) {
        guard let root, nodes[root].maxEnd > location, nodes[root].maxSequence > best else { return }
        let node = nodes[root], range = writes[node.index].range
        if range.location > location {
            query(node.left, at: location, best: &best)
            return
        }
        if NSMaxRange(range) > location { best = max(best, node.index) }
        let leftSequence = node.left.map { nodes[$0].maxSequence } ?? -1
        let rightSequence = node.right.map { nodes[$0].maxSequence } ?? -1
        if leftSequence > rightSequence {
            query(node.left, at: location, best: &best); query(node.right, at: location, best: &best)
        } else {
            query(node.right, at: location, best: &best); query(node.left, at: location, best: &best)
        }
    }

    func enumerateAttributes(in range: NSRange, using block: ([NSAttributedString.Key: Any], NSRange, UnsafeMutablePointer<ObjCBool>) -> Void) {
        precondition(range.location == 0 && range.length == length)
        guard length > 0 else { return }
        var events: [Event] = []
        events.reserveCapacity(writes.count * 2)
        for (index, write) in writes.enumerated() {
            events.append(Event(offset: write.range.location, index: index, starts: true))
            events.append(Event(offset: NSMaxRange(write.range), index: index, starts: false))
        }
        events.sort { $0.offset < $1.offset }
        var heaps: [NSAttributedString.Key: Heap] = [:]
        var active = [Bool](repeating: false, count: writes.count)
        var attributes: [NSAttributedString.Key: Any] = [:]
        var cursor = 0, offset = 0
        var stop = ObjCBool(false)
        while cursor < events.count {
            let edge = events[cursor].offset
            if edge > offset {
                block(attributes, NSRange(location: offset, length: edge - offset), &stop)
                if stop.boolValue { return }
            }
            var changed: Set<NSAttributedString.Key> = []
            while cursor < events.count && events[cursor].offset == edge {
                let event = events[cursor], key = writes[event.index].key
                changed.insert(key)
                active[event.index] = event.starts
                if event.starts { heaps[key, default: Heap()].push(event.index) }
                cursor += 1
            }
            for key in changed {
                while let root = heaps[key]?.values.first, !active[root] { heaps[key]?.pop() }
                if let root = heaps[key]?.values.first, case let .assigned(value) = writes[root].value {
                    attributes[key] = value
                } else { attributes.removeValue(forKey: key) }
            }
            offset = edge
        }
        if offset < length { block(attributes, NSRange(location: offset, length: length - offset), &stop) }
    }
}


enum MarkdownStylePlanBuilder {
    static func build(_ analysis: MarkdownAnalysis) -> MarkdownStylePlan {
        let source = analysis.source
        let storage = MarkdownStyleBuffer(string: source)
        let fontSize: CGFloat = 1
        let text = source as NSString
        let whole = NSRange(location: 0, length: text.length)
        let font = StyleFont(size: fontSize, family: .body)
        let paragraph = StyleParagraph()
        paragraph.lineSpacing = fontSize * 0.25
        // Explicit newlines determine paragraph gaps. Enter never inserts a gap for styling.
        paragraph.paragraphSpacing = 0
        let base: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: StyleColor.text, .paragraphStyle: paragraph
        ]
        let runs = analysis.runs.sorted { $0.range.location < $1.range.location }
        let fences = analysis.blocks.filter { $0.kind == .fencedCode }
        let codeRanges = fences.map(\.range) + runs.filter(\.isCodeBlock).map { text.paragraphRange(for: $0.range) }
        let codeIntervals = mergeIntervals(codeRanges)
        func isCode(_ range: NSRange) -> Bool { intervalsOverlap(codeIntervals, range) }
        let codeFont = StyleFont(size: fontSize * 0.9, family: .code)
        let codeColor = StyleColor.code
        let tableColor = StyleColor.table
        let headingScales: [CGFloat] = [1.8, 1.5, 1.3, 1.18, 1.1, 1.04]
        var headingLines: Set<Int> = []
        var tableHeaders: Set<Int> = []
        var nonRuleLines: Set<Int> = []
        func dim(_ range: NSRange) {
            storage.addAttribute(.foregroundColor, value: StyleColor.tertiary, range: range)
        }
        storage.beginEditing()
        defer { storage.endEditing() }
        storage.setAttributes(base, range: whole)

        for run in runs {
            let line = text.paragraphRange(for: run.range)
            let kinds = run.presentation?.components.map(\.kind) ?? []
            let quoteDepth = kinds.filter { $0 == .blockQuote }.count
            let listDepth = kinds.filter { $0 == .orderedList || $0 == .unorderedList }.count
            let style = paragraph.mutableCopy() as! StyleParagraph
            style.firstLineHeadIndent = CGFloat(quoteDepth) * 24 + CGFloat(max(0, listDepth - 1)) * 20
            style.headIndent = CGFloat(quoteDepth) * 24 + CGFloat(listDepth) * 20
            storage.addAttribute(.paragraphStyle, value: style, range: line)
            var runFont = font
            if quoteDepth > 0 {
                runFont = StyleFontManager.shared.convert(runFont, toHaveTrait: .italicFontMask)
                storage.addAttribute(.foregroundColor, value: StyleColor.secondary, range: line)
                storage.addAttribute(.mdwriteQuoteDepth, value: quoteDepth, range: line)
            }
            for kind in kinds {
                if case let .header(level) = kind {
                    runFont = StyleFontManager.shared.convert(font, toSize: fontSize * headingScales[min(6, max(1, level)) - 1])
                    runFont = StyleFontManager.shared.convert(runFont, toHaveTrait: .boldFontMask)
                    style.paragraphSpacingBefore = fontSize * 0.5
                    style.paragraphSpacing = fontSize * 0.25
                    storage.addAttribute(.paragraphStyle, value: style, range: line)
                    headingLines.insert(line.location)
                }
                if kind == .tableHeaderRow {
                    runFont = StyleFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                    tableHeaders.insert(line.location)
                }
                if case .table = kind {
                    storage.addAttribute(.mdwriteTableBackground, value: tableColor, range: line)
                }
            }
            if run.inlineIntent.contains(.stronglyEmphasized) {
                runFont = StyleFontManager.shared.convert(runFont, toHaveTrait: .boldFontMask)
            }
            if run.inlineIntent.contains(.emphasized) {
                runFont = StyleFontManager.shared.convert(runFont, toHaveTrait: .italicFontMask)
            }
            storage.addAttribute(.font, value: runFont, range: run.range)
            if run.inlineIntent.contains(.strikethrough) {
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: run.range)
            }
            if run.link != nil || run.image != nil {
                storage.addAttributes([.foregroundColor: StyleColor.link,
                                       .underlineStyle: NSUnderlineStyle.single.rawValue], range: run.range)
            }
            if run.inlineIntent.contains(.code) {
                storage.addAttributes([.font: codeFont, .foregroundColor: StyleColor.text,
                                       .backgroundColor: codeColor], range: run.range)
            }
            if run.inlineIntent.contains(.inlineHTML) || run.inlineIntent.contains(.blockHTML) {
                storage.addAttributes([.font: codeFont, .foregroundColor: StyleColor.secondary], range: run.range)
            }
        }

        // Decorate source-only markers omitted from Foundation's rendered runs.
        for block in analysis.blocks where !isCode(block.range) {
            for marker in block.markers { dim(marker) }
        }
        for span in analysis.inlineSpans where !isCode(span.content) {
            let semantic = intersectingRuns(runs, span.content).contains {
                NSIntersectionRange($0.range, span.content).length > 0 &&
                    (!$0.inlineIntent.intersection([.emphasized, .stronglyEmphasized]).isEmpty || $0.link != nil || $0.image != nil)
            }
            if semantic { for marker in span.markers { dim(marker) } }
        }
        for location in headingLines {
            let line = text.paragraphRange(for: NSRange(location: location, length: 0))
            let next = NSMaxRange(line)
            if next < text.length {
                let underline = text.lineRange(for: NSRange(location: next, length: 0))
                if matches(#"^ {0,3}(?:=+|-+)[ \t]*$"#, in: text.substring(with: underline).trimmingCharacters(in: .newlines)).first != nil {
                    dim(underline)
                    nonRuleLines.insert(underline.location)
                }
            }
        }
        for location in tableHeaders {
            let header = text.lineRange(for: NSRange(location: location, length: 0))
            let next = NSMaxRange(header)
            if next < text.length {
                let delimiter = text.lineRange(for: NSRange(location: next, length: 0))
                dim(delimiter)
                storage.addAttribute(.mdwriteTableBackground, value: tableColor, range: delimiter)
                nonRuleLines.insert(delimiter.location)
            }
        }
        var offset = 0
        let decorationCharacters = CharacterSet(charactersIn: ">[-*_\\|:&")
        while offset < text.length {
            let lineRange = text.lineRange(for: NSRange(location: offset, length: 0))
            let line = text.substring(with: lineRange).trimmingCharacters(in: .newlines)
            if !isCode(lineRange) {
                let first = line.drop(while: { $0 == " " || $0 == "\t" }).first
                let startsNumber = first.map { ("0"..."9").contains($0) } ?? false
                if !startsNumber, !line.hasSuffix("  "), line.rangeOfCharacter(from: decorationCharacters) == nil {
                    offset = NSMaxRange(lineRange)
                    continue
                }
                func absolute(_ range: NSRange) -> NSRange { NSRange(location: offset + range.location, length: range.length) }
                if let quote = matches(#"^([ \t]*(?:>[ \t]?)+)"#, in: line).first {
                    dim(absolute(quote.range))
                    if storage.value(for: .mdwriteQuoteDepth, at: offset) == nil {
                        let depth = (line as NSString).substring(with: quote.range).filter { $0 == ">" }.count
                        let style = paragraph.mutableCopy() as! StyleParagraph
                        style.firstLineHeadIndent = CGFloat(depth) * 24
                        style.headIndent = style.firstLineHeadIndent
                        storage.addAttributes([.paragraphStyle: style, .mdwriteQuoteDepth: depth], range: lineRange)
                    }
                }
                if let list = matches(#"^([ \t]*)([-+*]|[0-9]+[.)])[ \t]+(?:\[([ xX])\][ \t]+)?"#, in: line).first {
                    dim(absolute(list.range))
                    let existing = storage.value(for: .paragraphStyle, at: offset) as? StyleParagraph
                    if existing?.headIndent == 0 {
                        let style = paragraph.mutableCopy() as! StyleParagraph
                        let indentation = (line as NSString).substring(with: list.range(at: 1))
                        style.firstLineHeadIndent = CGFloat(indentation.count / 2) * 20
                        style.headIndent = style.firstLineHeadIndent + 20
                        storage.addAttribute(.paragraphStyle, value: style, range: lineRange)
                    }
                    if list.range(at: 3).location != NSNotFound,
                       (line as NSString).substring(with: list.range(at: 3)).lowercased() == "x" {
                        let content = NSRange(location: offset + NSMaxRange(list.range), length: (line as NSString).length - NSMaxRange(list.range))
                        storage.addAttributes([.foregroundColor: StyleColor.secondary,
                                               .strikethroughStyle: NSUnderlineStyle.single.rawValue], range: content)
                    }
                }
                if !nonRuleLines.contains(offset), matches(#"^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$"#, in: line).first != nil {
                    dim(lineRange)
                    storage.addAttributes([.mdwriteRule: true, .font: StyleFontManager.shared.convert(font, toSize: fontSize * 0.65)], range: lineRange)
                }
                if let prefix = matches(#"^ {0,3}(?:>[ \t]?)+"#, in: line).first,
                   matches(#"^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$"#,
                           in: (line as NSString).substring(from: NSMaxRange(prefix.range))).first != nil {
                    dim(lineRange)
                    storage.addAttribute(.mdwriteRule, value: true, range: lineRange)
                }
                if storage.value(for: .mdwriteTableBackground, at: offset) != nil {
                    for pipe in matches(#"(?<!\\)\|"#, in: line) { dim(absolute(pipe.range)) }
                }
                if let definition = matches(#"^ {0,3}\[[^\]]+\]:[ \t]*"#, in: line).first { dim(absolute(definition.range)) }
                for url in matches(#"(?:https?://|mailto:)[^\s<>]+"#, in: line) {
                    let range = absolute(url.range)
                    if !intersectingRuns(runs, range).contains(where: { $0.inlineIntent.contains(.code) && NSIntersectionRange($0.range, range).length > 0 }) {
                        storage.addAttributes([.foregroundColor: StyleColor.link,
                                               .underlineStyle: NSUnderlineStyle.single.rawValue], range: range)
                    }
                }
                if let hardBreak = matches(#"(?: {2,}|\\)$"#, in: line).first {
                    storage.addAttribute(.backgroundColor, value: StyleColor.hardBreak, range: absolute(hardBreak.range))
                }
                for note in matches(#"\[\^[^\]]+\]"#, in: line) {
                    storage.addAttributes([.foregroundColor: StyleColor.link,
                                           .font: StyleFontManager.shared.convert(font, toSize: fontSize * 0.85)], range: absolute(note.range))
                }
                for escape in matches(##"\\[!"#$%&'()*+,\-./:;<=>?@\[\]\\^_`{|}~]|&(?:#[0-9]+|#x[0-9a-fA-F]+|[A-Za-z][A-Za-z0-9]+);"##, in: line) {
                    dim(absolute(escape.range))
                }
            }
            offset = NSMaxRange(lineRange)
        }

        let codeParagraph = paragraph.mutableCopy() as! StyleParagraph
        codeParagraph.lineSpacing = fontSize * 0.2
        for range in codeRanges {
            let existing = storage.value(for: .paragraphStyle, at: range.location) as? StyleParagraph
            let style = codeParagraph.mutableCopy() as! StyleParagraph
            style.headIndent = existing?.headIndent ?? 0
            style.firstLineHeadIndent = existing?.firstLineHeadIndent ?? 0
            storage.addAttributes([.font: codeFont, .foregroundColor: StyleColor.text,
                .backgroundColor: codeColor, .mdwriteCodeBackground: codeColor,
                .paragraphStyle: style, .underlineStyle: 0, .strikethroughStyle: 0], range: range)
        }
        for fence in fences {
            storage.addAttribute(.mdwriteCodeContinues, value: fence.markers.count == 1, range: fence.range)
            for marker in fence.markers { dim(marker) }
        }
        var styled: [MarkdownStyleRun] = []
        // Dense documents contain millions of source intervals but comparatively
        // few canonical styles. Share only immutable descriptor values; source
        // ranges and style equality retain their existing value semantics.
        var interned: [MarkdownStyle: MarkdownStyleReference] = [:]
        storage.enumerateAttributes(in: whole) { attributes, range, _ in
            let style = MarkdownStyle(attributes)
            if let last = styled.last, last.style == style, NSMaxRange(last.range) == range.location {
                styled[styled.count - 1] = MarkdownStyleRun(range: NSUnionRange(last.range, range), reference: last.reference)
            } else {
                let reference: MarkdownStyleReference
                if let existing = interned[style] { reference = existing }
                else { reference = MarkdownStyleReference(style); interned[style] = reference }
                styled.append(MarkdownStyleRun(range: range, reference: reference))
            }
        }
        return MarkdownStylePlan(length: text.length, runs: styled, wordCount: analysis.wordCount)
    }

    private static func mergeIntervals(_ ranges: [NSRange]) -> [NSRange] {
        var merged: [NSRange] = []
        for range in ranges.sorted(by: { $0.location < $1.location }) {
            if let last = merged.last, NSMaxRange(last) >= range.location {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else { merged.append(range) }
        }
        return merged
    }

    private static func intersectingRuns(_ runs: [MarkdownSyntaxRun], _ range: NSRange) -> ArraySlice<MarkdownSyntaxRun> {
        var low = 0, high = runs.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(runs[mid].range) <= range.location { low = mid + 1 } else { high = mid }
        }
        let start = low
        while low < runs.count && runs[low].range.location < NSMaxRange(range) { low += 1 }
        return runs[start..<low]
    }

    private static func intervalsOverlap(_ intervals: [NSRange], _ range: NSRange) -> Bool {
        var low = 0, high = intervals.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(intervals[mid]) <= range.location { low = mid + 1 } else { high = mid }
        }
        return low < intervals.count && intervals[low].location < NSMaxRange(range)
    }

    private static func matches(_ pattern: String, in source: String) -> [NSTextCheckingResult] {
        StyleRegexCache.matches(pattern, in: source)
    }
}
