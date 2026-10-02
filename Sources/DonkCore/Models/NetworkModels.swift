import Foundation

public enum NetworkKind: String, Codable, Sendable, CaseIterable {
    case http, grpc, webView
}

public enum NetworkState: String, Codable, Sendable {
    case pending, paused, streaming, completed, failed, cancelled

    public var isInFlight: Bool {
        switch self {
        case .pending, .paused, .streaming: return true
        case .completed, .failed, .cancelled: return false
        }
    }
}

public enum StatusCategory: String, Codable, Sendable, CaseIterable {
    case pending, success, redirect, clientError, serverError, failure
}

// MARK: - Headers

public struct HTTPHeader: Codable, Sendable, Hashable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }

    public static func list(from fields: [String: String]?) -> [HTTPHeader] {
        guard let fields else { return [] }
        return sorted(fields.map { HTTPHeader(name: $0.key, value: $0.value) })
    }

    public static func list(from fields: [AnyHashable: Any]?) -> [HTTPHeader] {
        guard let fields else { return [] }
        let headers = fields.compactMap { key, value -> HTTPHeader? in
            guard let name = key.base as? String else { return nil }
            return HTTPHeader(name: name, value: value as? String ?? String(describing: value))
        }
        return sorted(headers)
    }

    private static func sorted(_ headers: [HTTPHeader]) -> [HTTPHeader] {
        headers.sorted { lhs, rhs in
            let left = lhs.name.lowercased()
            let right = rhs.name.lowercased()
            return left == right ? lhs.value < rhs.value : left < right
        }
    }
}

extension Array where Element == HTTPHeader {
    public func value(for name: String) -> String? {
        first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

// MARK: - Body

public struct BodyData: Codable, Sendable, Equatable {
    public var data: Data
    public var contentType: String?
    public var originalSize: Int
    public var isTruncated: Bool

    public static let jsonSniffLimit = 2 * 1024 * 1024

    public init(data: Data, contentType: String?, limit: Int) {
        originalSize = data.count
        self.contentType = contentType
        if limit >= 0, data.count > limit {
            self.data = Data(data.prefix(limit))
            isTruncated = true
        } else {
            self.data = data.startIndex == 0 ? data : Data(data)
            isTruncated = false
        }
    }

    public init(text: String, contentType: String? = "text/plain; charset=utf-8", limit: Int = .max) {
        self.init(data: Data(text.utf8), contentType: contentType, limit: limit)
    }

    public var mimeType: String? {
        guard let contentType else { return nil }
        let base = contentType.split(separator: ";", maxSplits: 1).first.map(String.init) ?? contentType
        let trimmed = base.trimmingCharacters(in: .whitespaces).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    public var text: String? {
        if let string = String(data: data, encoding: .utf8) { return string }
        guard isTruncated else { return nil }
        for drop in 1...3 where data.count > drop {
            if let string = String(data: data.dropLast(drop), encoding: .utf8) { return string }
        }
        return nil
    }

    public var isJSON: Bool {
        if contentTypeContainsJSON { return true }
        guard data.count <= Self.jsonSniffLimit, startsLikeJSON else { return false }
        return JSONFormatting.isValid(data)
    }

    public var prettyJSON: String? {
        guard contentTypeContainsJSON || startsLikeJSON else { return nil }
        return JSONFormatting.pretty(data)
    }

    public var isImage: Bool {
        if let mimeType, mimeType.hasPrefix("image/") { return true }
        return Self.hasImageSignature(data)
    }

    public var isFormURLEncoded: Bool {
        contentType?.lowercased().contains("application/x-www-form-urlencoded") ?? false
    }

    private var contentTypeContainsJSON: Bool {
        contentType?.lowercased().contains("json") ?? false
    }

    private var startsLikeJSON: Bool {
        var index = data.startIndex
        if data.count >= 3, data[index] == 0xEF, data[index + 1] == 0xBB, data[index + 2] == 0xBF {
            index += 3
        }
        while index < data.endIndex {
            switch data[index] {
            case 0x20, 0x09, 0x0A, 0x0D:
                index += 1
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                return true
            default:
                return false
            }
        }
        return false
    }

    static func hasImageSignature(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(16))
        guard bytes.count >= 4 else { return false }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return true }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return true }
        if bytes.starts(with: Array("GIF87a".utf8)) || bytes.starts(with: Array("GIF89a".utf8)) { return true }
        if bytes.count >= 12, bytes.starts(with: Array("RIFF".utf8)), Array(bytes[8..<12]) == Array("WEBP".utf8) { return true }
        if bytes.count >= 12, Array(bytes[4..<8]) == Array("ftyp".utf8) {
            let brand = String(decoding: bytes[8..<12], as: UTF8.self)
            return ["heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1", "avif"].contains(brand)
        }
        return false
    }
}

