import AppKit

/// An eager native attribute-fixing candidate for the large-document probe.
/// The main-actor document owns this object, just like ordinary NSTextStorage.
/// Native fixing (including Unicode font fallback) is intentionally preserved;
/// each edit is reported through the inherited change-management pipeline.
final class MarkdownTextStorage: NSTextStorage {
    private let backing = NSMutableAttributedString(string: "")
    // AppKit repeatedly bridges this primitive back to NSString during layout.
    // Reuse one immutable Swift value (and its UTF-16 conversion cache) per
    // character revision; attribute changes must not rematerialize the source.
    private var cachedString: String? = ""

    override init() {
        super.init()
    }

    override init(attributedString source: NSAttributedString) {
        super.init()
        setAttributedString(source)
    }

    override init(string: String) {
        super.init()
        replaceCharacters(in: NSRange(location: 0, length: 0), with: string)
    }

    override init(string: String, attributes: [NSAttributedString.Key: Any]?) {
        super.init()
        setAttributedString(NSAttributedString(string: string, attributes: attributes))
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    required init?(pasteboardPropertyList propertyList: Any, ofType type: NSPasteboard.PasteboardType) {
        super.init(pasteboardPropertyList: propertyList, ofType: type)
    }

    override class var supportsSecureCoding: Bool { true }
    override var classForCoder: AnyClass { MarkdownTextStorage.self }

    override var string: String {
        if let cachedString { return cachedString }
        let snapshot = backing.string
        cachedString = snapshot
        return snapshot
    }

    override var fixesAttributesLazily: Bool { false }

    override func attributes(at location: Int, effectiveRange range: NSRangePointer?) -> [NSAttributedString.Key: Any] {
        backing.attributes(at: location, effectiveRange: range)
    }

    // Native fixing frequently asks for one absent attribute across many style
    // runs. Inherited longest-range lookup walks our dictionary primitive and
    // bridges every run into Swift; the concrete backing can answer natively.
    override func attribute(_ attrName: NSAttributedString.Key, at location: Int,
                            effectiveRange range: NSRangePointer?) -> Any? {
        backing.attribute(attrName, at: location, effectiveRange: range)
    }

    override func attribute(_ attrName: NSAttributedString.Key, at location: Int,
                            longestEffectiveRange range: NSRangePointer?, in rangeLimit: NSRange) -> Any? {
        backing.attribute(attrName, at: location, longestEffectiveRange: range, in: rangeLimit)
    }

    override func attributes(at location: Int, longestEffectiveRange range: NSRangePointer?,
                             in rangeLimit: NSRange) -> [NSAttributedString.Key: Any] {
        backing.attributes(at: location, longestEffectiveRange: range, in: rangeLimit)
    }

    override func replaceCharacters(in range: NSRange, with string: String) {
        backing.replaceCharacters(in: range, with: string)
        cachedString = nil
        edited([.editedCharacters, .editedAttributes], range: range,
               changeInLength: (string as NSString).length - range.length)
    }

    override func setAttributes(_ attributes: [NSAttributedString.Key: Any]?, range: NSRange) {
        backing.setAttributes(attributes, range: range)
        edited(.editedAttributes, range: range, changeInLength: 0)
    }
}
