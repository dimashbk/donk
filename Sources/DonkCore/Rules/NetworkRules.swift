import Foundation

public struct URLMatcher: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable, CaseIterable {
        case contains, wildcard, regex
    }

    public var pattern: String
    public var mode: Mode

    public init(pattern: String, mode: Mode = .contains) {
        self.pattern = pattern
        self.mode = mode
    }

    public func matches(_ url: String) -> Bool {
        guard !pattern.isEmpty else { return false }
        switch mode {
        case .contains:
            return url.range(of: pattern, options: .caseInsensitive) != nil
        case .wildcard:
            return Wildcard.matches(url, pattern: pattern)
        case .regex:
            guard let regex = RegexCache.shared.regex(pattern, options: [.caseInsensitive]) else { return false }
            let range = NSRange(url.startIndex..<url.endIndex, in: url)
            return regex.firstMatch(in: url, options: [], range: range) != nil
        }
    }

    public var isValid: Bool {
        guard !pattern.isEmpty else { return false }
        guard mode == .regex else { return true }
        return RegexCache.shared.regex(pattern, options: [.caseInsensitive]) != nil
    }
}

public struct RuleMatch: Codable, Equatable, Sendable {
    public var kinds: Set<NetworkKind>
    public var method: String?
    public var url: URLMatcher

    public init(kinds: Set<NetworkKind> = [.http], method: String? = nil, url: URLMatcher) {
        self.kinds = kinds
        self.method = method
        self.url = url
    }

    public func matches(kind: NetworkKind, method requestMethod: String, url requestURL: String) -> Bool {
        guard kind != .webView else { return false }
        if !kinds.isEmpty, !kinds.contains(kind) { return false }
        if kind != .grpc, let method = method?.trimmingCharacters(in: .whitespaces), !method.isEmpty,
           method.caseInsensitiveCompare(requestMethod.trimmingCharacters(in: .whitespaces)) != .orderedSame {
            return false
        }
        return url.matches(requestURL)
    }
}

public struct HeaderPatch: Codable, Equatable, Sendable {
    public var set: [HTTPHeader]
    public var remove: [String]

    public init(set: [HTTPHeader] = [], remove: [String] = []) {
        self.set = set
        self.remove = remove
    }

    public var isEmpty: Bool { self.set.isEmpty && remove.isEmpty }

    public func apply(to headers: [HTTPHeader]) -> [HTTPHeader] {
        let removals = Set(remove.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })
        var result = removals.isEmpty ? headers : headers.filter { !removals.contains($0.name.lowercased()) }
        var assigned = Set<String>()
        for header in self.set {
            let key = header.name.trimmingCharacters(in: .whitespaces).lowercased()
            guard !key.isEmpty else { continue }
            if assigned.contains(key) {
                result.append(header)
                continue
            }
            assigned.insert(key)
            if let index = result.firstIndex(where: { $0.name.lowercased() == key }) {
                result[index] = header
                var position = result.index(after: index)
                while position < result.endIndex {
                    if result[position].name.lowercased() == key {
                        result.remove(at: position)
                    } else {
                        position += 1
                    }
                }
            } else {
                result.append(header)
            }
        }
        return result
    }
}

public struct FindReplace: Codable, Equatable, Sendable {
    public var find: String
    public var replace: String
    public var isRegex: Bool

    public init(find: String, replace: String, isRegex: Bool = false) {
        self.find = find
        self.replace = replace
        self.isRegex = isRegex
    }

    public func apply(to text: String) -> String {
        guard !find.isEmpty else { return text }
        if isRegex {
            guard let regex = RegexCache.shared.regex(find) else { return text }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replace)
        }
        return text.replacingOccurrences(of: find, with: replace)
    }
}

public enum BodyPatch: Codable, Equatable, Sendable {
    case keep
    case replace(String)
    case findReplace([FindReplace])

