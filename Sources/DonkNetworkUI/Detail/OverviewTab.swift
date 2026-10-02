import DonkCore
import DonkUI
import SwiftUI

struct OverviewTab: View {
    let entry: NetworkEntry
    var headerMask: HeaderMask?
    let editRule: (NetworkRule) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DonkSpacing.l) {
            if let error = entry.error {
                ErrorCard(error: error, state: entry.state)
            } else if entry.state == .cancelled {
                ErrorCard(error: NetworkErrorInfo(domain: NSURLErrorDomain, code: NSURLErrorCancelled, message: "The request was cancelled."), state: entry.state)
            }
            if let grpc = entry.grpc {
                GRPCSummaryCard(grpc: grpc, state: entry.state)
            }
            if entry.origin.isModified {
                RuleOriginCard(origin: entry.origin, editRule: editRule)
            }
            if let web = entry.web {
                WebViewCard(details: web)
            }
            factsCard
            if let grpc = entry.grpc, !grpc.trailers.isEmpty {
                HeaderListView(grpc.trailers.map { ($0.name, $0.value) }, title: "Trailers", masksKey: headerMask.map { mask in { mask.masks($0) } })
            }
        }
        .padding(.horizontal, DonkSpacing.screen)
        .padding(.top, DonkSpacing.s)
    }

    // MARK: - Facts

    private var factsCard: some View {
        DonkCard(title: "Summary", icon: "list.bullet.rectangle", tone: .accent) {
            VStack(spacing: 0) {
                ForEach(Array(facts.enumerated()), id: \.offset) { index, fact in
                    KeyValueRow(key: fact.key, value: fact.value, monospacedValue: fact.mono, valueTone: fact.tone)
                    if index < facts.count - 1 {
                        Divider()
                    }
                }
            }
        } accessory: {
            CopyButton(label: "Summary") {
                facts.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
            }
        }
    }

    private struct Fact {
        var key: String
        var value: String
        var mono = false
        var tone: DonkTone?
    }

    private var facts: [Fact] {
        var result: [Fact] = []
        result.append(Fact(key: "Method", value: entry.kind == .grpc ? "\(entry.methodLabel) · POST" : entry.request.method.uppercased(), mono: true))
        result.append(Fact(key: "Status", value: EntryFormat.status(entry), tone: entry.statusCategory == .pending ? nil : EntryStyle.statusTone(entry)))
        result.append(Fact(key: "State", value: EntryStyle.stateTitle(entry.state)))
        if let duration = entry.duration {
            result.append(Fact(key: "Duration", value: DonkFormat.duration(duration), mono: true))
        }
        if let responseStart = entry.timing.responseStartedAt {
            result.append(Fact(key: "Time to first byte", value: DonkFormat.duration(max(0, responseStart.timeIntervalSince(entry.timing.startedAt))), mono: true))
        }
        result.append(Fact(key: "Request size", value: sizeText(entry.requestSize, body: entry.request.body), mono: true))
        result.append(Fact(key: "Response size", value: sizeText(entry.responseSize, body: entry.response?.body), mono: true))
        result.append(Fact(key: "Started", value: EntryFormat.timestamp(entry.timing.startedAt), mono: true))
        if let host = entry.host {
            result.append(Fact(key: "Host", value: host, mono: true))
        }
        if let transaction = entry.timing.transactions.last {
            if let name = EntryStyle.protocolName(transaction.networkProtocol) {
                result.append(Fact(key: "Protocol", value: name, mono: true))
            }
            if let address = transaction.remoteAddress {
                result.append(Fact(key: "Remote address", value: address, mono: true))
            }
            if let tls = transaction.tlsProtocol {
                let cipher = transaction.tlsCipherSuite.map { " · \($0)" } ?? ""
                result.append(Fact(key: "TLS", value: tls + cipher, mono: true))
            }
            result.append(Fact(key: "Connection", value: connectionText(transaction)))
            result.append(Fact(key: "Cached", value: isCached(transaction) ? "Yes · local cache" : "No"))
            if entry.timing.transactions.count > 1 {
                result.append(Fact(key: "Redirects", value: "\(entry.timing.transactions.count - 1)"))
            }
        } else if entry.kind == .grpc {
            result.append(Fact(key: "Protocol", value: "HTTP/2 · gRPC", mono: true))
        }
        if let type = entry.response?.header("Content-Type") ?? entry.request.header("Content-Type") {
            result.append(Fact(key: "Content type", value: type, mono: true))
        }
        return result
    }

    private func sizeText(_ size: Int, body: BodyData?) -> String {
        guard size > 0 else { return "0 B" }
        var text = DonkFormat.bytes(size)
        if let body, body.isTruncated {
            text += " (captured \(DonkFormat.bytes(body.data.count)))"
        }
        return text
    }

    private func connectionText(_ transaction: TransactionMetrics) -> String {
        var parts = [transaction.isReusedConnection ? "Reused" : "New"]
        if transaction.isProxyConnection { parts.append("via proxy") }
        return parts.joined(separator: " · ")
    }

    private func isCached(_ transaction: TransactionMetrics) -> Bool {
        transaction.networkProtocol == nil && transaction.remoteAddress == nil && transaction.connectStart == nil
            && transaction.responseEnd != nil
    }
}

