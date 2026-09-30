import Foundation

public enum MarkdownEncodingError: Error, Equatable {
    case invalidUTF8
}

/// Keep original bytes for unchanged saves; edit LF internally without losing BOM/style.
public struct MarkdownEncoding: Sendable {
    public enum LineEnding: String, Sendable {
        case lf = "\n"
        case crlf = "\r\n"
        case cr = "\r"
    }

    public let text: String
    public let hasBOM: Bool
    public let lineEnding: LineEnding
    private let originalData: Data

    public init(data: Data) throws {
        let bom = Data([0xef, 0xbb, 0xbf])
        hasBOM = data.starts(with: bom)
        let payload = hasBOM ? data.dropFirst(3) : data[...]
        guard let decoded = String(data: payload, encoding: .utf8) else {
            throw MarkdownEncodingError.invalidUTF8
        }
        if let range = decoded.range(of: #"\r\n|\r|\n"#, options: .regularExpression) {
            let ending = decoded[range.lowerBound...]
            if ending.hasPrefix("\r\n") { lineEnding = .crlf }
            else if ending.hasPrefix("\r") { lineEnding = .cr }
            else { lineEnding = .lf }
        } else {
            lineEnding = .lf
        }
        text = EditorBehavior.normalizePlainText(decoded)
        originalData = data
    }

    public func data(for editedText: String) -> Data {
        // An unchanged file keeps mixed line endings and every trailing byte intact.
        if editedText.utf8.elementsEqual(text.utf8) { return originalData }
        let normalized = EditorBehavior.normalizePlainText(editedText)
        let encoded = normalized.replacingOccurrences(of: "\n", with: lineEnding.rawValue)
        var data = hasBOM ? Data([0xef, 0xbb, 0xbf]) : Data()
        data.append(contentsOf: encoded.utf8)
        return data
    }
}
