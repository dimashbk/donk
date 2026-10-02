import Foundation

public struct JSONMember: Equatable, Sendable {
    public var key: String
    public var value: JSONValue

    public init(key: String, value: JSONValue) {
        self.key = key
        self.value = value
    }
}

public indirect enum JSONValue: Equatable, Sendable {
    case object([JSONMember])
    case array([JSONValue])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    public static func parse(_ data: Data) throws -> JSONValue {
        var parser = JSONParser(bytes: [UInt8](data))
        return try parser.parseDocument()
    }

    public static func parse(_ string: String) throws -> JSONValue {
        try parse(Data(string.utf8))
    }

    public var isContainer: Bool {
        switch self {
        case .object, .array: return true
        default: return false
        }
    }

    public var childCount: Int {
        switch self {
        case let .object(members): return members.count
        case let .array(values): return values.count
        default: return 0
        }
    }

    public var typeName: String {
        switch self {
        case .object: return "object"
        case .array: return "array"
        case .string: return "string"
        case .number: return "number"
        case .bool: return "bool"
        case .null: return "null"
        }
    }

    public subscript(key: String) -> JSONValue? {
        guard case let .object(members) = self else { return nil }
        return members.first { $0.key == key }?.value
    }

    public func prettyPrinted(indent: Int = 2) -> String {
        var output = ""
        JSONWriter.write(self, into: &output, indent: indent, level: 0)
        return output
    }

    public func compact() -> String {
        var output = ""
        JSONWriter.write(self, into: &output, indent: nil, level: 0)
        return output
    }
}

public struct JSONParseError: Error, Equatable, Sendable, CustomStringConvertible {
    public var offset: Int
    public var reason: String

    public var description: String { "JSON error at \(offset): \(reason)" }
}

public enum JSONFormatting {
    public static func pretty(_ data: Data) -> String? {
        guard !data.isEmpty, let value = try? JSONValue.parse(data) else { return nil }
        return value.prettyPrinted()
    }

    public static func pretty(_ string: String) -> String? {
        pretty(Data(string.utf8))
    }

    public static func isValid(_ string: String) -> Bool {
        (try? JSONValue.parse(string)) != nil
    }

    public static func isValid(_ data: Data) -> Bool {
        (try? JSONValue.parse(data)) != nil
    }

    public static func escape(_ string: String) -> String {
        var output = ""
        JSONWriter.writeString(string, into: &output)
        return output
    }
}

// MARK: - Parser

private struct JSONParser {
    private let bytes: [UInt8]
    private var index = 0
    private var depth = 0
    private let maxDepth = 200

