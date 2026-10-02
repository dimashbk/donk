import UIKit

// MARK: - Language

public enum CodeLanguage: String, CaseIterable, Hashable, Sendable {
    case plain
    case json

    public static func detect(contentType: String? = nil, text: String? = nil) -> CodeLanguage {
        if let contentType, contentType.lowercased().contains("json") {
            return .json
        }
        if let text, let first = text.unicodeScalars.first(where: { !CharacterSet.whitespacesAndNewlines.contains($0) }) {
            if first == "{" || first == "[" {
                return .json
            }
        }
        return .plain
    }
}

// MARK: - JSON lexer

enum JSONSyntax {
    enum Kind: UInt8, Sendable {
        case key
        case string
        case number
        case literal
    }

    struct Token: Sendable {
        let location: Int
        let length: Int
        let kind: Kind
    }

    static let highlightLimit = 300_000
    static let synchronousLimit = 16_000
    static let editorLimit = 64_000

    static func tokens(in text: String) -> [Token] {
        let units = Array(text.utf16)
        let count = units.count
        var tokens: [Token] = []
        tokens.reserveCapacity(count / 6)
        var index = 0
        while index < count {
            let unit = units[index]
            switch unit {
            case 0x22:
                let start = index
                index += 1
                var closed = false
                while index < count {
                    let current = units[index]
                    if current == 0x5C {
                        index += 2
                        continue
                    }
                    if current == 0x22 {
                        index += 1
                        closed = true
                        break
                    }
                    if current == 0x0A {
                        break
                    }
                    index += 1
                }
                index = min(index, count)
                var lookahead = index
                while lookahead < count, isSpace(units[lookahead]) {
                    lookahead += 1
                }
                let isKey = closed && lookahead < count && units[lookahead] == 0x3A
                tokens.append(Token(location: start, length: index - start, kind: isKey ? .key : .string))
            case 0x2D, 0x30...0x39:
                let start = index
                index += 1
                while index < count, isNumberUnit(units[index]) {
                    index += 1
                }
                tokens.append(Token(location: start, length: index - start, kind: .number))
            case 0x74, 0x66, 0x6E:
                let start = index
                index += 1
                while index < count, isLetter(units[index]) {
                    index += 1
                }
                tokens.append(Token(location: start, length: index - start, kind: .literal))
            default:
                index += 1
            }
        }
        return tokens
    }

    static func color(for kind: Kind) -> UIColor {
        switch kind {
        case .key: return DonkPalette.codeKey
        case .string: return DonkPalette.codeString
        case .number: return DonkPalette.codeNumber
        case .literal: return DonkPalette.codeLiteral
        }
    }

    static func baseColor(for language: CodeLanguage) -> UIColor {
        language == .json ? DonkPalette.codePunctuation : .label
    }

    static func paragraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        style.lineBreakMode = .byWordWrapping
        return style
    }

    static func baseAttributes(font: UIFont, language: CodeLanguage) -> [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: baseColor(for: language),
            .paragraphStyle: paragraphStyle(),
        ]
    }

    static func attributedString(_ text: String, language: CodeLanguage, font: UIFont) -> NSMutableAttributedString {
        NSMutableAttributedString(string: text, attributes: baseAttributes(font: font, language: language))
    }

    static func apply(_ tokens: [Token], to storage: NSMutableAttributedString) {
        let length = storage.length
        let keyColor = color(for: .key)
        let stringColor = color(for: .string)
        let numberColor = color(for: .number)
        let literalColor = color(for: .literal)
        for token in tokens where token.length > 0 && token.location + token.length <= length {
            let value: UIColor
            switch token.kind {
            case .key: value = keyColor
            case .string: value = stringColor
            case .number: value = numberColor
            case .literal: value = literalColor
            }
            storage.addAttribute(.foregroundColor, value: value, range: NSRange(location: token.location, length: token.length))
        }
    }

    private static func isSpace(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D
    }

    private static func isNumberUnit(_ unit: UInt16) -> Bool {
        (0x30...0x39).contains(unit) || unit == 0x2E || unit == 0x65 || unit == 0x45 || unit == 0x2B || unit == 0x2D
    }

    private static func isLetter(_ unit: UInt16) -> Bool {
        (0x61...0x7A).contains(unit) || (0x41...0x5A).contains(unit)
    }
}

// MARK: - Search engine

enum CodeSearchEngine {
    static let matchLimit = 10_000

    static func matches(of query: String, in text: String, limit: Int = matchLimit) -> (ranges: [NSRange], truncated: Bool) {
        guard !query.isEmpty, !text.isEmpty else { return ([], false) }
        let string = NSString(string: text)
        let length = string.length
        var ranges: [NSRange] = []
        var location = 0
        while location < length {
            let found = string.range(of: query, options: [.caseInsensitive], range: NSRange(location: location, length: length - location))
            guard found.location != NSNotFound, found.length > 0 else { break }
            if ranges.count >= limit {
                return (ranges, true)
            }
            ranges.append(found)
            location = NSMaxRange(found)
        }
        return (ranges, false)
    }

    static func hexDump(_ data: Data, limit: Int = 16 * 1024) -> String {
        let bytes = [UInt8](data.prefix(limit))
        var lines: [String] = []
        lines.reserveCapacity(bytes.count / 16 + 2)
        var offset = 0
        while offset < bytes.count {
            let chunk = bytes[offset..<min(offset + 16, bytes.count)]
            var hex = ""
            var ascii = ""
            for (position, byte) in chunk.enumerated() {
                hex += String(format: "%02x ", byte)
                if position == 7 { hex += " " }
                ascii.append((0x20...0x7E).contains(byte) ? Character(UnicodeScalar(byte)) : ".")
            }
            let padding = String(repeating: " ", count: max(0, 49 - hex.count))
            lines.append(String(format: "%08x  ", offset) + hex + padding + " |" + ascii + "|")
            offset += 16
        }
        if data.count > limit {
            lines.append("… \(DonkFormat.bytes(data.count - limit)) more")
        }
        return lines.joined(separator: "\n")
    }
}
