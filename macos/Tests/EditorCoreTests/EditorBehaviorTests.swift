import Foundation
import Testing
@testable import EditorCore

private struct BehaviorFixtures: Decodable {
    struct Edit: Decodable {
        let id: String
        let command: String
        let source: String
        let selection: [Int]
        let argument: String?
        let expectedText: String
        let expectedSelection: [Int]
        let noEdit: Bool?
    }
    struct Count: Decodable { let text: String; let count: Int }
    struct Name: Decodable { let text: String; let filename: String }
    struct Link: Decodable { let text: String; let normalized: String?; let opens: Bool }
    struct Markup: Decodable {
        struct Span: Decodable { let kind: InlineMarkup.Kind; let content: [Int]; let markers: [[Int]] }
        let source: String
        let spans: [Span]
    }
    let edits: [Edit]
    let wordCounts: [Count]
    let filenames: [Name]
    let links: [Link]
    let markup: [Markup]

    static func load() throws -> Self {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf:
            repository.appendingPathComponent("tests/fixtures/editor-behavior.json")))
    }
}

private func range(_ numbers: [Int]) -> NSRange {
    NSRange(location: numbers[0], length: numbers[1])
}

@Test func editingMatchesBehaviorFixtures() throws {
    for fixture in try BehaviorFixtures.load().edits {
        let command: EditorCommand
        switch fixture.command {
        case "replace": command = .replace(fixture.argument ?? "")
        case "bold": command = .bold
        case "italic": command = .italic
        case "link": command = .link(clipboard: fixture.argument ?? "")
        case "paste": command = .paste(fixture.argument ?? "")
        case "return": command = .insertReturn(soft: false)
        case "softReturn": command = .insertReturn(soft: true)
        case "deleteParagraphBreak": command = .deleteParagraphBreak
        default: Issue.record("Unknown fixture command: \(fixture.command)"); continue
        }
        let edit = try EditorBehavior.edit(command, in: fixture.source, selection: range(fixture.selection))
        if fixture.noEdit == true {
            #expect(edit == nil, "\(fixture.id)")
        } else {
            let edit = try #require(edit, "\(fixture.id)")
            #expect(try Data(edit.applying(to: fixture.source).utf8) == Data(fixture.expectedText.utf8), "\(fixture.id)")
            #expect(edit.selection == range(fixture.expectedSelection), "\(fixture.id)")
        }
    }
}

@Test func utilitiesMatchBehaviorFixtures() throws {
    let fixtures = try BehaviorFixtures.load()
    for fixture in fixtures.wordCounts {
        #expect(EditorBehavior.wordCount(fixture.text) == fixture.count)
    }
    for fixture in fixtures.filenames {
        #expect(EditorBehavior.suggestedFilename(fixture.text) == fixture.filename)
    }
    for fixture in fixtures.links {
        let normalized = EditorBehavior.normalizedLinkURL(fixture.text)
        #expect(normalized == fixture.normalized)
        let opens = normalized.flatMap(URL.init(string:)).map(EditorBehavior.canOpenLink) ?? false
        #expect(opens == fixture.opens)
    }
}

@Test func markupUsesSourceUTF16Ranges() throws {
    for fixture in try BehaviorFixtures.load().markup {
        let spans = MarkdownSpans.inline(in: fixture.source)
        #expect(spans.count == fixture.spans.count)
        for (span, expected) in zip(spans, fixture.spans) {
            #expect(span.kind == expected.kind)
            #expect(span.content == range(expected.content))
            #expect(span.markers == expected.markers.map(range))
        }
    }
}

@Test func editsRejectRangesThatSplitGraphemesOrOverflow() {
    let invalid = [NSRange(location: 1, length: 0), NSRange(location: 0, length: 1),
                   NSRange(location: NSNotFound, length: 0), NSRange(location: Int.max, length: Int.max),
                   NSRange(location: -1, length: 0), NSRange(location: 0, length: -1)]
    for selection in invalid {
        #expect(throws: EditorError.invalidRange) {
            try EditorBehavior.edit(.bold, in: "👩‍💻é", selection: selection)
        }
    }
    #expect(throws: EditorError.invalidRange) {
        try EditorBehavior.edit(.replace("x"), in: "é", selection: NSRange(location: 1, length: 0))
    }
    #expect(throws: EditorError.invalidRange) {
        try SourceEdit(range: NSRange(location: 0, length: 0), replacement: "x",
                       selection: NSRange(location: 20, length: 0)).applying(to: "a")
    }
}

@Test func longFilenamesStayWithinTheLimitWithoutSplittingUnicode() {
    #expect(EditorBehavior.suggestedFilename(String(repeating: "a", count: 130))
            == String(repeating: "a", count: 120) + ".md")
    let input = String(repeating: "a", count: 119) + "👩‍💻"
    #expect(EditorBehavior.suggestedFilename(input) == String(repeating: "a", count: 119) + ".md")
}

@Test func encodedDocumentsRoundTripAndRetainBOMAndLineEndings() throws {
    for source in ["", "last line", "a\nb\n", "a\r\nb\r\n", "a\rb\r", "a\r\nb\nc\r", "👩‍💻é"] {
        for hasBOM in [false, true] {
            let data = (hasBOM ? Data([0xef, 0xbb, 0xbf]) : Data()) + Data(source.utf8)
            let document = try MarkdownEncoding(data: data)
            #expect(document.text == EditorBehavior.normalizePlainText(source))
            #expect(document.hasBOM == hasBOM)
            #expect(document.data(for: document.text) == data)
        }
    }
    let document = try MarkdownEncoding(data: Data([0xef, 0xbb, 0xbf]) + Data("a\r\nb".utf8))
    #expect(document.data(for: "a\nb\nc") == Data([0xef, 0xbb, 0xbf]) + Data("a\r\nb\r\nc".utf8))
    #expect(throws: MarkdownEncodingError.invalidUTF8) {
        try MarkdownEncoding(data: Data([0xc3, 0x28]))
    }
    #expect(throws: MarkdownEncodingError.invalidUTF8) {
        try MarkdownEncoding(data: Data([0xff, 0xfe, 0x61, 0x00]))
    }
}

@Test func savesDoNotMistakeCanonicallyEquivalentEditsForUnchangedSource() throws {
    let decomposed = "e\u{0301}"
    let precomposed = "\u{00e9}"
    #expect(decomposed == precomposed) // Swift equality is canonically equivalent.
    #expect(Data(decomposed.utf8) != Data(precomposed.utf8))
    for (original, edited) in [(decomposed, precomposed), (precomposed, decomposed)] {
        let document = try MarkdownEncoding(data: Data(original.utf8))
        #expect(document.data(for: edited) == Data(edited.utf8))
    }
    let document = try MarkdownEncoding(data: Data("a\u{2028}b\r\nc".utf8))
    #expect(document.lineEnding == .crlf)
    #expect(document.data(for: document.text + "\nd") == Data("a\u{2028}b\r\nc\r\nd".utf8))
}
