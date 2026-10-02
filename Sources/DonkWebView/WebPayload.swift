import DonkCore
import Foundation

enum WebPayload {
    static let errorDomain = "WKWebView"

    static func headers(_ raw: Any?) -> [HTTPHeader] {
        guard let pairs = raw as? [Any] else { return [] }
        return pairs.compactMap { pair in
            guard let values = pair as? [Any], values.count >= 2, let name = values[0] as? String else { return nil }
            let value = values[1] as? String ?? String(describing: values[1])
            return HTTPHeader(name: name, value: value)
        }
    }

    static func body(_ raw: Any?, contentType headerContentType: String?, limit: Int) -> BodyData? {
        guard let dictionary = raw as? [String: Any] else { return nil }
        let declaredSize = dictionary.int("s")
        if let note = dictionary.string("n") {
            var body = BodyData(data: Data(note.utf8), contentType: "text/plain; charset=utf-8", limit: max(limit, note.utf8.count))
            body.originalSize = max(declaredSize ?? 0, body.data.count)
            body.isTruncated = true
            return body
        }
        let data: Data
        if let text = dictionary.string("x") {
            data = Data(text.utf8)
        } else if let encoded = dictionary.string("b64"), let decoded = Data(base64Encoded: encoded) {
            data = decoded
        } else {
            return nil
        }
        let contentType = headerContentType ?? dictionary.string("ct")
        var body = BodyData(data: data, contentType: contentType, limit: limit)
        if dictionary.bool("tr") {
            body.isTruncated = true
            body.originalSize = max(body.originalSize, declaredSize ?? 0)
        }
        return body
    }

    static func sizeOnlyBody(_ raw: [String: Any], contentType: String?) -> BodyData? {
        let size = max(raw.int("ds") ?? 0, raw.int("es") ?? 0)
        guard size > 0 else { return nil }
        var body = BodyData(data: Data(), contentType: contentType, limit: 0)
        body.originalSize = size
        body.isTruncated = true
        return body
    }

    static func timing(_ raw: [String: Any], startKey: String = "t0", endKeys: [String] = ["t1"]) -> NetworkTiming {
        let marks = raw["tm"] as? [String: Any] ?? [:]
        let start = raw.date(startKey) ?? marks.date("fetchStart") ?? Date()
        var end: Date?
        for key in endKeys where end == nil {
            end = raw.date(key) ?? marks.date(key)
        }
        let connectEnd = marks.date("connectEnd")
        let secureStart = marks.date("secureConnectionStart")
        var metrics = TransactionMetrics(
            fetchStart: marks.date("fetchStart"),
            domainLookupStart: marks.date("domainLookupStart"),
            domainLookupEnd: marks.date("domainLookupEnd"),
            connectStart: marks.date("connectStart"),
            connectEnd: connectEnd,
            secureConnectionStart: secureStart,
            secureConnectionEnd: secureStart != nil ? connectEnd : nil,
            requestStart: marks.date("requestStart"),
            responseStart: marks.date("responseStart"),
            responseEnd: marks.date("responseEnd"),
            networkProtocol: raw.string("np").flatMap { $0.isEmpty ? nil : $0 }
        )
        let transfer = raw.int("ts") ?? 0
        let encoded = raw.int("es") ?? 0
        metrics.responseBodyBytes = Int64(encoded)
        metrics.responseHeaderBytes = Int64(max(0, transfer - encoded))
        let hasMetrics = !marks.isEmpty || metrics.networkProtocol != nil || transfer > 0 || encoded > 0
        return NetworkTiming(
            startedAt: start,
            responseStartedAt: marks.date("responseStart"),
            endedAt: end.map { max($0, start) },
            transactions: hasMetrics ? [metrics] : []
        )
    }

    static func normalize(_ url: String) -> String {
        guard var components = URLComponents(string: url) else { return url }
        components.fragment = nil
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if components.path.isEmpty, components.host != nil {
            components.path = "/"
        }
        return components.string ?? url
    }

    static func isReportableDocument(_ url: String) -> Bool {
        let lowered = url.lowercased()
        return lowered.hasPrefix("http://") || lowered.hasPrefix("https://") || lowered.hasPrefix("file://")
    }

    static func errorCode(for reason: String) -> Int {
        switch reason {
        case "abort": return NSURLErrorCancelled
        case "timeout": return NSURLErrorTimedOut
        default: return NSURLErrorUnknown
        }
    }

    static func bytes(_ count: Int) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(count)
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        if index == 0 { return "\(count) B" }
        return String(format: "%.1f %@", value, units[index])
    }

    static func closeCodeName(_ code: Int) -> String? {
        switch code {
        case 1000: return "Normal Closure"
        case 1001: return "Going Away"
        case 1002: return "Protocol Error"
        case 1003: return "Unsupported Data"
        case 1005: return "No Status Received"
        case 1006: return "Abnormal Closure"
        case 1007: return "Invalid Payload"
        case 1008: return "Policy Violation"
        case 1009: return "Message Too Big"
        case 1010: return "Mandatory Extension"
        case 1011: return "Internal Error"
        case 1015: return "TLS Handshake Failure"
        default: return nil
        }
    }
}

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? {
        self[key] as? String
    }

    func number(_ key: String) -> Double? {
        guard let number = self[key] as? NSNumber else { return nil }
        let value = number.doubleValue
        return value.isFinite ? value : nil
    }

    func int(_ key: String) -> Int? {
        guard let value = number(key), abs(value) < 9_000_000_000_000_000 else { return nil }
        return Int(value.rounded())
    }

    func bool(_ key: String) -> Bool {
        (self[key] as? NSNumber)?.boolValue ?? false
    }

    func date(_ key: String) -> Date? {
        guard let milliseconds = number(key), milliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }
}
