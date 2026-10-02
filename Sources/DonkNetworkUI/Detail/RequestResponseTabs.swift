import DonkCore
import DonkUI
import SwiftUI

// MARK: - Request

struct RequestTab: View {
    let entry: NetworkEntry
    var headerMask: HeaderMask?

    var body: some View {
        VStack(alignment: .leading, spacing: DonkSpacing.l) {
            if entry.web?.captureLevel == .observed {
                NoticeBanner(icon: "eye", text: "Observed through resource timing — request headers and body are not available.", tone: .neutral)
            }
            let query = entry.request.queryItems
            if !query.isEmpty {
                HeaderListView(
                    query.map { DonkKeyValue(key: $0.name, value: $0.value ?? "") },
                    title: "Query Parameters",
                    emptyText: "No query parameters"
                )
            }
            if let grpc = entry.grpc {
                HeaderListView(grpc.requestMetadata.map { ($0.name, $0.value) }, title: "Metadata", emptyText: "No metadata", masksKey: masksKey)
                BodyCard(
                    bodyData: entry.request.body,
                    title: grpc.callType == .unary || grpc.callType == .serverStreaming ? "Message" : "First Message",
                    note: grpc.sentMessageCount > 1 ? "\(grpc.sentMessageCount) messages sent · see Messages for the full stream" : nil,
                    fileName: EntryFormat.fileName(for: entry, part: "request", body: entry.request.body)
                )
            } else {
                HeaderListView(entry.request.headers.map { ($0.name, $0.value) }, title: "Headers", masksKey: masksKey)
                BodyCard(
                    bodyData: entry.request.body,
                    title: "Body",
                    note: nil,
                    fileName: EntryFormat.fileName(for: entry, part: "request", body: entry.request.body)
                )
            }
        }
        .padding(.horizontal, DonkSpacing.screen)
        .padding(.top, DonkSpacing.s)
    }

    private var masksKey: ((String) -> Bool)? {
        headerMask.map { mask in { mask.masks($0) } }
    }
}

// MARK: - Response

struct ResponseTab: View {
    let entry: NetworkEntry
    var headerMask: HeaderMask?

    var body: some View {
        VStack(alignment: .leading, spacing: DonkSpacing.l) {
            if let response = entry.response {
                statusCard(response)
                if let grpc = entry.grpc {
                    HeaderListView(grpc.responseHeaders.map { ($0.name, $0.value) }, title: "Headers", masksKey: masksKey)
                    BodyCard(
                        bodyData: response.body,
                        title: grpc.callType == .unary || grpc.callType == .clientStreaming ? "Message" : "Last Message",
                        note: grpc.receivedMessageCount > 1 ? "\(grpc.receivedMessageCount) messages received · see Messages for the full stream" : nil,
                        fileName: EntryFormat.fileName(for: entry, part: "response", body: response.body)
                    )
                    if grpc.statusCode != nil || !grpc.trailers.isEmpty {
                        HeaderListView(grpc.trailers.map { ($0.name, $0.value) }, title: "Trailers", emptyText: "No trailers", masksKey: masksKey)
                    }
                } else {
                    if entry.web?.captureLevel == .metadata {
                        NoticeBanner(icon: "list.bullet.rectangle", text: "Captured from navigation metadata — the response body is not accessible to Donk.", tone: .info)
                    }
                    HeaderListView(response.headers.map { ($0.name, $0.value) }, title: "Headers", masksKey: masksKey)
                    BodyCard(
                        bodyData: response.body,
                        title: "Body",
                        note: entry.state == .streaming ? "Streaming — the body grows as data arrives" : nil,
                        fileName: EntryFormat.fileName(for: entry, part: "response", body: response.body)
                    )
                }
            } else if entry.state.isInFlight {
                waitingCard
            } else if let error = entry.error {
                ErrorCard(error: error, state: entry.state)
                noResponse
            } else if let grpc = entry.grpc, grpc.statusCode != nil {
                GRPCSummaryCard(grpc: grpc, state: entry.state)
                HeaderListView(grpc.trailers.map { ($0.name, $0.value) }, title: "Trailers", emptyText: "No trailers", masksKey: masksKey)
            } else {
                noResponse
            }
        }
        .padding(.horizontal, DonkSpacing.screen)
        .padding(.top, DonkSpacing.s)
    }

    private var masksKey: ((String) -> Bool)? {
        headerMask.map { mask in { mask.masks($0) } }
    }

    private func statusCard(_ response: ResponseSnapshot) -> some View {
        let tone = EntryStyle.statusTone(entry)
        return DonkCard {
            HStack(alignment: .center, spacing: DonkSpacing.m) {
                DonkIconBadge(statusIcon, tone: tone, size: 40, filled: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(primaryStatus(response))
                        .font(DonkFont.rounded(.title3, weight: .bold))
                        .foregroundColor(DonkColor.textPrimary)
                    Text(secondaryStatus(response))
                        .font(.footnote)
                        .foregroundColor(DonkColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if entry.state == .streaming {
                    StatusPill("LIVE", tone: entry.kind == .grpc ? .grpc : .info, isLive: true)
                }
            }
        }
    }

    private var statusIcon: String {
        switch entry.statusCategory {
        case .success: return "checkmark"
        case .redirect: return "arrow.uturn.right"
        case .clientError: return "exclamationmark"
        case .serverError, .failure: return "xmark"
        case .pending: return "ellipsis"
        }
    }

    private func primaryStatus(_ response: ResponseSnapshot) -> String {
        if entry.kind == .grpc {
            return entry.grpc?.statusName ?? (entry.state == .streaming ? "Streaming" : "Headers received")
        }
        let phrase = ResponseSnapshot.reasonPhrase(for: response.statusCode)
        return phrase.isEmpty ? "\(response.statusCode)" : "\(response.statusCode) \(phrase)"
    }

    private func secondaryStatus(_ response: ResponseSnapshot) -> String {
        if let grpc = entry.grpc {
            if let message = grpc.statusMessage { return message }
            if let code = grpc.statusCode { return "gRPC status \(code) · HTTP \(response.statusCode)" }
            return "HTTP \(response.statusCode) · waiting for trailers"
        }
        var parts: [String] = []
        if let type = response.header("Content-Type") { parts.append(type) }
        if let size = response.body?.originalSize, size > 0 { parts.append(DonkFormat.bytes(size)) }
        return parts.isEmpty ? "No content" : parts.joined(separator: " · ")
    }

    private var waitingCard: some View {
        DonkCard {
            HStack(spacing: DonkSpacing.m) {
                LiveDot(tone: entry.state == .paused ? .warning : .info, size: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.state == .paused ? "Paused at a breakpoint" : "Waiting for response…")
                        .font(.subheadline.weight(.semibold))
                    ElapsedMetric(since: entry.timing.startedAt)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var noResponse: some View {
        DonkCard {
            HStack(spacing: DonkSpacing.m) {
                Image(systemName: "tray")
                    .font(.title3)
                    .foregroundColor(DonkColor.textTertiary)
                Text(entry.web?.captureLevel == .observed ? "Observed resources carry no response details." : "No response was received.")
                    .font(.subheadline)
                    .foregroundColor(DonkColor.textSecondary)
                Spacer(minLength: 0)
            }
        }
    }
}