// MARK: - Request / response

public struct RequestSnapshot: Codable, Sendable, Equatable {
    public var url: String
    public var method: String
    public var headers: [HTTPHeader]
    public var body: BodyData?

    public init(url: String, method: String = "GET", headers: [HTTPHeader] = [], body: BodyData? = nil) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }

    public var host: String? { URLParts.host(of: url) }

    public var path: String { URLParts.path(of: url) }

    public var queryItems: [URLQueryItem] { URLParts.queryItems(of: url) }

    public func header(_ name: String) -> String? {
        headers.value(for: name)
    }
}

public struct ResponseSnapshot: Codable, Sendable, Equatable {
    public var statusCode: Int
    public var headers: [HTTPHeader]
    public var body: BodyData?

    public init(statusCode: Int, headers: [HTTPHeader] = [], body: BodyData? = nil) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers.value(for: name)
    }

    public var reasonPhrase: String { Self.reasonPhrase(for: statusCode) }

    public static func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 100: return "Continue"
        case 101: return "Switching Protocols"
        case 200: return "OK"
        case 201: return "Created"
        case 202: return "Accepted"
        case 203: return "Non-Authoritative Information"
        case 204: return "No Content"
        case 205: return "Reset Content"
        case 206: return "Partial Content"
        case 300: return "Multiple Choices"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 303: return "See Other"
        case 304: return "Not Modified"
        case 307: return "Temporary Redirect"
        case 308: return "Permanent Redirect"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 402: return "Payment Required"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 406: return "Not Acceptable"
        case 407: return "Proxy Authentication Required"
        case 408: return "Request Timeout"
        case 409: return "Conflict"
        case 410: return "Gone"
        case 411: return "Length Required"
        case 412: return "Precondition Failed"
        case 413: return "Payload Too Large"
        case 414: return "URI Too Long"
        case 415: return "Unsupported Media Type"
        case 416: return "Range Not Satisfiable"
        case 417: return "Expectation Failed"
        case 418: return "I'm a teapot"
        case 422: return "Unprocessable Entity"
        case 423: return "Locked"
        case 425: return "Too Early"
        case 426: return "Upgrade Required"
        case 428: return "Precondition Required"
        case 429: return "Too Many Requests"
        case 431: return "Request Header Fields Too Large"
        case 451: return "Unavailable For Legal Reasons"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        case 504: return "Gateway Timeout"
        case 505: return "HTTP Version Not Supported"
        case 511: return "Network Authentication Required"
        default: return ""
        }
    }
}

// MARK: - Timing

public struct TransactionMetrics: Codable, Sendable, Equatable {
    public var fetchStart: Date?
    public var domainLookupStart: Date?
    public var domainLookupEnd: Date?
    public var connectStart: Date?
    public var connectEnd: Date?
    public var secureConnectionStart: Date?
    public var secureConnectionEnd: Date?
    public var requestStart: Date?
    public var requestEnd: Date?
    public var responseStart: Date?
    public var responseEnd: Date?
    public var networkProtocol: String?
    public var remoteAddress: String?
    public var tlsProtocol: String?
    public var tlsCipherSuite: String?
    public var isReusedConnection: Bool
    public var isProxyConnection: Bool
    public var requestHeaderBytes: Int64
    public var requestBodyBytes: Int64
    public var responseHeaderBytes: Int64
    public var responseBodyBytes: Int64