// MARK: - Error card

struct ErrorCard: View {
    let error: NetworkErrorInfo
    let state: NetworkState

    var body: some View {
        DonkCard(title: title, icon: state == .cancelled ? "slash.circle.fill" : "xmark.octagon.fill", tone: state == .cancelled ? .neutral : .error) {
            Text(error.message)
                .font(.subheadline)
                .foregroundColor(DonkColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let hint {
                Text(hint)
                    .font(.footnote)
                    .foregroundColor(DonkColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                TonePill(text: error.domain, tone: .neutral)
                TonePill(text: "Code \(error.code)", tone: .neutral)
                if let name {
                    TonePill(text: name, tone: state == .cancelled ? .neutral : .error)
                }
            }
        } accessory: {
            CopyButton(text: "\(error.domain) \(error.code): \(error.message)", label: "Error")
        }
    }

    private var title: String {
        state == .cancelled ? "Cancelled" : "Request failed"
    }

    private var name: String? {
        guard error.domain == NSURLErrorDomain else { return nil }
        switch error.code {
        case NSURLErrorTimedOut: return "Timed out"
        case NSURLErrorCannotFindHost: return "DNS"
        case NSURLErrorNotConnectedToInternet: return "Offline"
        case NSURLErrorCancelled: return "Cancelled"
        case NSURLErrorCannotConnectToHost: return "Connection refused"
        case NSURLErrorNetworkConnectionLost: return "Connection lost"
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate:
            return "TLS"
        default: return nil
        }
    }

    private var hint: String? {
        guard error.domain == NSURLErrorDomain else { return nil }
        switch error.code {
        case NSURLErrorTimedOut: return "No response arrived before the request's timeout interval elapsed."
        case NSURLErrorCannotFindHost: return "The host name could not be resolved. Check the URL or the device's DNS."
        case NSURLErrorNotConnectedToInternet: return "The device appears to be offline."
        case NSURLErrorCancelled: return "The task was cancelled by the app, a breakpoint abort or a redirect."
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted:
            return "The TLS handshake failed. Certificate pinning or an untrusted certificate is a common cause."
        default: return nil
        }
    }
}

// MARK: - gRPC

struct GRPCSummaryCard: View {
    let grpc: GRPCDetails
    let state: NetworkState

    var body: some View {
        DonkCard(title: "gRPC", icon: "point.3.connected.trianglepath.dotted", tone: .grpc) {
            HStack(alignment: .center, spacing: DonkSpacing.m) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(statusTitle)
                        .font(DonkFont.rounded(.title3, weight: .bold))
                        .foregroundColor(statusTone.color)
                    if let message = grpc.statusMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundColor(DonkColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: DonkSpacing.s)
                if let code = grpc.statusCode {
                    Text("\(code)")
                        .font(DonkFont.metric)
                        .foregroundColor(statusTone.color.opacity(0.8))
                }
            }
            VStack(spacing: 0) {
                KeyValueRow(key: "Service", value: grpc.service, monospacedValue: true)
                Divider()
                KeyValueRow(key: "Method", value: grpc.method, monospacedValue: true)
                Divider()
                KeyValueRow(key: "Call type", value: grpc.callType.label.capitalized)
                Divider()
                KeyValueRow(key: "Messages", value: "↑ \(grpc.sentMessageCount) sent · ↓ \(grpc.receivedMessageCount) received")
                if grpc.droppedMessageCount > 0 {
                    Divider()
                    KeyValueRow(key: "Dropped", value: "\(grpc.droppedMessageCount) oldest messages (limit \(GRPCDetails.messageLimit))", valueTone: .warning)
                }
                if let timeout = grpc.timeout {
                    Divider()
                    KeyValueRow(key: "Deadline", value: DonkFormat.duration(timeout), monospacedValue: true)
                }
            }
        }
    }

    private var statusTitle: String {
        if let name = grpc.statusName { return name }
        switch state {
        case .streaming: return "Streaming…"
        case .pending, .paused: return "In flight…"
        case .cancelled: return "CANCELLED"
        case .failed: return "Transport error"
        case .completed: return "Finished"
        }
    }

    private var statusTone: DonkTone {
        if let code = grpc.statusCode { return .grpcStatus(code) }
        switch state {
        case .failed: return .error
        case .cancelled: return .neutral
        default: return .grpc
        }
    }
}

// MARK: - Rule origin

struct RuleOriginCard: View {
    let origin: NetworkOrigin
    let editRule: (NetworkRule) -> Void

