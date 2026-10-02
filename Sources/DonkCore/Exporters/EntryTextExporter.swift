import Foundation

public enum EntryTextExporter {
    public static func text(for entry: NetworkEntry) -> String {
        text(for: entry, redaction: nil)
    }

    public static func text(for entry: NetworkEntry, redaction: RedactionPolicy?) -> String {
        let entry = redaction.map { $0.redact(entry) } ?? entry
        var sections: [String] = [summary(for: entry)]
        sections.append(requestSection(for: entry))
        if let response = responseSection(for: entry) {
            sections.append(response)
        }
        if let grpc = entry.grpc {
            sections.append(grpcSection(for: grpc))
        }
        sections.append(timingSection(for: entry))
        if let error = entry.error {
            sections.append("ERROR\n\(error.domain) \(error.code): \(error.message)")
        }
        return sections.joined(separator: "\n\n") + "\n"
    }

    // MARK: - Sections

    private static func summary(for entry: NetworkEntry) -> String {
        var line = "\(entry.methodLabel) \(entry.request.url) → \(entry.statusLabel)"
        if let duration = entry.duration {
            line += " (\(DonkFormat.duration(duration)))"
        }
        var details = ["Kind: \(entry.kind.rawValue)", "State: \(entry.state.rawValue)"]
        switch entry.origin {
        case .network:
            break
        case let .mocked(rule):
            details.append("Mocked by rule \"\(rule)\"")
        case let .rewritten(rule):
            details.append("Rewritten by rule \"\(rule)\"")
        case let .breakpoint(edited):
            details.append(edited ? "Edited at breakpoint" : "Paused at breakpoint")
        }
        if let web = entry.web {
            details.append("WebView \(web.initiator.rawValue), capture \(web.captureLevel.rawValue)")
            if let page = web.pageURL { details.append("Page: \(page)") }
        }
        return line + "\n" + details.joined(separator: " · ")
    }

    private static func requestSection(for entry: NetworkEntry) -> String {
        let request = entry.request
        var lines = ["REQUEST", "\(request.method.uppercased()) \(request.url)"]
        lines.append(contentsOf: request.headers.map { "\($0.name): \($0.value)" })
        var text = lines.joined(separator: "\n")
        if let body = render(request.body) {
            text += "\n\n" + body
        }
        return text
    }

    private static func responseSection(for entry: NetworkEntry) -> String? {
        guard let response = entry.response else { return nil }
        let phrase = response.reasonPhrase
        var lines = ["RESPONSE", phrase.isEmpty ? "\(response.statusCode)" : "\(response.statusCode) \(phrase)"]
        lines.append(contentsOf: response.headers.map { "\($0.name): \($0.value)" })
        var text = lines.joined(separator: "\n")
        if let body = render(response.body) {
            text += "\n\n" + body
        }
        return text
    }

    private static func grpcSection(for grpc: GRPCDetails) -> String {
        var lines = ["GRPC", "\(grpc.service)/\(grpc.method) (\(grpc.callType.label))"]
        if let code = grpc.statusCode {
            var status = "Status: \(code) \(GRPCDetails.statusName(for: code))"
            if let message = grpc.statusMessage { status += " — \(message)" }
            lines.append(status)
        }
        if let timeout = grpc.timeout {
            lines.append("Timeout: \(DonkFormat.seconds(timeout)) s")
        }
        if !grpc.trailers.isEmpty {
            lines.append("Trailers:")
            lines.append(contentsOf: grpc.trailers.map { "  \($0.name): \($0.value)" })
        }
        let total = grpc.sentMessageCount + grpc.receivedMessageCount
        var header = "Messages (\(max(total, grpc.messages.count)))"
        if grpc.droppedMessageCount > 0 {
            header += ", showing last \(grpc.messages.count)"
        }
        lines.append("")
        lines.append(header)
        for message in grpc.messages {
            let arrow = message.direction == .sent ? "→" : "←"
            lines.append("[\(DonkFormat.timeOfDay(message.timestamp))] \(arrow) \(message.typeName) (\(DonkFormat.bytes(message.size)))")
            if let json = message.json {
                lines.append(JSONFormatting.pretty(json) ?? json)
            } else if let textFormat = message.textFormat {
                lines.append(textFormat)
            } else if let raw = message.raw {
                lines.append("<binary, \(DonkFormat.bytes(raw.count))>")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func timingSection(for entry: NetworkEntry) -> String {
        let timing = entry.timing
        var lines = ["TIMING", "Started: \(DonkFormat.iso8601(timing.startedAt))"]
        if let responseStarted = timing.responseStartedAt {
            lines.append("Response started: +\(DonkFormat.duration(max(0, responseStarted.timeIntervalSince(timing.startedAt))))")
        }
        if let duration = timing.duration {
            lines.append("Duration: \(DonkFormat.duration(duration))")
        }
        if let metrics = timing.transactions.last {
            if let networkProtocol = metrics.networkProtocol { lines.append("Protocol: \(networkProtocol)") }
            if let address = metrics.remoteAddress { lines.append("Remote address: \(address)") }
            if let tls = metrics.tlsProtocol { lines.append("TLS: \(tls)") }
            if metrics.isReusedConnection { lines.append("Reused connection") }
        }
        lines.append("Request size: \(DonkFormat.bytes(entry.requestSize))")
        lines.append("Response size: \(DonkFormat.bytes(entry.responseSize))")
        return lines.joined(separator: "\n")
    }

    private static func render(_ body: BodyData?) -> String? {
        guard let body, !body.data.isEmpty else { return nil }
        var text: String
        if let pretty = body.prettyJSON {
            text = pretty
        } else if body.isImage {
            text = "<image\(body.mimeType.map { " " + $0 } ?? ""), \(DonkFormat.bytes(body.originalSize))>"
        } else if let string = body.text {
            text = string
        } else {
            text = "<binary, \(DonkFormat.bytes(body.originalSize))>"
        }
        if body.isTruncated {
            text += "\n… truncated (\(DonkFormat.bytes(body.data.count)) of \(DonkFormat.bytes(body.originalSize)))"
        }
        return text
    }
}
