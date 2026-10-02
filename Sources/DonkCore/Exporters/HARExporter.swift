import Foundation

public enum HARExporter {
    public static let creatorVersion = DonkEnvironment.version

    public static func data(for entries: [NetworkEntry]) throws -> Data {
        try data(for: entries, redaction: nil)
    }

    public static func data(for entries: [NetworkEntry], redaction: RedactionPolicy?) throws -> Data {
        Data(document(for: entries, redaction: redaction).prettyPrinted().utf8)
    }

    public static func document(for entries: [NetworkEntry]) -> JSONValue {
        document(for: entries, redaction: nil)
    }

    public static func document(for entries: [NetworkEntry], redaction: RedactionPolicy?) -> JSONValue {
        let entries = redaction.map { policy in entries.map(policy.redact) } ?? entries
        let sorted = entries.sorted { $0.timing.startedAt < $1.timing.startedAt }
        return object([
            ("log", object([
                ("version", .string("1.2")),
                ("creator", object([
                    ("name", .string("donk")),
                    ("version", .string(creatorVersion)),
                ])),
                ("pages", .array([])),
                ("entries", .array(sorted.map(entryValue))),
            ])),
        ])
    }

    // MARK: - Entry

    private static func entryValue(_ entry: NetworkEntry) -> JSONValue {
        let timings = Timings(entry)
        var members: [(String, JSONValue)] = [
            ("startedDateTime", .string(DonkFormat.iso8601(entry.timing.startedAt))),
            ("time", number(timings.total)),
            ("request", requestValue(entry)),
            ("response", responseValue(entry)),
            ("cache", .object([])),
            ("timings", timings.value),
        ]
        if let address = entry.timing.transactions.last?.remoteAddress {
            members.append(("serverIPAddress", .string(address)))
        }
        members.append(("_kind", .string(entry.kind.rawValue)))
        if let grpc = entry.grpc {
            members.append(("_grpc", grpcValue(grpc)))
        }
        if let error = entry.error {
            members.append(("_error", .string("\(error.domain) \(error.code): \(error.message)")))
        }
        return object(members)
    }

    private static func requestValue(_ entry: NetworkEntry) -> JSONValue {
        let request = entry.request
        var members: [(String, JSONValue)] = [
            ("method", .string(request.method.uppercased())),
            ("url", .string(request.url)),
            ("httpVersion", .string(httpVersion(entry))),
            ("cookies", .array([])),
            ("headers", headersValue(request.headers)),
            ("queryString", .array(request.queryItems.map { item in
                object([("name", .string(item.name)), ("value", .string(item.value ?? ""))])
            })),
        ]
        if let body = request.body, !body.data.isEmpty {
            let mimeType = request.header("Content-Type") ?? body.contentType ?? "application/octet-stream"
            var postData: [(String, JSONValue)] = [("mimeType", .string(mimeType))]
            if let text = body.text {
                postData.append(("text", .string(text)))
            } else {
                postData.append(("text", .string(body.data.base64EncodedString())))
                postData.append(("_encoding", .string("base64")))
            }
            postData.append(("params", .array([])))
            members.append(("postData", object(postData)))
        }
        members.append(("headersSize", number(-1)))
        members.append(("bodySize", number(request.body?.originalSize ?? 0)))
        return object(members)
    }

    private static func responseValue(_ entry: NetworkEntry) -> JSONValue {
        guard let response = entry.response else {
            return object([
                ("status", number(0)),
                ("statusText", .string("")),
                ("httpVersion", .string(httpVersion(entry))),
                ("cookies", .array([])),
                ("headers", .array([])),
                ("content", object([("size", number(0)), ("mimeType", .string("x-unknown"))])),
                ("redirectURL", .string("")),
                ("headersSize", number(-1)),
                ("bodySize", number(-1)),
            ])
        }
        let mimeType = response.header("Content-Type") ?? response.body?.contentType ?? "x-unknown"
        var content: [(String, JSONValue)] = [
            ("size", number(response.body?.originalSize ?? 0)),
            ("mimeType", .string(mimeType)),
        ]
        if let body = response.body, !body.data.isEmpty {
            if let text = body.text {
                content.append(("text", .string(text)))
            } else {
                content.append(("text", .string(body.data.base64EncodedString())))
                content.append(("encoding", .string("base64")))
            }
            if body.isTruncated {
                content.append(("comment", .string("truncated to \(body.data.count) of \(body.originalSize) bytes")))
            }
        }
        return object([
            ("status", number(response.statusCode)),
            ("statusText", .string(response.reasonPhrase)),
            ("httpVersion", .string(httpVersion(entry))),
            ("cookies", .array([])),
            ("headers", headersValue(response.headers)),
            ("content", object(content)),
            ("redirectURL", .string(response.header("Location") ?? "")),
            ("headersSize", number(-1)),
            ("bodySize", number(response.body?.originalSize ?? 0)),
        ])
    }

