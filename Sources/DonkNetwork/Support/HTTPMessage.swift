import DonkCore
import Foundation

package struct RequestParts {
    package var request: URLRequest
    package var body: RequestBody

    package init(request: URLRequest, body: RequestBody) {
        self.request = request
        self.body = body
    }

    package var urlString: String { request.url?.absoluteString ?? "" }

    package var method: String {
        let method = request.httpMethod?.trimmingCharacters(in: .whitespaces).uppercased() ?? ""
        return method.isEmpty ? "GET" : method
    }

    package var headers: [HTTPHeader] { HTTPHeader.list(from: request.allHTTPHeaderFields) }
}

package struct ResponseParts: Equatable {
    package var url: URL
    package var statusCode: Int
    package var headers: [HTTPHeader]
    package var body: Data

    package init(url: URL, statusCode: Int, headers: [HTTPHeader], body: Data) {
        self.url = url
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    package init(response: HTTPURLResponse, body: Data, fallbackURL: URL) {
        self.init(
            url: response.url ?? fallbackURL,
            statusCode: response.statusCode,
            headers: HTTPHeader.list(from: response.allHeaderFields),
            body: body
        )
    }
}

package enum HTTPMessage {
    // MARK: - Snapshots

    package static func contentType(in headers: [HTTPHeader]) -> String? {
        headers.value(for: "Content-Type")
    }

    package static func bodyData(_ body: RequestBody, contentType: String?, limit: Int) -> BodyData? {
        guard body.size > 0 else { return nil }
        var snapshot = BodyData(data: body.prefix, contentType: contentType, limit: limit)
        snapshot.originalSize = body.size
        snapshot.isTruncated = body.size > snapshot.data.count
        return snapshot
    }

    package static func bodyData(_ data: Data, totalBytes: Int, contentType: String?, limit: Int) -> BodyData? {
        guard totalBytes > 0 || !data.isEmpty else { return nil }
        var snapshot = BodyData(data: data, contentType: contentType, limit: limit)
        snapshot.originalSize = max(totalBytes, data.count)
        snapshot.isTruncated = snapshot.originalSize > snapshot.data.count
        return snapshot
    }

    package static func mergedHeaders(_ headers: [HTTPHeader], extra: [HTTPHeader]) -> [HTTPHeader] {
        guard !extra.isEmpty else { return headers }
        let present = Set(headers.map { $0.name.lowercased() })
        let missing = extra.filter { !present.contains($0.name.lowercased()) }
        guard !missing.isEmpty else { return headers }
        return HTTPHeader.list(from: Dictionary((headers + missing).map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first }))
    }

    package static func requestSnapshot(_ parts: RequestParts, extraHeaders: [HTTPHeader], limit: Int) -> RequestSnapshot {
        let headers = mergedHeaders(parts.headers, extra: extraHeaders)
        return RequestSnapshot(
            url: parts.urlString,
            method: parts.method,
            headers: headers,
            body: bodyData(parts.body, contentType: contentType(in: headers), limit: limit)
        )
    }

    package static func responseSnapshot(_ response: URLResponse?, body: Data, totalBytes: Int, limit: Int) -> ResponseSnapshot? {
        guard let response else { return nil }
        let http = response as? HTTPURLResponse
        let headers = HTTPHeader.list(from: http?.allHeaderFields)
        let contentType = headers.value(for: "Content-Type") ?? response.mimeType
        return ResponseSnapshot(
            statusCode: http?.statusCode ?? 200,
            headers: headers,
            body: bodyData(body, totalBytes: totalBytes, contentType: contentType, limit: limit)
        )
    }

    package static func responseSnapshot(_ parts: ResponseParts, limit: Int) -> ResponseSnapshot {
        ResponseSnapshot(
            statusCode: parts.statusCode,
            headers: parts.headers,
            body: bodyData(parts.body, totalBytes: parts.body.count, contentType: contentType(in: parts.headers), limit: limit)
        )
    }

    // MARK: - Requests

    package static func setHeaders(_ headers: [HTTPHeader], on request: inout URLRequest) {
        for name in (request.allHTTPHeaderFields ?? [:]).keys {
            request.setValue(nil, forHTTPHeaderField: name)
        }
        for (name, value) in joined(headers) {
            request.setValue(value, forHTTPHeaderField: name)
        }
    }

    package static func joined(_ headers: [HTTPHeader]) -> [String: String] {
        var result: [String: String] = [:]
        var canonical: [String: String] = [:]
        for header in headers {
            let name = header.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            let key = name.lowercased()
            if let existing = canonical[key], let value = result[existing] {
                result[existing] = value + ", " + header.value
            } else {
                canonical[key] = name
                result[name] = header.value
            }
        }
        return result
    }

    package static func marked(_ request: URLRequest, key: String, value: Any?) -> URLRequest {
        guard let mutable = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else { return request }
        if let value {
            URLProtocol.setProperty(value, forKey: key, in: mutable)
        } else {
            URLProtocol.removeProperty(forKey: key, in: mutable)
        }
        return mutable as URLRequest
    }

    package static func preparedInnerRequest(_ parts: RequestParts) -> URLRequest {
        var request = parts.request
        switch parts.body {
        case .none:
            request.httpBodyStream = nil
            request.httpBody = nil
        case let .data(data):
            request.httpBody = data
        case .file:
            request.httpBodyStream = nil
            request.httpBody = nil
        }
        if request.value(forHTTPHeaderField: "Content-Length") != nil {
            request.setValue(String(parts.body.size), forHTTPHeaderField: "Content-Length")
        }
        return marked(request, key: DonkURLProtocol.handledKey, value: true)
    }

    // MARK: - Rules

    package static func apply(_ rewrite: RequestRewrite, to parts: inout RequestParts) {
        if let value = rewrite.url?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty, let url = URL(string: value) {
            parts.request.url = url
        }
        if let method = rewrite.method?.trimmingCharacters(in: .whitespaces), !method.isEmpty {
            parts.request.httpMethod = method.uppercased()
        }
        if !rewrite.headers.isEmpty {
            setHeaders(rewrite.headers.apply(to: parts.headers), on: &parts.request)
        }
        if rewrite.body != .keep {
            replaceBody(of: &parts, with: rewrite.body.apply(to: parts.body.loadData()) ?? Data())
        }
    }

    package static func apply(_ rewrite: ResponseRewrite, to parts: inout ResponseParts) {
        if let statusCode = rewrite.statusCode, statusCode > 0 {
            parts.statusCode = statusCode
        }
        if !rewrite.headers.isEmpty {
            parts.headers = rewrite.headers.apply(to: parts.headers)
        }
        if rewrite.body != .keep {
            replaceBody(of: &parts, with: rewrite.body.apply(to: parts.body) ?? Data())
        }
    }

    package static func replaceBody(of parts: inout RequestParts, with data: Data) {
        if let url = parts.body.fileURL {
            try? FileManager.default.removeItem(at: url)
        }
        parts.body = data.isEmpty ? .none : .data(data)
    }

    package static func replaceBody(of parts: inout ResponseParts, with data: Data) {
        parts.body = data
        if let index = parts.headers.firstIndex(where: { $0.name.caseInsensitiveCompare("Content-Length") == .orderedSame }) {
            parts.headers[index].value = String(data.count)
        }
    }

    // MARK: - Breakpoints

    package static func editable(_ parts: RequestParts) -> EditableRequest {
        let body = BodyEncoding.editable(parts.body.loadData())
        return EditableRequest(url: parts.urlString, method: parts.method, headers: parts.headers, body: body.text, bodyIsBinary: body.isBinary)
    }

    package static func apply(_ edited: EditableRequest, original: EditableRequest, to parts: inout RequestParts) {
        if edited.url != original.url, let url = URL(string: edited.url.trimmingCharacters(in: .whitespacesAndNewlines)) {
            parts.request.url = url
        }
        if edited.method != original.method {
            let method = edited.method.trimmingCharacters(in: .whitespaces).uppercased()
            parts.request.httpMethod = method.isEmpty ? "GET" : method
        }
        if edited.headers != original.headers {
            setHeaders(edited.headers, on: &parts.request)
        }
        if edited.body != original.body || edited.bodyIsBinary != original.bodyIsBinary {
            replaceBody(of: &parts, with: edited.bodyData)
        }
    }

    package static func editable(_ parts: ResponseParts) -> EditableResponse {
        let body = BodyEncoding.editable(parts.body)
        return EditableResponse(statusCode: parts.statusCode, headers: parts.headers, body: body.text, bodyIsBinary: body.isBinary)
    }

    package static func apply(_ edited: EditableResponse, original: EditableResponse, to parts: inout ResponseParts) {
        if edited.statusCode > 0 {
            parts.statusCode = edited.statusCode
        }
        if edited.headers != original.headers {
            parts.headers = edited.headers
        }
        if edited.body != original.body || edited.bodyIsBinary != original.bodyIsBinary {
            replaceBody(of: &parts, with: edited.bodyData)
        }
    }

    package static func responseParts(_ response: EditableResponse, url: URL) -> ResponseParts {
        var parts = ResponseParts(url: url, statusCode: response.statusCode > 0 ? response.statusCode : 200, headers: response.headers, body: response.bodyData)
        ensureContentHeaders(&parts)
        return parts
    }

    // MARK: - Local responses

    package static func responseParts(_ mock: MockResponse, url: URL) -> ResponseParts {
        var parts = ResponseParts(url: url, statusCode: mock.statusCode > 0 ? mock.statusCode : 200, headers: mock.headers, body: mock.bodyData)
        ensureContentHeaders(&parts, isBinary: mock.body.hasPrefix(BodyEncoding.base64Prefix))
        return parts
    }

    package static func ensureContentHeaders(_ parts: inout ResponseParts, isBinary: Bool = false) {
        if parts.headers.value(for: "Content-Type") == nil, !parts.body.isEmpty {
            parts.headers.append(HTTPHeader(name: "Content-Type", value: inferredContentType(for: parts.body, isBinary: isBinary)))
        }
        if let index = parts.headers.firstIndex(where: { $0.name.caseInsensitiveCompare("Content-Length") == .orderedSame }) {
            parts.headers[index].value = String(parts.body.count)
        } else {
            parts.headers.append(HTTPHeader(name: "Content-Length", value: String(parts.body.count)))
        }
    }

    package static func inferredContentType(for data: Data, isBinary: Bool = false) -> String {
        let probe = BodyData(data: data, contentType: nil, limit: .max)
        if probe.isImage {
            let bytes = [UInt8](data.prefix(12))
            if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
            if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
            if bytes.starts(with: Array("GIF8".utf8)) { return "image/gif" }
            if bytes.count >= 12, Array(bytes[8..<12]) == Array("WEBP".utf8) { return "image/webp" }
            return "image/heic"
        }
        if isBinary || String(data: data, encoding: .utf8) == nil {
            return "application/octet-stream"
        }
        if JSONFormatting.isValid(data) {
            return "application/json; charset=utf-8"
        }
        let text = String(decoding: data.prefix(256), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("<!doctype html") || text.hasPrefix("<html") {
            return "text/html; charset=utf-8"
        }
        if text.hasPrefix("<?xml") {
            return "application/xml; charset=utf-8"
        }
        return "text/plain; charset=utf-8"
    }

    package static func detached(_ response: URLResponse) -> URLResponse {
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: response, requiringSecureCoding: true),
           let copy = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [HTTPURLResponse.self, URLResponse.self], from: data) as? URLResponse,
           copy !== response {
            return copy
        }
        if let http = response as? HTTPURLResponse, let url = http.url,
           let copy = HTTPURLResponse(url: url, statusCode: http.statusCode, httpVersion: nil, headerFields: joined(HTTPHeader.list(from: http.allHeaderFields))) {
            return copy
        }
        return response
    }

    package static func makeResponse(_ parts: ResponseParts) -> HTTPURLResponse {
        let statusCode = (100...999).contains(parts.statusCode) ? parts.statusCode : 200
        return HTTPURLResponse(url: parts.url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: joined(parts.headers))
            ?? HTTPURLResponse(url: parts.url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
    }

    package static func isStreamingContentType(_ contentType: String?) -> Bool {
        guard let contentType = contentType?.lowercased() else { return false }
        return contentType.contains("text/event-stream")
            || contentType.contains("application/x-ndjson")
            || contentType.contains("application/ndjson")
    }
}