    init(bytes: [UInt8]) {
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            self.bytes = Array(bytes.dropFirst(3))
        } else {
            self.bytes = bytes
        }
    }

    mutating func parseDocument() throws -> JSONValue {
        skipWhitespace()
        let value = try parseValue()
        skipWhitespace()
        guard index == bytes.count else { throw error("unexpected trailing characters") }
        return value
    }

    private func error(_ reason: String) -> JSONParseError {
        JSONParseError(offset: index, reason: reason)
    }

    private mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D: index += 1
            default: return
            }
        }
    }

    private mutating func parseValue() throws -> JSONValue {
        guard index < bytes.count else { throw error("unexpected end of input") }
        switch bytes[index] {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expect("true"); return .bool(true)
        case UInt8(ascii: "f"): try expect("false"); return .bool(false)
        case UInt8(ascii: "n"): try expect("null"); return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .number(try parseNumber())
        default: throw error("unexpected character")
        }
    }

    private mutating func expect(_ literal: String) throws {
        let utf8 = Array(literal.utf8)
        guard index + utf8.count <= bytes.count, Array(bytes[index..<index + utf8.count]) == utf8 else {
            throw error("invalid literal")
        }
        index += utf8.count
    }

    private mutating func enter() throws {
        depth += 1
        guard depth <= maxDepth else { throw error("nesting too deep") }
    }

    private mutating func parseObject() throws -> JSONValue {
        try enter()
        defer { depth -= 1 }
        index += 1
        var members: [JSONMember] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
            index += 1
            return .object(members)
        }
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw error("expected object key") }
            let key = try parseString()
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw error("expected ':'") }
            index += 1
            skipWhitespace()
            let value = try parseValue()
            members.append(JSONMember(key: key, value: value))
            skipWhitespace()
            guard index < bytes.count else { throw error("unterminated object") }
            if bytes[index] == UInt8(ascii: ",") {
                index += 1
                continue
            }
            if bytes[index] == UInt8(ascii: "}") {
                index += 1
                return .object(members)
            }
            throw error("expected ',' or '}'")
        }
    }

    private mutating func parseArray() throws -> JSONValue {
        try enter()
        defer { depth -= 1 }
        index += 1
        var values: [JSONValue] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
            index += 1
            return .array(values)
        }
        while true {
            skipWhitespace()
            values.append(try parseValue())
            skipWhitespace()
            guard index < bytes.count else { throw error("unterminated array") }
            if bytes[index] == UInt8(ascii: ",") {
                index += 1
                continue
            }
            if bytes[index] == UInt8(ascii: "]") {
                index += 1
                return .array(values)
            }
            throw error("expected ',' or ']'")
        }
    }

    private mutating func parseString() throws -> String {
        index += 1
        var buffer: [UInt8] = []
        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case UInt8(ascii: "\""):
                index += 1
                guard let string = String(bytes: buffer, encoding: .utf8) else { throw error("invalid UTF-8") }
                return string
            case UInt8(ascii: "\\"):
                index += 1
                guard index < bytes.count else { throw error("unterminated escape") }
                let escaped = bytes[index]
                index += 1
                switch escaped {
                case UInt8(ascii: "\""): buffer.append(0x22)
                case UInt8(ascii: "\\"): buffer.append(0x5C)
                case UInt8(ascii: "/"): buffer.append(0x2F)
                case UInt8(ascii: "b"): buffer.append(0x08)
                case UInt8(ascii: "f"): buffer.append(0x0C)
                case UInt8(ascii: "n"): buffer.append(0x0A)
                case UInt8(ascii: "r"): buffer.append(0x0D)
                case UInt8(ascii: "t"): buffer.append(0x09)
                case UInt8(ascii: "u"):
                    let scalar = try parseUnicodeEscape()
                    buffer.append(contentsOf: Array(String(Character(scalar)).utf8))
                default:
                    throw error("invalid escape")
                }
            case 0x00...0x1F:
                throw error("unescaped control character")
            default:
                buffer.append(byte)
                index += 1
            }
        }
        throw error("unterminated string")
    }

    private mutating func parseHex4() throws -> UInt32 {
        guard index + 4 <= bytes.count else { throw error("short unicode escape") }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let byte = bytes[index]
            let digit: UInt32
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(byte - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(byte - UInt8(ascii: "A") + 10)
            default: throw error("invalid hex digit")
            }
            value = value << 4 | digit
            index += 1
        }
        return value
    }

    private mutating func parseUnicodeEscape() throws -> Unicode.Scalar {
        let high = try parseHex4()
        if (0xD800...0xDBFF).contains(high) {
            if index + 6 <= bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                let saved = index
                index += 2
                let low = try parseHex4()
                if (0xDC00...0xDFFF).contains(low) {
                    let combined = 0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00)
                    return Unicode.Scalar(combined) ?? "\u{FFFD}"
                }
                index = saved
            }
            return "\u{FFFD}"
        }
        if (0xDC00...0xDFFF).contains(high) { return "\u{FFFD}" }
        return Unicode.Scalar(high) ?? "\u{FFFD}"
    }

    private mutating func parseNumber() throws -> String {
        let start = index
        if bytes[index] == UInt8(ascii: "-") { index += 1 }
        guard index < bytes.count else { throw error("invalid number") }
        if bytes[index] == UInt8(ascii: "0") {
            index += 1
        } else if isDigit(bytes[index]) {
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        } else {
            throw error("invalid number")
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            index += 1
            guard index < bytes.count, isDigit(bytes[index]) else { throw error("invalid fraction") }
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            index += 1
            if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
            guard index < bytes.count, isDigit(bytes[index]) else { throw error("invalid exponent") }
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    private func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }
}

// MARK: - Writer

private enum JSONWriter {
    static func write(_ value: JSONValue, into output: inout String, indent: Int?, level: Int) {
        switch value {
        case let .object(members):
            guard !members.isEmpty else { output += "{}"; return }
            output += "{"
            for (offset, member) in members.enumerated() {
                if offset > 0 { output += "," }
                newline(&output, indent: indent, level: level + 1)
                writeString(member.key, into: &output)
                output += indent == nil ? ":" : ": "
                write(member.value, into: &output, indent: indent, level: level + 1)
            }
            newline(&output, indent: indent, level: level)
            output += "}"
        case let .array(values):
            guard !values.isEmpty else { output += "[]"; return }
            output += "["
            for (offset, element) in values.enumerated() {
                if offset > 0 { output += "," }
                newline(&output, indent: indent, level: level + 1)
                write(element, into: &output, indent: indent, level: level + 1)
            }
            newline(&output, indent: indent, level: level)
            output += "]"
        case let .string(string):
            writeString(string, into: &output)
        case let .number(literal):
            output += literal
        case let .bool(flag):
            output += flag ? "true" : "false"
        case .null:
            output += "null"
        }
    }

    static func newline(_ output: inout String, indent: Int?, level: Int) {
        guard let indent else { return }
        output += "\n"
        output += String(repeating: " ", count: indent * level)
    }

    static func writeString(_ string: String, into output: inout String) {
        output += "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            default:
                if scalar.value < 0x20 {
                    output += String(format: "\\u%04X", scalar.value)
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        output += "\""
    }
}
