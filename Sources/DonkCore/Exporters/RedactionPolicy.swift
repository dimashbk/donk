import Foundation

public struct RedactionPolicy: Codable, Equatable, Sendable {
    public static let defaultHeaders = [
        "authorization", "proxy-authorization", "cookie", "set-cookie", "x-api-key", "x-auth-token", "x-access-token",
    ]
    public static let defaultKeys = [
        "password", "pass", "passcode", "pin", "token", "access_token", "accessToken", "refresh_token", "refreshToken",
        "id_token", "secret", "client_secret", "otp", "cvv", "cvc", "cardNumber", "card_number", "pan",
    ]
    public static let defaultReplacement = "••••"
    public static let `default` = RedactionPolicy()

    public var headers: [String]
    public var keys: [String]
    public var replacement: String

    public init(
        headers: [String] = RedactionPolicy.defaultHeaders,
        keys: [String] = RedactionPolicy.defaultKeys,
        replacement: String = RedactionPolicy.defaultReplacement
    ) {
        self.headers = headers
        self.keys = keys
        self.replacement = replacement
    }

    private enum CodingKeys: String, CodingKey {
        case headers, keys, replacement
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        headers = (try? container.decodeIfPresent([String].self, forKey: .headers)) ?? Self.defaultHeaders
        keys = (try? container.decodeIfPresent([String].self, forKey: .keys)) ?? Self.defaultKeys
        replacement = (try? container.decodeIfPresent(String.self, forKey: .replacement)) ?? Self.defaultReplacement
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(headers, forKey: .headers)
        try container.encode(keys, forKey: .keys)
        try container.encode(replacement, forKey: .replacement)
    }

    // MARK: - Matching

    public func redactsHeader(_ name: String) -> Bool {
        Redactor(self).redactsHeader(name)
    }

    public func redactsKey(_ key: String) -> Bool {
        Redactor(self).redactsKey(key)
    }

    // MARK: - Redaction

    public func redact(_ entry: NetworkEntry) -> NetworkEntry {
        Redactor(self).entry(entry)
    }

    public func redact(_ request: RequestSnapshot) -> RequestSnapshot {
        Redactor(self).request(request)
    }

    public func redact(_ response: ResponseSnapshot) -> ResponseSnapshot {
        Redactor(self).response(response)
    }

    public func redact(headers: [HTTPHeader]) -> [HTTPHeader] {
        Redactor(self).headers(headers)
    }

    public func redact(url: String) -> String {
        Redactor(self).url(url)
    }

    public func redact(body: BodyData) -> BodyData {
        Redactor(self).body(body)
    }

    public func redact(json: String) -> String {
        Redactor(self).json(json) ?? json
    }

    public func redact(formURLEncoded text: String) -> String {
        Redactor(self).pairs(Substring(text)).text
    }
}

// MARK: - Redactor

private struct Redactor {
    let headerNames: Set<String>
    let keyNames: Set<String>
    let replacement: String