    var body: some View {
        DonkCard(title: title, icon: badge?.icon ?? "wand.and.stars", tone: badge?.tone ?? .accent) {
            Text(explanation)
                .font(.footnote)
                .foregroundColor(DonkColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let name = EntryStyle.originRuleName(origin) {
                HStack(spacing: DonkSpacing.s) {
                    TonePill(text: name, tone: badge?.tone ?? .accent, icon: "slider.horizontal.3")
                    Spacer(minLength: 0)
                    if let rule = RuleStore.shared.rules.first(where: { $0.name == name }) {
                        Button("Edit Rule") { editRule(rule) }
                            .font(.footnote.weight(.semibold))
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    } else {
                        Text("Rule no longer exists")
                            .font(.caption)
                            .foregroundColor(DonkColor.textTertiary)
                    }
                }
            }
        }
    }

    private var badge: OriginBadge? { EntryStyle.originBadge(origin) }

    private var title: String {
        switch origin {
        case .network: return "Network"
        case .mocked: return "Mocked response"
        case .rewritten: return "Rewritten"
        case let .breakpoint(edited): return edited ? "Edited at a breakpoint" : "Passed a breakpoint"
        }
    }

    private var explanation: String {
        switch origin {
        case .network: return ""
        case .mocked: return "The response was produced locally by a Map Local rule. The server was never contacted."
        case .rewritten: return "A Rewrite rule changed the request and/or the response on the way through."
        case let .breakpoint(edited):
            return edited ? "The exchange was paused at a breakpoint and edited before it continued." : "The exchange was paused at a breakpoint and continued unchanged."
        }
    }
}

// MARK: - WebView

struct WebViewCard: View {
    let details: WebViewDetails

    var body: some View {
        DonkCard(title: "WebView", icon: "safari", tone: .web) {
            HStack(alignment: .top, spacing: DonkSpacing.m) {
                DonkIconBadge(levelIcon, tone: levelTone, size: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(levelTitle)
                        .font(.subheadline.weight(.semibold))
                    Text(levelExplanation)
                        .font(.footnote)
                        .foregroundColor(DonkColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(spacing: 0) {
                KeyValueRow(key: "Initiator", value: EntryStyle.initiatorTitle(details.initiator))
                if let page = details.pageURL {
                    Divider()
                    KeyValueRow(key: "Page", value: page, monospacedValue: true)
                }
                if let id = details.webViewID {
                    Divider()
                    KeyValueRow(key: "WebView", value: id, monospacedValue: true)
                }
            }
        }
    }

    private var levelTitle: String {
        switch details.captureLevel {
        case .full: return "Full capture"
        case .metadata: return "Metadata only"
        case .observed: return "Observed"
        }
    }

    private var levelIcon: String {
        switch details.captureLevel {
        case .full: return "checkmark.seal.fill"
        case .metadata: return "list.bullet.rectangle"
        case .observed: return "eye"
        }
    }

    private var levelTone: DonkTone {
        switch details.captureLevel {
        case .full: return .success
        case .metadata: return .info
        case .observed: return .neutral
        }
    }

    private var levelExplanation: String {
        switch details.captureLevel {
        case .full:
            return "Captured by the injected fetch/XMLHttpRequest hooks: request and response headers and bodies are available."
        case .metadata:
            return "Seen through WebKit navigation callbacks: URL, method, status and headers are known, but bodies are not accessible."
        case .observed:
            return "Reported by the page's resource timing. Only the URL, timing and transfer size are known — no headers or bodies."
        }
    }
}