    private static func grpcValue(_ grpc: GRPCDetails) -> JSONValue {
        var members: [(String, JSONValue)] = [
            ("service", .string(grpc.service)),
            ("method", .string(grpc.method)),
            ("callType", .string(grpc.callType.rawValue)),
        ]
        if let code = grpc.statusCode {
            members.append(("statusCode", number(code)))
            members.append(("statusName", .string(GRPCDetails.statusName(for: code))))
        }
        if let message = grpc.statusMessage {
            members.append(("statusMessage", .string(message)))
        }
        members.append(("trailers", headersValue(grpc.trailers)))
        members.append(("messages", .array(grpc.messages.map { message in
            var fields: [(String, JSONValue)] = [
                ("direction", .string(message.direction.rawValue)),
                ("timestamp", .string(DonkFormat.iso8601(message.timestamp))),
                ("typeName", .string(message.typeName)),
                ("size", number(message.size)),
            ]
            if let json = message.json {
                fields.append(("json", .string(json)))
            }
            return object(fields)
        })))
        return object(members)
    }

    // MARK: - Helpers

    private static func headersValue(_ headers: [HTTPHeader]) -> JSONValue {
        .array(headers.map { object([("name", .string($0.name)), ("value", .string($0.value))]) })
    }

    private static func httpVersion(_ entry: NetworkEntry) -> String {
        if entry.kind == .grpc { return "HTTP/2" }
        switch entry.timing.transactions.last?.networkProtocol?.lowercased() {
        case "h2", "http/2", "http/2.0": return "HTTP/2"
        case "h3", "http/3": return "HTTP/3"
        case "http/1.0": return "HTTP/1.0"
        default: return "HTTP/1.1"
        }
    }

    private static func object(_ members: [(String, JSONValue)]) -> JSONValue {
        .object(members.map { JSONMember(key: $0.0, value: $0.1) })
    }

    private static func number(_ value: Int) -> JSONValue {
        .number(String(value))
    }

    private static func number(_ value: Double) -> JSONValue {
        guard value.isFinite else { return .number("-1") }
        if value == -1 { return .number("-1") }
        return .number(String(format: "%.3f", value))
    }

    // MARK: - Timings

    private struct Timings {
        var blocked: Double = -1
        var dns: Double = -1
        var connect: Double = -1
        var ssl: Double = -1
        var send: Double = 0
        var wait: Double = 0
        var receive: Double = 0

        init(_ entry: NetworkEntry) {
            guard let metrics = entry.timing.transactions.last, metrics.requestStart != nil || metrics.responseStart != nil else {
                wait = entry.timing.duration.map { $0 * 1000 } ?? 0
                return
            }
            let firstNetworkEvent = metrics.domainLookupStart ?? metrics.connectStart ?? metrics.requestStart
            blocked = Self.interval(metrics.fetchStart, firstNetworkEvent) ?? -1
            dns = Self.interval(metrics.domainLookupStart, metrics.domainLookupEnd) ?? -1
            connect = Self.interval(metrics.connectStart, metrics.connectEnd) ?? -1
            ssl = Self.interval(metrics.secureConnectionStart, metrics.secureConnectionEnd) ?? -1
            send = Self.interval(metrics.requestStart, metrics.requestEnd) ?? 0
            wait = Self.interval(metrics.requestEnd, metrics.responseStart) ?? 0
            receive = Self.interval(metrics.responseStart, metrics.responseEnd) ?? 0
        }

        var total: Double {
            [blocked, dns, connect, send, wait, receive].filter { $0 >= 0 }.reduce(0, +)
        }

        var value: JSONValue {
            HARExporter.object([
                ("blocked", HARExporter.number(blocked)),
                ("dns", HARExporter.number(dns)),
                ("connect", HARExporter.number(connect)),
                ("ssl", HARExporter.number(ssl)),
                ("send", HARExporter.number(send)),
                ("wait", HARExporter.number(wait)),
                ("receive", HARExporter.number(receive)),
            ])
        }

        private static func interval(_ start: Date?, _ end: Date?) -> Double? {
            guard let start, let end else { return nil }
            return max(0, end.timeIntervalSince(start) * 1000)
        }
    }
}
