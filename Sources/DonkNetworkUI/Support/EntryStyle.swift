import DonkCore
import DonkUI
import Foundation

// MARK: - Tones & labels

enum EntryStyle {
    static func tone(for category: StatusCategory) -> DonkTone {
        switch category {
        case .pending: return .neutral
        case .success: return .success
        case .redirect: return .info
        case .clientError: return .warning
        case .serverError: return .error
        case .failure: return .error
        }
    }

    static func statusTone(_ entry: NetworkEntry) -> DonkTone {
        if entry.state == .paused { return .warning }
        if entry.kind == .grpc, let code = entry.grpc?.statusCode { return .grpcStatus(code) }
        if entry.statusCategory == .pending { return liveTone(entry) }
        return tone(for: entry.statusCategory)
    }

    static func barTone(_ entry: NetworkEntry) -> DonkTone {
        if entry.state == .paused { return .warning }
        if entry.state == .streaming { return liveTone(entry) }
        if entry.statusCategory == .pending { return .info }
        return tone(for: entry.statusCategory)
    }

    static func liveTone(_ entry: NetworkEntry) -> DonkTone {
        entry.kind == .grpc ? .grpc : .info
    }

    static func statusLabel(_ entry: NetworkEntry) -> String {
        if entry.kind == .grpc, entry.grpc?.statusCode == nil, entry.state == .streaming { return "LIVE" }
        return entry.statusLabel
    }

    static func kindTitle(_ kind: NetworkKind) -> String {
        switch kind {
        case .http: return "HTTP"
        case .grpc: return "gRPC"
        case .webView: return "WebView"
        }
    }

    static func kindIcon(_ kind: NetworkKind) -> String {
        switch kind {
        case .http: return "network"
        case .grpc: return "point.3.connected.trianglepath.dotted"
        case .webView: return "safari"
        }
    }

    static func kindTone(_ kind: NetworkKind) -> DonkTone {
        switch kind {
        case .http: return .info
        case .grpc: return .grpc
        case .webView: return .web
        }
    }

    static func categoryTitle(_ category: StatusCategory) -> String {
        switch category {
        case .pending: return "In progress"
        case .success: return "Success"
        case .redirect: return "Redirect"
        case .clientError: return "Client error"
        case .serverError: return "Server error"
        case .failure: return "Failed"
        }
    }

    static func categoryIcon(_ category: StatusCategory) -> String {
        switch category {
        case .pending: return "hourglass"
        case .success: return "checkmark.circle"
        case .redirect: return "arrow.uturn.right.circle"
        case .clientError: return "exclamationmark.circle"
        case .serverError: return "xmark.octagon"
        case .failure: return "bolt.horizontal.circle"
        }
    }

    static func categoryHint(_ category: StatusCategory) -> String {
        switch category {
        case .pending: return "Pending, paused or streaming"
        case .success: return "2xx · gRPC OK"
        case .redirect: return "3xx"
        case .clientError: return "4xx · client-side gRPC codes"
        case .serverError: return "5xx · server-side gRPC codes"
        case .failure: return "Transport errors, cancelled"
        }
    }

    static let errorCategories: Set<StatusCategory> = [.clientError, .serverError, .failure]

    static func stateTitle(_ state: NetworkState) -> String {
        switch state {
        case .pending: return "Pending"
        case .paused: return "Paused"
        case .streaming: return "Streaming"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    static func stateTone(_ state: NetworkState) -> DonkTone {
        switch state {
        case .pending: return .info
        case .paused: return .warning
        case .streaming: return .accent
        case .completed: return .success
        case .failed: return .error
        case .cancelled: return .neutral
        }
    }

    static func stateIcon(_ state: NetworkState) -> String {
        switch state {
        case .pending: return "hourglass"
        case .paused: return "pause.fill"
        case .streaming: return "dot.radiowaves.left.and.right"
        case .completed: return "checkmark"
        case .failed: return "xmark"
        case .cancelled: return "slash.circle"
        }
    }

    static func originBadge(_ origin: NetworkOrigin) -> OriginBadge? {
        switch origin {
        case .network: return nil
        case .mocked: return .mocked
        case .rewritten: return .rewritten
        case let .breakpoint(edited): return .breakpoint(edited: edited)
        }
    }

    static func originRuleName(_ origin: NetworkOrigin) -> String? {
        switch origin {
        case let .mocked(rule), let .rewritten(rule): return rule
        case .network, .breakpoint: return nil
        }
    }

    static func initiatorTitle(_ initiator: WebInitiator) -> String {
        switch initiator {
        case .document: return "document"
        case .fetch: return "fetch"
        case .xhr: return "xhr"
        case .beacon: return "beacon"
        case .websocket: return "websocket"
        case .eventSource: return "event source"
        case .resource: return "resource"
        }
    }

    static func protocolName(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "h2", "http/2", "http/2.0": return "HTTP/2"
        case "h3", "http/3": return "HTTP/3"
        case "http/1.1": return "HTTP/1.1"
        case "http/1.0": return "HTTP/1.0"
        default: return raw.uppercased()
        }
    }

    static func isStreamedHTTP(_ entry: NetworkEntry) -> Bool {
        guard entry.kind != .grpc else { return false }
        if let type = entry.response?.header("Content-Type")?.lowercased(), type.contains("text/event-stream") {
            return true
        }
        return entry.web?.initiator == .eventSource
    }

    static func showsMessages(_ entry: NetworkEntry) -> Bool {
        entry.kind == .grpc || isStreamedHTTP(entry)
    }

    static func canRepeat(_ entry: NetworkEntry) -> Bool {
        guard entry.kind == .http else { return false }
        let scheme = URL(string: entry.request.url)?.scheme?.lowercased()
        return scheme == "http" || scheme == "https"
    }
}

// MARK: - Origin badge

enum OriginBadge: Equatable, Sendable {
    case mocked, rewritten, breakpoint(edited: Bool)

