import AppKit

@MainActor
private final class StorageEditObserver: NSObject, @preconcurrency NSTextStorageDelegate {
    var characterEvents = 0
    var attributeEvents = 0

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing mask: NSTextStorageEditActions,
                     range: NSRange, changeInLength delta: Int) {
        if mask.contains(.editedCharacters) { characterEvents += 1 }
        if mask.contains(.editedAttributes) { attributeEvents += 1 }
    }
}

@MainActor
enum NativeStorageChecks {
    static func run() throws {
        func expect(_ condition: Bool, _ message: String) throws {
            if !condition {
                throw NSError(domain: "mdwrite.storage", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        let source = "A 👩🏽‍💻 é 日本語 क्‍ष 🇫🇮\r\na\nb\n"
        let font = NSFont.monospacedSystemFont(ofSize: 20, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        let input = NSAttributedString(string: source, attributes: [.font: font, .paragraphStyle: paragraph])
        let storage = MarkdownTextStorage(attributedString: input)
        let reference = NSTextStorage()
        reference.setAttributedString(input)
        reference.ensureAttributesAreFixed(in: NSRange(location: 0, length: reference.length))
        try expect(!storage.fixesAttributesLazily, "storage deferred native attribute fixing")
        try expect(Data(storage.string.utf8) == Data(source.utf8), "font fixing changed source bytes")
        for offset in 0..<reference.length {
            guard let actual = storage.attribute(.font, at: offset, effectiveRange: nil) as? NSFont,
                  let expected = reference.attribute(.font, at: offset, effectiveRange: nil) as? NSFont else {
                throw NSError(domain: "mdwrite.storage", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "native font fallback is absent"])
            }
            // Native fallback fonts may be distinct private objects even when
            // their public face, traits, size and layout metrics are identical.
            try expect(actual.fontName == expected.fontName && actual.pointSize == expected.pointSize
                       && actual.fontDescriptor.symbolicTraits == expected.fontDescriptor.symbolicTraits
                       && actual.ascender == expected.ascender && actual.descender == expected.descender
                       && actual.capHeight == expected.capHeight && actual.xHeight == expected.xHeight,
                       "native Unicode font fallback differs at UTF16 offset \(offset)")
            let actualParagraph = storage.attribute(.paragraphStyle, at: offset, effectiveRange: nil) as? NSParagraphStyle
            let expectedParagraph = reference.attribute(.paragraphStyle, at: offset, effectiveRange: nil) as? NSParagraphStyle
            try expect(actualParagraph?.isEqual(expectedParagraph) == true, "paragraph fixing differs")
        }
        let snapshot = storage.string
        let observer = StorageEditObserver()
        storage.delegate = observer
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: NSRange(location: 0, length: 1))
        storage.addAttribute(.font, value: font, range: NSRange(location: 0, length: storage.length))
        storage.endEditing()
        try expect(observer.characterEvents == 0 && observer.attributeEvents > 0,
                   "derived font/color fixing reported a character edit")
        try expect(Data(storage.string.utf8) == Data(snapshot.utf8), "attribute edits invalidated source content")
        storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "Current")
        try expect(observer.characterEvents == 1, "source mutation did not report one character edit")
        try expect(Data(snapshot.utf8) == Data(source.utf8), "captured source snapshot changed with mutable storage")
        try expect(storage.string.hasPrefix("Current "), "character edit did not refresh cached source")
        // The superclass archives its delegate, which is intentionally omitted
        // from this storage-only roundtrip (the observer is not NSSecureCoding).
        storage.delegate = nil
        let archive = try NSKeyedArchiver.archivedData(withRootObject: storage, requiringSecureCoding: true)
        let restored = try NSKeyedUnarchiver.unarchivedObject(ofClass: MarkdownTextStorage.self, from: archive)
        try expect(restored.map { Data($0.string.utf8) } == Data(storage.string.utf8),
                   "secure storage roundtrip changed source")
        try expect(MarkdownTextStorage(string: "plain").string == "plain",
                   "plain source initializer failed")
        try expect(MarkdownTextStorage(string: "styled", attributes: [.font: font]).string == "styled",
                   "attributed source initializer failed")
        // Single-key longest ranges must traverse unrelated fragmented styles
        // and return correct absence ranges, including restricted query bounds.
        let fragmentInput = NSMutableAttributedString(string: String(repeating: "abcdef", count: 16),
                                                      attributes: [.font: font])
        let marker = NSAttributedString.Key("mdwrite.storage-test")
        for offset in 0..<fragmentInput.length {
            fragmentInput.addAttribute(.foregroundColor, value: offset % 2 == 0 ? NSColor.red : NSColor.blue,
                                       range: NSRange(location: offset, length: 1))
        }
        fragmentInput.addAttribute(marker, value: "shared", range: NSRange(location: 12, length: 60))
        let fragments = MarkdownTextStorage(attributedString: fragmentInput)
        let native = NSTextStorage(attributedString: fragmentInput)
        native.ensureAttributesAreFixed(in: NSRange(location: 0, length: native.length))
        for limit in [NSRange(location: 0, length: native.length), NSRange(location: 7, length: 78)] {
            for offset in limit.location..<NSMaxRange(limit) {
                for key in [marker, .glyphInfo, .font, .foregroundColor] {
                    var actualRange = NSRange(), expectedRange = NSRange()
                    let actual = fragments.attribute(key, at: offset, longestEffectiveRange: &actualRange, in: limit)
                    let expected = native.attribute(key, at: offset, longestEffectiveRange: &expectedRange, in: limit)
                    try expect(actualRange == expectedRange && (actual as? NSObject)?.isEqual(expected) ==
                               (expected != nil ? true : nil), "single-key longest attribute lookup differs")
                    let direct = fragments.attribute(key, at: offset, effectiveRange: nil)
                    try expect((direct as? NSObject)?.isEqual(expected) == (expected != nil ? true : nil),
                               "single-key direct attribute lookup differs")
                }
                var actualRange = NSRange(), expectedRange = NSRange()
                let actual = fragments.attributes(at: offset, longestEffectiveRange: &actualRange, in: limit)
                let expected = native.attributes(at: offset, longestEffectiveRange: &expectedRange, in: limit)
                try expect(actualRange == expectedRange && NSDictionary(dictionary: actual).isEqual(to: expected),
                           "whole-dictionary longest attribute lookup differs")
            }
        }
        print("PASS: eager native fixing, Unicode fonts, immutable cached snapshots, edit notifications, and secure storage coding")
    }
}