    init(_ policy: RedactionPolicy) {
        headerNames = Set(policy.headers.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        keyNames = Set(policy.keys.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        replacement = policy.replacement
    }

    func redactsHeader(_ name: String) -> Bool {
        headerNames.contains(name.trimmingCharacters(in: .whitespaces).lowercased())
    }

    func redactsKey(_ key: String) -> Bool {
        keyNames.contains(key.lowercased())
    }

    // MARK: - Entry

    func entry(_ entry: NetworkEntry) -> NetworkEntry {
        var copy = entry
        copy.request = request(entry.request)
        copy.response = entry.response.map(response)
        if var grpc = entry.grpc {
            grpc.requestMetadata = headers(grpc.requestMetadata)
            grpc.responseHeaders = headers(grpc.responseHeaders)
            grpc.trailers = headers(grpc.trailers)
            let messages = grpc.messages
            let redacted = messages.map(message)
            if redacted != messages {
                grpc.messages = redacted
            }
            copy.grpc = grpc
        }
        if var web = entry.web, let page = web.pageURL {
            web.pageURL = url(page)
            copy.web = web
        }
        return copy
    }

    func request(_ request: RequestSnapshot) -> RequestSnapshot {
        var copy = request
        copy.url = url(request.url)
        copy.headers = headers(request.headers)
        copy.body = request.body.map(body)
        return copy
    }

    func response(_ response: ResponseSnapshot) -> ResponseSnapshot {
        var copy = response
        copy.headers = headers(response.headers)
        copy.body = response.body.map(body)
        return copy
    }

    func headers(_ headers: [HTTPHeader]) -> [HTTPHeader] {
        headers.map { header in
            redactsHeader(header.name) ? HTTPHeader(name: header.name, value: replacement) : header
        }
    }

    func message(_ message: GRPCMessage) -> GRPCMessage {
        var copy = message
        if let json = message.json, let redacted = self.json(json) {
            copy.json = redacted
        }
        if let text = message.textFormat, let redacted = textFormat(text) {
            copy.textFormat = redacted
        }
        return copy
    }

    // MARK: - URL and form pairs

    func url(_ url: String) -> String {
        guard let separator = url.firstIndex(where: { $0 == "?" || $0 == "#" }) else { return url }
        var result = String(url[..<separator])
        let rest = url[separator...]
        var query: Substring?
        var fragment: Substring?
        if rest.first == "?" {
            let afterMark = rest.dropFirst()
            if let hash = afterMark.firstIndex(of: "#") {
                query = afterMark[..<hash]
                fragment = afterMark[afterMark.index(after: hash)...]
            } else {
                query = afterMark
            }
        } else {
            fragment = rest.dropFirst()
        }
        if let query {
            result += "?" + pairs(query).text
        }
        if let fragment {
            result += "#" + (fragment.contains("=") ? pairs(fragment).text : String(fragment))
        }
        return result
    }

    func pairs(_ text: Substring) -> (text: String, changed: Bool) {
        var changed = false
        let parts = text.split(separator: "&", omittingEmptySubsequences: false).map { pair -> String in
            guard let equals = pair.firstIndex(of: "=") else { return String(pair) }
            let name = pair[..<equals]
            guard redactsPairName(name) else { return String(pair) }
            changed = true
            return String(name) + "=" + replacement
        }
        return (changed ? parts.joined(separator: "&") : String(text), changed)
    }

    private func redactsPairName(_ raw: Substring) -> Bool {
        let plain = String(raw).replacingOccurrences(of: "+", with: " ")
        let name = plain.removingPercentEncoding ?? plain
        if redactsKey(name) { return true }
        guard name.hasSuffix("]"), let open = name.lastIndex(of: "[") else { return false }
        let inner = name[name.index(after: open)..<name.index(before: name.endIndex)]
        return redactsKey(String(inner))
    }

    // MARK: - Bodies

    func body(_ body: BodyData) -> BodyData {
        guard !body.data.isEmpty, !body.isImage, let text = body.text else { return body }
        let redacted: String?
        if body.isFormURLEncoded {
            let result = pairs(Substring(text))
            redacted = result.changed ? result.text : nil
        } else if body.mimeType?.contains("json") == true || Self.looksLikeJSON(text) {
            redacted = json(text)
        } else {
            redacted = nil
        }
        guard let redacted else { return body }
        var copy = body
        copy.data = Data(redacted.utf8)
        return copy
    }

    func json(_ text: String) -> String? {
        if let value = try? JSONValue.parse(text) {
            let result = redactValue(value)
            guard result.changed else { return nil }
            return text.contains("\n") ? result.value.prettyPrinted() : result.value.compact()
        }
        return scanJSON(text)
    }

    private func redactValue(_ value: JSONValue) -> (value: JSONValue, changed: Bool) {
        switch value {
        case let .object(members):
            var changed = false
            let redacted = members.map { member -> JSONMember in
                if redactsKey(member.key) {
                    changed = true
                    return JSONMember(key: member.key, value: .string(replacement))
                }
                let nested = redactValue(member.value)
                changed = changed || nested.changed
                return JSONMember(key: member.key, value: nested.value)
            }
            return (.object(redacted), changed)
        case let .array(items):
            var changed = false
            let redacted = items.map { item -> JSONValue in
                let nested = redactValue(item)
                changed = changed || nested.changed
                return nested.value
            }
            return (.array(redacted), changed)
        case .string, .number, .bool, .null:
            return (value, false)
        }
    }

    private func scanJSON(_ text: String) -> String? {
        let bytes = Array(text.utf8)
        let replacementLiteral = Array(JSONFormatting.escape(replacement).utf8)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var changed = false
        var index = 0
        while index < bytes.count {
            guard bytes[index] == Self.quote else {
                output.append(bytes[index])
                index += 1
                continue
            }
            let end = Self.endOfString(bytes, from: index)
            output.append(contentsOf: bytes[index..<end])
            var cursor = end
            while cursor < bytes.count, Self.isWhitespace(bytes[cursor]) { cursor += 1 }
            guard cursor < bytes.count, bytes[cursor] == Self.colon,
                  let key = Self.decodeKey(bytes[index..<end]), redactsKey(key)
            else {
                index = end
                continue
            }
            cursor += 1
            while cursor < bytes.count, Self.isWhitespace(bytes[cursor]) { cursor += 1 }
            output.append(contentsOf: bytes[end..<cursor])
            output.append(contentsOf: replacementLiteral)
            changed = true
            index = Self.endOfValue(bytes, from: cursor)
        }
        return changed ? String(decoding: output, as: UTF8.self) : nil
    }

    private func textFormat(_ text: String) -> String? {
        var changed = false
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let indent = line.prefix { $0 == " " || $0 == "\t" }
            let rest = line.dropFirst(indent.count)
            guard let colon = rest.firstIndex(of: ":") else { return String(line) }
            let name = rest[..<colon]
            guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }), redactsKey(String(name)) else {
                return String(line)
            }
            changed = true
            return String(indent) + String(name) + ": " + JSONFormatting.escape(replacement)
        }
        return changed ? lines.joined(separator: "\n") : nil
    }

    // MARK: - Scanning helpers

    private static let quote = UInt8(ascii: "\"")
    private static let colon = UInt8(ascii: ":")
    private static let backslash = UInt8(ascii: "\\")

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private static func looksLikeJSON(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first(where: { !CharacterSet.whitespacesAndNewlines.contains($0) && $0 != "\u{FEFF}" }) else {
            return false
        }
        return first == "{" || first == "["
    }

    private static func endOfString(_ bytes: [UInt8], from start: Int) -> Int {
        var index = start + 1
        while index < bytes.count {
            if bytes[index] == backslash {
                index += 2
                continue
            }
            if bytes[index] == quote { return index + 1 }
            index += 1
        }
        return bytes.count
    }

    private static func endOfValue(_ bytes: [UInt8], from start: Int) -> Int {
        guard start < bytes.count else { return start }
        switch bytes[start] {
        case quote:
            return endOfString(bytes, from: start)
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            var depth = 0
            var index = start
            while index < bytes.count {
                let byte = bytes[index]
                if byte == quote {
                    index = endOfString(bytes, from: index)
                    continue
                }
                if byte == UInt8(ascii: "{") || byte == UInt8(ascii: "[") {
                    depth += 1
                } else if byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]") {
                    depth -= 1
                    if depth == 0 { return index + 1 }
                }
                index += 1
            }
            return bytes.count
        default:
            var index = start
            while index < bytes.count {
                let byte = bytes[index]
                if byte == UInt8(ascii: ",") || byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]") || isWhitespace(byte) { break }
                index += 1
            }
            return index
        }
    }

    private static func decodeKey(_ literal: ArraySlice<UInt8>) -> String? {
        guard literal.count >= 2, literal.last == quote else { return nil }
        if !literal.contains(backslash) {
            return String(decoding: literal.dropFirst().dropLast(), as: UTF8.self)
        }
        guard case let .string(key)? = try? JSONValue.parse(String(decoding: literal, as: UTF8.self)) else { return nil }
        return key
    }
}
