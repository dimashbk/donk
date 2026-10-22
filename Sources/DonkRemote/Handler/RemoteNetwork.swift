import DonkCore
import Foundation

enum RemoteNetwork {
    static let defaultLimit = 50
    static let limitRange = 1...500
    static let defaultMaxBodyBytes = 64 * 1024
    static let maxBodyBytesRange = 1024...(1024 * 1024)
    static let defaultMaxMessages = 50
    static let maxMessagesRange = 0...1000

    // MARK: - network.list

    static func list(_ params: RemoteParams, context: RemoteContext) throws -> JSONValue {
        let filter = try self.filter(from: params)
        let limit = try params.clamped("limit", default: defaultLimit, range: limitRange)
        let before = try params.string("before")
        let snapshot = context.store.snapshot()
        let policy = context.policy

        var structural = filter
        structural.query = ""
        let candidates = NetworkSearch.apply(structural, hiddenHosts: [], to: snapshot)
        let searches = !filter.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let matches: [NetworkEntry]
        if searches {
            matches = candidates.compactMap { entry in
                let redacted = policy.map { $0.redact(entry) } ?? entry
                return NetworkSearch.matches(redacted, query: filter.query) ? redacted : nil
            }
        } else {
            matches = candidates
        }

        var start = 0
        if let before {
            let cursor = try RemoteIDResolver.resolve(before, in: snapshot, noun: "entry", id: \.id)
            var positions: [UUID: Int] = [:]
            positions.reserveCapacity(snapshot.count)
            for (offset, entry) in snapshot.enumerated() {
                positions[entry.id] = offset
            }
            let cursorPosition = positions[cursor.id] ?? -1
            start = matches.firstIndex { (positions[$0.id] ?? -1) > cursorPosition } ?? matches.count
        }
        let page = matches[start...].prefix(limit)
        let hasMore = start + page.count < matches.count

        let summaries: [JSONValue] = page.map { entry in
            let visible: NetworkEntry
            if searches {
                visible = entry
            } else {
                visible = policy.map { $0.redact(metadataOnly(entry)) } ?? entry
            }
            return summary(visible).value
        }
        var result = RemoteObject()
        result.set("total", matches.count)
        result.set("entries", .array(summaries))
        if hasMore {
            result.set("nextBefore", page.last?.id.uuidString)
        }
        return result.value
    }