    public func apply(to data: Data?) -> Data? {
        switch self {
        case .keep:
            return data
        case let .replace(string):
            return BodyEncoding.decode(string)
        case let .findReplace(operations):
            guard let data, let text = String(data: data, encoding: .utf8) else { return data }
            let result = operations.reduce(text) { $1.apply(to: $0) }
            return Data(result.utf8)
        }
    }
}

public struct MockResponse: Codable, Equatable, Sendable {
    public var statusCode: Int
    public var headers: [HTTPHeader]
    public var body: String
    public var delay: TimeInterval
    public var grpcStatusCode: Int
    public var grpcStatusMessage: String?
    public var grpcMessages: [String]

    public init(
        statusCode: Int = 200,
        headers: [HTTPHeader] = [],
        body: String = "",
        delay: TimeInterval = 0,
        grpcStatusCode: Int = 0,
        grpcStatusMessage: String? = nil,
        grpcMessages: [String] = []
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.delay = delay
        self.grpcStatusCode = grpcStatusCode
        self.grpcStatusMessage = grpcStatusMessage
        self.grpcMessages = grpcMessages
    }

    public var bodyData: Data { BodyEncoding.decode(body) }
}

public struct RequestRewrite: Codable, Equatable, Sendable {
    public var url: String?
    public var method: String?
    public var headers: HeaderPatch
    public var body: BodyPatch

    public init(url: String? = nil, method: String? = nil, headers: HeaderPatch = HeaderPatch(), body: BodyPatch = .keep) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }
}

public struct ResponseRewrite: Codable, Equatable, Sendable {
    public var statusCode: Int?
    public var headers: HeaderPatch
    public var body: BodyPatch
    public var grpcStatusCode: Int?
    public var grpcStatusMessage: String?

    public init(
        statusCode: Int? = nil,
        headers: HeaderPatch = HeaderPatch(),
        body: BodyPatch = .keep,
        grpcStatusCode: Int? = nil,
        grpcStatusMessage: String? = nil
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.grpcStatusCode = grpcStatusCode
        self.grpcStatusMessage = grpcStatusMessage
    }
}

public enum RuleAction: Codable, Equatable, Sendable {
    case mapLocal(MockResponse)
    case rewrite(request: RequestRewrite?, response: ResponseRewrite?)
    case breakpoint(request: Bool, response: Bool)

    public var isTransform: Bool {
        switch self {
        case .mapLocal, .rewrite: return true
        case .breakpoint: return false
        }
    }

    public var isBreakpoint: Bool {
        if case let .breakpoint(request, response) = self { return request || response }
        return false
    }
}

public struct NetworkRule: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    public var match: RuleMatch
    public var action: RuleAction
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, isEnabled: Bool = true, match: RuleMatch, action: RuleAction, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.match = match
        self.action = action
        self.createdAt = createdAt
    }
}

public struct RuleResolution: Sendable {
    public var transform: NetworkRule?
    public var breakpoint: NetworkRule?

    public init(transform: NetworkRule? = nil, breakpoint: NetworkRule? = nil) {
        self.transform = transform
        self.breakpoint = breakpoint
    }

    public static let empty = RuleResolution()

    public var isEmpty: Bool { transform == nil && breakpoint == nil }
}

// MARK: - Body encoding

package enum BodyEncoding {
    package static let base64Prefix = "base64:"

    package static func decode(_ string: String) -> Data {
        if string.hasPrefix(base64Prefix) {
            let payload = string.dropFirst(base64Prefix.count)
            if let data = Data(base64Encoded: String(payload), options: .ignoreUnknownCharacters) {
                return data
            }
        }
        return Data(string.utf8)
    }

    package static func editable(_ data: Data?) -> (text: String, isBinary: Bool) {
        guard let data, !data.isEmpty else { return ("", false) }
        if let text = String(data: data, encoding: .utf8) { return (text, false) }
        return (data.base64EncodedString(), true)
    }
}
