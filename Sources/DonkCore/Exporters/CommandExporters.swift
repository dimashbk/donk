import Foundation

public enum CurlExporter {
    public static func command(for request: RequestSnapshot) -> String {
        command(for: request, redaction: nil)
    }

    public static func command(for request: RequestSnapshot, redaction: RedactionPolicy?) -> String {
        let request = redaction.map { $0.redact(request) } ?? request
        let trimmedMethod = request.method.trimmingCharacters(in: .whitespaces).uppercased()
        let method = trimmedMethod.isEmpty ? "GET" : trimmedMethod
        let body = request.body.flatMap { $0.data.isEmpty ? nil : $0 }
        var first = "curl"
        if method == "HEAD", body == nil {
            first += " --head"
        } else if method != "GET" || body != nil {
            first += " -X " + token(method)
        }
        if request.url.contains(where: { "[]{}".contains($0) }) {
            first += " --globoff"
        }
        first += " " + Shell.quote(request.url)
        var parts = [first]
        for header in request.headers where !header.name.hasPrefix(":") && header.name.lowercased() != "content-length" {
            parts.append("-H " + Shell.quote("\(header.name): \(header.value)"))
        }
        if let encoding = request.header("Accept-Encoding")?.lowercased(),
           ["gzip", "br", "deflate"].contains(where: { encoding.contains($0) }) {
            parts.append("--compressed")
        }
        if let body {
            if let text = body.text {
                parts.append("--data-raw " + Shell.quote(text))
            } else {
                parts.append("--data-binary @body.bin")
            }
        }
        let command = parts.joined(separator: " \\\n  ")
        if let body, body.isTruncated {
            return "# donk: request body truncated (\(body.data.count) of \(body.originalSize) bytes)\n" + command
        }
        return command
    }

    private static func token(_ method: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return method.unicodeScalars.allSatisfy(allowed.contains) ? method : Shell.quote(method)
    }
}

public enum GRPCurlExporter {
    static let skippedMetadata: Set<String> = ["content-type", "te", "grpc-accept-encoding", "user-agent", "grpc-timeout"]

    public static func command(for entry: NetworkEntry, plaintext: Bool = false) -> String {
        command(for: entry, plaintext: plaintext, redaction: nil)
    }

    public static func command(for entry: NetworkEntry, plaintext: Bool = false, redaction: RedactionPolicy?) -> String {
        let entry = redaction.map { $0.redact(entry) } ?? entry
        var parts = ["grpcurl"]
        if plaintext { parts.append("-plaintext") }
        let metadata = entry.grpc.map { $0.requestMetadata.isEmpty ? entry.request.headers : $0.requestMetadata }
            ?? entry.request.headers
        for header in metadata {
            let name = header.name.lowercased()
            guard !name.hasPrefix(":"), !skippedMetadata.contains(name) else { continue }
            parts.append("-H " + Shell.quote("\(header.name): \(header.value)"))
        }
        if let data = payload(for: entry) {
            parts.append("-d " + Shell.quote(data))
        }
        if let timeout = entry.grpc?.timeout, timeout > 0, timeout.isFinite {
            parts.append("-max-time " + DonkFormat.seconds(timeout))
        }
        parts.append(address(for: entry.request.url))
        parts.append(symbol(for: entry))
        return parts.joined(separator: " \\\n  ")
    }

    private static func payload(for entry: NetworkEntry) -> String? {
        guard let grpc = entry.grpc else {
            return entry.request.body?.text.map(compact)
        }
        let sent = grpc.messages.filter { $0.direction == .sent }.compactMap(\.json)
        if sent.isEmpty {
            return entry.request.body?.text.map(compact)
        }
        switch grpc.callType {
        case .unary, .serverStreaming:
            return compact(sent[0])
        case .clientStreaming, .bidirectionalStreaming:
            return sent.map(compact).joined(separator: "\n")
        }
    }

    private static func compact(_ json: String) -> String {
        (try? JSONValue.parse(json).compact()) ?? json.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func address(for url: String) -> String {
        var rest = Substring(url)
        if let separator = rest.range(of: "://") {
            rest = rest[separator.upperBound...]
        }
        let authority = rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        var host = String(authority)
        if let at = host.lastIndex(of: "@") {
            host = String(host[host.index(after: at)...])
        }
        if host.isEmpty { host = "localhost" }
        let hasPort: Bool
        if host.hasPrefix("[") {
            hasPort = host.contains("]:")
        } else {
            hasPort = host.contains(":")
        }
        return hasPort ? host : host + ":443"
    }

    private static func symbol(for entry: NetworkEntry) -> String {
        let service: String
        let method: String
        if let grpc = entry.grpc, !grpc.method.isEmpty {
            service = grpc.service
            method = grpc.method
        } else {
            let parts = GRPCDetails.split(path: entry.request.path)
            service = parts.service
            method = parts.method
        }
        return service.isEmpty ? method : "\(service)/\(method)"
    }
}