    static func filter(from params: RemoteParams) throws -> NetworkFilter {
        var filter = NetworkFilter()
        filter.query = try params.string("query") ?? ""
        if let kinds = try params.strings("kinds") {
            filter.kinds = Set(try kinds.map { raw in
                guard let kind = NetworkKind(rawValue: raw) else {
                    throw RemoteError.invalidParams("unknown kind \(raw); expected http, grpc or webView")
                }
                return kind
            })
        }
        if let hosts = try params.strings("hosts") {
            filter.hosts = Set(hosts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })
        }
        if let statuses = try params.strings("status") {
            filter.statusCategories = Set(try statuses.map { raw in
                guard let category = StatusCategory(rawValue: raw) else {
                    let known = StatusCategory.allCases.map(\.rawValue).joined(separator: ", ")
                    throw RemoteError.invalidParams("unknown status \(raw); expected one of \(known)")
                }
                return category
            })
        }
        filter.onlyModified = try params.bool("onlyModified") ?? false
        filter.onlyPinned = try params.bool("onlyPinned") ?? false
        return filter
    }

    static func metadataOnly(_ entry: NetworkEntry) -> NetworkEntry {
        var copy = entry
        copy.request.body = entry.request.body.map(emptied)
        copy.response?.body = entry.response?.body.map(emptied)
        if var grpc = entry.grpc, grpc.messageCount > 0 {
            grpc.messages = grpc.messages.map { message in
                var stripped = message
                stripped.json = nil
                stripped.textFormat = nil
                stripped.raw = nil
                return stripped
            }
            copy.grpc = grpc
        }
        return copy
    }

    private static func emptied(_ body: BodyData) -> BodyData {
        var copy = body
        copy.data = Data()
        return copy
    }

    // MARK: - network.get

    static func get(_ params: RemoteParams, context: RemoteContext) throws -> JSONValue {
        guard let input = try params.string("id") else {
            throw RemoteError.invalidParams("id is required")
        }
        let maxBodyBytes = try params.clamped("maxBodyBytes", default: defaultMaxBodyBytes, range: maxBodyBytesRange)
        let maxMessages = try params.clamped("maxMessages", default: defaultMaxMessages, range: maxMessagesRange)
        let raw: NetworkEntry
        if let uuid = UUID(uuidString: input.trimmingCharacters(in: .whitespacesAndNewlines)) {
            guard let entry = context.store.entry(uuid) else {
                throw RemoteError.notFound("entry \(uuid.uuidString) not found")
            }
            raw = entry
        } else {
            raw = try RemoteIDResolver.resolve(input, in: context.store.snapshot(), noun: "entry", id: \.id)
        }
        let entry = context.policy.map { $0.redact(raw) } ?? raw
        var result = RemoteObject()
        result.set("entry", detail(entry, maxBodyBytes: maxBodyBytes, maxMessages: maxMessages))
        return result.value
    }

    // MARK: - Mapping

    static func summary(_ entry: NetworkEntry) -> RemoteObject {
        var object = RemoteObject()
        object.set("id", entry.id.uuidString)
        object.set("kind", entry.kind.rawValue)
        object.set("state", entry.state.rawValue)
        switch entry.origin {
        case .network:
            object.set("origin", "network")
        case let .mocked(rule):
            object.set("origin", "mocked")
            object.set("rule", rule)
        case let .rewritten(rule):
            object.set("origin", "rewritten")
            object.set("rule", rule)
        case .breakpoint:
            object.set("origin", "breakpoint")
        }
        object.set("method", entry.methodLabel)
        object.set("title", entry.title)
        object.set("url", entry.request.url)
        object.set("host", entry.host)
        object.set("status", entry.statusLabel)
        object.set("statusCategory", entry.statusCategory.rawValue)
        object.set("startedAt", date: entry.timing.startedAt)
        object.set("durationMs", number: entry.duration.map { $0 * 1000 })
        object.set("requestSize", entry.requestSize)
        object.set("responseSize", entry.responseSize)
        object.set("error", entry.error?.message)
        object.set("pinned", entry.isPinned)
        if let grpc = entry.grpc {
            var details = grpcStatus(grpc)
            details.set("messages", grpc.sentMessageCount + grpc.receivedMessageCount)
            object.set("grpc", details.value)
        }
        return object
    }

    static func detail(_ entry: NetworkEntry, maxBodyBytes: Int, maxMessages: Int) -> JSONValue {
        var object = summary(entry)

        var request = RemoteObject()
        request.set("url", entry.request.url)
        request.set("method", entry.request.method)
        request.set("headers", RemoteJSON.headers(entry.request.headers))
        request.set("body", entry.request.body.map { body($0, maxBytes: maxBodyBytes) })
        object.set("request", request.value)

        if let response = entry.response {
            var value = RemoteObject()
            value.set("statusCode", response.statusCode)
            value.set("headers", RemoteJSON.headers(response.headers))
            value.set("body", response.body.map { body($0, maxBytes: maxBodyBytes) })
            object.set("response", value.value)
        }

        if let error = entry.error {
            var value = RemoteObject()
            value.set("domain", error.domain)
            value.set("code", error.code)
            value.set("message", error.message)
            object.set("errorInfo", value.value)
        }

        object.set("timing", timing(entry.timing))

        if let grpc = entry.grpc {
            object.set("grpc", grpcDetail(grpc, maxBytes: maxBodyBytes, maxMessages: maxMessages))
        }

        if let web = entry.web {
            var value = RemoteObject()
            value.setNonEmpty("pageURL", web.pageURL)
            value.set("initiator", web.initiator.rawValue)
            value.set("captureLevel", web.captureLevel.rawValue)
            object.set("web", value.value)
        }

        switch entry.kind {
        case .grpc:
            object.set("grpcurl", GRPCurlExporter.command(for: entry))
        case .http, .webView:
            object.set("curl", CurlExporter.command(for: entry.request))
        }
        return object.value
    }

    static func body(_ body: BodyData, maxBytes: Int) -> JSONValue {
        let isImage = body.isImage
        let isTextImage = body.mimeType?.contains("svg") ?? false
        let text = isImage && !isTextImage ? nil : (body.prettyJSON ?? body.text)
        let cut = text.map { RemoteJSON.prefix($0, maxBytes: maxBytes) }
        var object = RemoteObject()
        object.setNonEmpty("contentType", body.contentType)
        object.set("size", body.originalSize)
        object.set("truncated", body.isTruncated || (cut?.isCut ?? false))
        object.set("encoding", cut == nil ? "binary" : "text")
        object.set("text", cut?.text)
        if isImage {
            object.set("image", true)
        }
        return object.value
    }

    private static func timing(_ timing: NetworkTiming) -> JSONValue {
        var object = RemoteObject()
        object.set("startedAt", date: timing.startedAt)
        object.set("responseStartedAt", date: timing.responseStartedAt)
        object.set("endedAt", date: timing.endedAt)
        object.set("durationMs", number: timing.duration.map { $0 * 1000 })
        if let last = timing.transactions.last {
            object.setNonEmpty("protocol", last.networkProtocol)
            object.setNonEmpty("remoteAddress", last.remoteAddress)
            object.set("reusedConnection", last.isReusedConnection)
        }
        return object.value
    }

    private static func grpcStatus(_ grpc: GRPCDetails) -> RemoteObject {
        var object = RemoteObject()
        object.set("service", grpc.service)
        object.set("method", grpc.method)
        object.set("statusCode", grpc.statusCode)
        object.set("statusName", grpc.statusName)
        object.set("statusMessage", grpc.statusMessage)
        return object
    }

    private static func grpcDetail(_ grpc: GRPCDetails, maxBytes: Int, maxMessages: Int) -> JSONValue {
        var object = grpcStatus(grpc)
        object.set("path", grpc.path)
        object.set("callType", grpc.callType.rawValue)
        object.set("timeoutSec", number: grpc.timeout)
        object.set("requestMetadata", RemoteJSON.headers(grpc.requestMetadata))
        object.set("responseHeaders", RemoteJSON.headers(grpc.responseHeaders))
        object.set("trailers", RemoteJSON.headers(grpc.trailers))
        object.set("sentMessageCount", grpc.sentMessageCount)
        object.set("receivedMessageCount", grpc.receivedMessageCount)
        object.set("droppedMessageCount", grpc.droppedMessageCount)
        object.set("messages", .array(grpc.messages.suffix(maxMessages).map { message($0, maxBytes: maxBytes) }))
        return object.value
    }

    private static func message(_ message: GRPCMessage, maxBytes: Int) -> JSONValue {
        var object = RemoteObject()
        object.set("direction", message.direction.rawValue)
        object.set("timestamp", date: message.timestamp)
        object.set("typeName", message.typeName)
        object.set("size", message.size)
        if let json = message.json {
            let cut = RemoteJSON.prefix(json, maxBytes: maxBytes)
            object.set("json", cut.text)
            if cut.isCut { object.set("truncated", true) }
        } else if let textFormat = message.textFormat {
            let cut = RemoteJSON.prefix(textFormat, maxBytes: maxBytes)
            object.set("textFormat", cut.text)
            if cut.isCut { object.set("truncated", true) }
        }
        return object.value
    }
}
