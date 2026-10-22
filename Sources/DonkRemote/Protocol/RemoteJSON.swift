import DonkCore
import Foundation

// MARK: - Object builder

struct RemoteObject {
    private(set) var members: [JSONMember] = []

    var value: JSONValue { .object(members) }

    mutating func set(_ key: String, _ value: JSONValue?) {
        guard let value else { return }
        if let index = members.firstIndex(where: { $0.key == key }) {
            members[index].value = value
        } else {
            members.append(JSONMember(key: key, value: value))
        }
    }

    mutating func set(_ key: String, _ value: String?) {
        set(key, value.map(JSONValue.string))
    }

    mutating func setNonEmpty(_ key: String, _ value: String?) {
        guard let value, !value.isEmpty else { return }
        set(key, .string(value))
    }

    mutating func set(_ key: String, _ value: Int?) {
        set(key, value.map(RemoteJSON.integer))
    }

    mutating func set(_ key: String, _ value: Bool?) {
        set(key, value.map(JSONValue.bool))
    }

    mutating func set(_ key: String, number value: Double?, decimals: Int = 3) {
        set(key, value.flatMap { RemoteJSON.number($0, decimals: decimals) })
    }

    mutating func set(_ key: String, date value: Date?) {
        set(key, value.map(RemoteJSON.date))
    }
}

// MARK: - Values

enum RemoteJSON {
    static func integer(_ value: Int) -> JSONValue {
        .number(String(value))
    }

    static func number(_ value: Double, decimals: Int = 3) -> JSONValue? {
        guard value.isFinite else { return nil }
        if value.rounded() == value, abs(value) < 1e15 {
            return .number(String(Int64(value)))
        }
        var text = String(format: "%.\(max(0, decimals))f", value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        if text == "-0" { text = "0" }
        return .number(text)
    }

    static func date(_ date: Date) -> JSONValue {
        .string(dateString(date))
    }

    static func dateString(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    static func headers(_ headers: [HTTPHeader]) -> JSONValue {
        .array(headers.map { header in
            .object([JSONMember(key: "name", value: .string(header.name)), JSONMember(key: "value", value: .string(header.value))])
        })
    }

    static func prefix(_ text: String, maxBytes: Int) -> (text: String, isCut: Bool) {
        let utf8 = text.utf8
        guard utf8.count > maxBytes else { return (text, false) }
        var end = utf8.index(utf8.startIndex, offsetBy: max(0, maxBytes))
        while end > utf8.startIndex, end.samePosition(in: text.unicodeScalars) == nil {
            end = utf8.index(before: end)
        }
        return (String(text.unicodeScalars[..<end]), true)
    }

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()
}

// MARK: - Errors

struct RemoteError: Error, Equatable {
    var code: Int
    var message: String

    static func invalidRequest(_ message: String = "Invalid request") -> RemoteError {
        RemoteError(code: -32600, message: message)
    }

    static func methodNotFound(_ method: String) -> RemoteError {
        RemoteError(code: -32601, message: "Unknown method \(method)")
    }

    static func invalidParams(_ message: String) -> RemoteError {
        RemoteError(code: -32602, message: message)
    }

    static func notFound(_ message: String) -> RemoteError {
        RemoteError(code: -32000, message: message)
    }

    static func unavailable(_ message: String) -> RemoteError {
        RemoteError(code: -32001, message: message)
    }

    static func ambiguous(_ message: String) -> RemoteError {
        RemoteError(code: -32002, message: message)
    }
}

// MARK: - Params

struct RemoteParams {
    private let members: [JSONMember]

    init(_ value: JSONValue?) throws {
        switch value {
        case nil, .null?:
            members = []
        case let .object(members)?:
            self.members = members
        default:
            throw RemoteError.invalidParams("params must be an object")
        }
    }

    private func raw(_ key: String) -> JSONValue? {
        guard let value = members.last(where: { $0.key == key })?.value, value != .null else { return nil }
        return value
    }

    func string(_ key: String) throws -> String? {
        guard let value = raw(key) else { return nil }
        guard case let .string(text) = value else { throw RemoteError.invalidParams("\(key) must be a string") }
        return text
    }

    func number(_ key: String) throws -> Double? {
        guard let value = raw(key) else { return nil }
        guard case let .number(literal) = value, let number = Double(literal), number.isFinite else {
            throw RemoteError.invalidParams("\(key) must be a number")
        }
        return number
    }

    func integer(_ key: String) throws -> Int? {
        guard let number = try number(key) else { return nil }
        guard number.rounded() == number else { throw RemoteError.invalidParams("\(key) must be an integer") }
        return Int(max(Double(Int32.min), min(Double(Int32.max), number)))
    }

    func bool(_ key: String) throws -> Bool? {
        guard let value = raw(key) else { return nil }
        guard case let .bool(flag) = value else { throw RemoteError.invalidParams("\(key) must be a boolean") }
        return flag
    }

    func strings(_ key: String) throws -> [String]? {
        guard let value = raw(key) else { return nil }
        guard case let .array(items) = value else { throw RemoteError.invalidParams("\(key) must be an array of strings") }
        return try items.map { item in
            guard case let .string(text) = item else { throw RemoteError.invalidParams("\(key) must be an array of strings") }
            return text
        }
    }

    func clamped(_ key: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
        min(range.upperBound, max(range.lowerBound, try integer(key) ?? fallback))
    }
}

// MARK: - Messages

enum RemoteIncoming: Equatable {
    case request(id: JSONValue, method: String, params: JSONValue?)
    case notification(method: String, params: JSONValue?)
    case response
    case invalid(id: JSONValue)

    static func parse(_ text: String) -> RemoteIncoming {
        guard let value = try? JSONValue.parse(text), case let .object(members) = value else {
            return .invalid(id: .null)
        }
        let id = members.last { $0.key == "id" }?.value
        let method = members.last { $0.key == "method" }?.value
        let params = members.last { $0.key == "params" }?.value
        switch id {
        case nil, .string?, .number?, .null?:
            break
        default:
            return .invalid(id: .null)
        }
        guard let method else {
            let isResponse = members.contains { $0.key == "result" || $0.key == "error" }
            return isResponse ? .response : .invalid(id: id ?? .null)
        }
        guard case let .string(name) = method, !name.isEmpty else {
            return .invalid(id: id ?? .null)
        }
        if let params {
            switch params {
            case .object, .array, .null:
                break
            default:
                return .invalid(id: id ?? .null)
            }
        }
        guard let id else {
            return .notification(method: name, params: params)
        }
        return .request(id: id, method: name, params: params)
    }
}

enum RemoteFrame {
    static func result(id: JSONValue, _ result: JSONValue) -> String {
        JSONValue.object([
            JSONMember(key: "jsonrpc", value: .string("2.0")),
            JSONMember(key: "id", value: id),
            JSONMember(key: "result", value: result),
        ]).compact()
    }

    static func error(id: JSONValue, _ error: RemoteError) -> String {
        JSONValue.object([
            JSONMember(key: "jsonrpc", value: .string("2.0")),
            JSONMember(key: "id", value: id),
            JSONMember(key: "error", value: .object([
                JSONMember(key: "code", value: RemoteJSON.integer(error.code)),
                JSONMember(key: "message", value: .string(error.message)),
            ])),
        ]).compact()
    }

    static func notification(_ method: String, params: JSONValue) -> String {
        JSONValue.object([
            JSONMember(key: "jsonrpc", value: .string("2.0")),
            JSONMember(key: "method", value: .string(method)),
            JSONMember(key: "params", value: params),
        ]).compact()
    }
}