    public init(
        fetchStart: Date? = nil,
        domainLookupStart: Date? = nil,
        domainLookupEnd: Date? = nil,
        connectStart: Date? = nil,
        connectEnd: Date? = nil,
        secureConnectionStart: Date? = nil,
        secureConnectionEnd: Date? = nil,
        requestStart: Date? = nil,
        requestEnd: Date? = nil,
        responseStart: Date? = nil,
        responseEnd: Date? = nil,
        networkProtocol: String? = nil,
        remoteAddress: String? = nil,
        tlsProtocol: String? = nil,
        tlsCipherSuite: String? = nil,
        isReusedConnection: Bool = false,
        isProxyConnection: Bool = false,
        requestHeaderBytes: Int64 = 0,
        requestBodyBytes: Int64 = 0,
        responseHeaderBytes: Int64 = 0,
        responseBodyBytes: Int64 = 0
    ) {
        self.fetchStart = fetchStart
        self.domainLookupStart = domainLookupStart
        self.domainLookupEnd = domainLookupEnd
        self.connectStart = connectStart
        self.connectEnd = connectEnd
        self.secureConnectionStart = secureConnectionStart
        self.secureConnectionEnd = secureConnectionEnd
        self.requestStart = requestStart
        self.requestEnd = requestEnd
        self.responseStart = responseStart
        self.responseEnd = responseEnd
        self.networkProtocol = networkProtocol
        self.remoteAddress = remoteAddress
        self.tlsProtocol = tlsProtocol
        self.tlsCipherSuite = tlsCipherSuite
        self.isReusedConnection = isReusedConnection
        self.isProxyConnection = isProxyConnection
        self.requestHeaderBytes = requestHeaderBytes
        self.requestBodyBytes = requestBodyBytes
        self.responseHeaderBytes = responseHeaderBytes
        self.responseBodyBytes = responseBodyBytes
    }
}

public struct NetworkTiming: Codable, Sendable, Equatable {
    public var startedAt: Date
    public var responseStartedAt: Date?
    public var endedAt: Date?
    public var transactions: [TransactionMetrics]

    public init(startedAt: Date = Date(), responseStartedAt: Date? = nil, endedAt: Date? = nil, transactions: [TransactionMetrics] = []) {
        self.startedAt = startedAt
        self.responseStartedAt = responseStartedAt
        self.endedAt = endedAt
        self.transactions = transactions
    }

    public var duration: TimeInterval? {
        endedAt.map { max(0, $0.timeIntervalSince(startedAt)) }
    }
}

// MARK: - Origin / error

public enum NetworkOrigin: Codable, Sendable, Equatable {
    case network
    case mocked(rule: String)
    case rewritten(rule: String)
    case breakpoint(edited: Bool)

    public var isModified: Bool {
        if case .network = self { return false }
        return true
    }
}

public struct NetworkErrorInfo: Codable, Sendable, Equatable {
    public var domain: String
    public var code: Int
    public var message: String

    public init(domain: String, code: Int, message: String) {
        self.domain = domain
        self.code = code
        self.message = message
    }

    public init(_ error: Error) {
        let nsError = error as NSError
        self.init(domain: nsError.domain, code: nsError.code, message: nsError.localizedDescription)
    }
}

// MARK: - WebView

public enum WebInitiator: String, Codable, Sendable {
    case document, fetch, xhr, beacon, websocket, eventSource, resource
}

public enum CaptureLevel: String, Codable, Sendable {
    case full, metadata, observed
}

public struct WebViewDetails: Codable, Sendable, Equatable {
    public var pageURL: String?
    public var initiator: WebInitiator
    public var captureLevel: CaptureLevel
    public var webViewID: String?

    public init(pageURL: String? = nil, initiator: WebInitiator, captureLevel: CaptureLevel, webViewID: String? = nil) {
        self.pageURL = pageURL
        self.initiator = initiator
        self.captureLevel = captureLevel
        self.webViewID = webViewID
    }
}