    var title: String {
        switch self {
        case .mocked: return "Mocked"
        case .rewritten: return "Rewritten"
        case let .breakpoint(edited): return edited ? "Edited" : "Breakpoint"
        }
    }

    var icon: String {
        switch self {
        case .mocked: return "wand.and.stars"
        case .rewritten: return "pencil"
        case .breakpoint: return "pause.circle"
        }
    }

    var tone: DonkTone {
        switch self {
        case .mocked: return .accent
        case .rewritten: return .warning
        case .breakpoint: return .info
        }
    }
}

// MARK: - Formatting

enum EntryFormat {
    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    static func clock(_ date: Date) -> String {
        clockFormatter.string(from: date)
    }

    static func timestamp(_ date: Date) -> String {
        let fraction = date.timeIntervalSince1970.truncatingRemainder(dividingBy: 1)
        return DonkFormat.dateTime(date) + String(format: ".%03d", Int(fraction * 1000))
    }

    static func offset(_ interval: TimeInterval) -> String {
        let milliseconds = max(0, interval) * 1000
        if milliseconds < 10 { return String(format: "+%.1f ms", milliseconds) }
        if milliseconds < 10_000 { return String(format: "+%.0f ms", milliseconds) }
        return "+" + DonkFormat.duration(interval)
    }

    static func status(_ entry: NetworkEntry) -> String {
        if entry.kind == .grpc {
            if let code = entry.grpc?.statusCode {
                return "\(GRPCDetails.statusName(for: code)) (\(code))"
            }
            return entry.state.isInFlight ? EntryStyle.stateTitle(entry.state) : entry.statusLabel
        }
        if let code = entry.response?.statusCode, code > 0 {
            let phrase = ResponseSnapshot.reasonPhrase(for: code)
            return phrase.isEmpty ? "\(code)" : "\(code) \(phrase)"
        }
        return entry.statusLabel
    }

    static func urlWithoutQuery(_ url: String) -> String {
        var cut = url.endIndex
        if let query = url.firstIndex(of: "?") { cut = query }
        if let fragment = url.firstIndex(of: "#"), fragment < cut { cut = fragment }
        return String(url[..<cut])
    }

    static func hexDump(_ data: Data, limit: Int = 4096) -> String {
        let bytes = [UInt8](data.prefix(limit))
        guard !bytes.isEmpty else { return "" }
        var lines: [String] = []
        lines.reserveCapacity(bytes.count / 16 + 2)
        var offset = 0
        while offset < bytes.count {
            let chunk = bytes[offset..<min(offset + 16, bytes.count)]
            var hex = ""
            for (index, byte) in chunk.enumerated() {
                hex += String(format: "%02x ", byte)
                if index == 7 { hex += " " }
            }
            let padding = String(repeating: " ", count: max(0, 49 - hex.count))
            let ascii = String(chunk.map { $0 >= 0x20 && $0 < 0x7F ? Character(UnicodeScalar($0)) : "." })
            lines.append(String(format: "%08x  ", offset) + hex + padding + " |" + ascii + "|")
            offset += 16
        }
        if data.count > limit {
            lines.append("… \(DonkFormat.bytes(data.count - limit)) more")
        }
        return lines.joined(separator: "\n")
    }

    static func formFields(_ text: String) -> [DonkKeyValue] {
        text.split(separator: "&", omittingEmptySubsequences: true).map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = decodeFormComponent(String(parts.first ?? ""))
            let value = parts.count > 1 ? decodeFormComponent(String(parts[1])) : ""
            return DonkKeyValue(key: key, value: value)
        }
    }

    private static func decodeFormComponent(_ raw: String) -> String {
        let spaced = raw.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }

    static func fileExtension(for body: BodyData?) -> String {
        guard let body else { return "txt" }
        let mime = body.mimeType ?? ""
        let known: [(String, String)] = [
            ("json", "json"), ("xml", "xml"), ("html", "html"), ("css", "css"), ("javascript", "js"),
            ("csv", "csv"), ("png", "png"), ("jpeg", "jpg"), ("jpg", "jpg"), ("gif", "gif"), ("webp", "webp"),
            ("heic", "heic"), ("svg", "svg"), ("pdf", "pdf"), ("protobuf", "bin"), ("grpc", "bin"),
            ("x-www-form-urlencoded", "txt"), ("event-stream", "txt"), ("text/plain", "txt"), ("zip", "zip"),
        ]
        for (needle, ext) in known where mime.contains(needle) {
            return ext
        }
        if body.isJSON { return "json" }
        let head = [UInt8](body.data.prefix(4))
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if head.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if head.starts(with: [0x47, 0x49, 0x46]) { return "gif" }
        return body.text != nil ? "txt" : "bin"
    }

    static func fileName(for entry: NetworkEntry, part: String, body: BodyData?) -> String {
        let base = entry.title
            .split(separator: "/")
            .last
            .map(String.init)?
            .split(separator: "?").first
            .map(String.init) ?? "body"
        let cleaned = base.isEmpty ? "body" : base
        return "\(cleaned)-\(part).\(fileExtension(for: body))"
    }
}
