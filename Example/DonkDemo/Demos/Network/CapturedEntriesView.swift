import Donk
import DonkUI
import SwiftUI
import UIKit

struct CapturedEntriesView: View {
    @ObservedObject var model: NetworkDemoModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        DonkNavigationContainer {
            Group {
                if filtered.isEmpty {
                    EmptyStateView(
                        icon: "network.slash",
                        title: query.isEmpty ? "No requests yet" : "No matches",
                        message: query.isEmpty ? "Requests appear here as they happen." : "Nothing matches “\(query)”."
                    )
                    .donkScreenBackground()
                } else {
                    List(filtered) { entry in
                        NavigationLink {
                            CapturedEntryDetailView(entryID: entry.id, model: model)
                        } label: {
                            CapturedEntryRow(entry: entry)
                        }
                        .contextMenu {
                            Button {
                                DonkPasteboard.copy(entry.request.url, label: "URL")
                            } label: {
                                Label("Copy URL", systemImage: "link")
                            }
                            Button {
                                DonkPasteboard.copy(CurlExporter.command(for: entry.request), label: "cURL")
                            } label: {
                                Label("Copy cURL", systemImage: "terminal")
                            }
                        }
                    }
                    .donkListStyle()
                }
            }
            .searchable(text: $query, prompt: "URL, status, header, body")
            .donkNavigationTitle("Captured · \(model.count)")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear", role: .destructive) { model.clear() }
                        .disabled(model.count == 0)
                }
            }
        }
        .donkTheme()
    }

    private var filtered: [NetworkEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return model.entries }
        return model.entries.filter { NetworkSearch.matches($0, query: trimmed) }
    }
}

struct CapturedEntryRow: View {
    let entry: NetworkEntry

    var body: some View {
        HStack(alignment: .top, spacing: DonkSpacing.m) {
            MethodBadge(entry.methodLabel)
                .frame(minWidth: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(DonkTextBreaking.breakable(entry.path))
                    .font(DonkFont.code)
                    .foregroundColor(DonkColor.textPrimary)
                    .lineLimit(2)
                Text(metadata)
                    .font(DonkFont.caption)
                    .foregroundColor(DonkColor.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let pill = originPill {
                    pill
                }
            }
            Spacer(minLength: DonkSpacing.s)
            StatusPill(statusText, tone: CapturedEntryRow.tone(for: entry), isLive: entry.state.isInFlight)
        }
        .padding(.vertical, DonkSpacing.xxs)
        .accessibilityElement(children: .combine)
    }

    private var metadata: String {
        var parts = [entry.host ?? ""]
        if let duration = entry.duration {
            parts.append(DonkFormat.duration(duration))
        }
        if entry.responseSize > 0 {
            parts.append(DonkFormat.bytes(entry.responseSize))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var statusText: String {
        switch entry.state {
        case .paused: return "PAUSED"
        case .streaming: return entry.response.map { "\($0.statusCode)" } ?? "LIVE"
        case .cancelled: return "CANCELLED"
        default: return entry.statusLabel
        }
    }

    private var originPill: TonePill? {
        switch entry.origin {
        case .network: return nil
        case .mocked: return TonePill("Mocked", tone: .warning, icon: "wand.and.stars")
        case .rewritten: return TonePill("Rewritten", tone: .warning, icon: "pencil")
        case let .breakpoint(edited): return TonePill(edited ? "Edited at breakpoint" : "Breakpoint", tone: .warning, icon: "pause.circle")
        }
    }

    static func tone(for entry: NetworkEntry) -> DonkTone {
        if entry.state == .paused { return .warning }
        if entry.state == .streaming { return .web }
        switch entry.statusCategory {
        case .pending: return .neutral
        case .success: return .success
        case .redirect: return .info
        case .clientError: return .warning
        case .serverError, .failure: return .error
        }
    }
}

struct CapturedEntryDetailView: View {
    let entryID: UUID
    @ObservedObject var model: NetworkDemoModel

    var body: some View {
        Group {
            if let entry = model.entries.first(where: { $0.id == entryID }) ?? NetworkStore.shared.entry(entryID) {
                content(entry)
            } else {
                EmptyStateView(icon: "trash", title: "Entry removed", message: "It was cleared from the store.")
                    .donkScreenBackground()
            }
        }
        .donkNavigationTitle("Request")
    }

    private func content(_ entry: NetworkEntry) -> some View {
        DonkScrollContainer {
            DonkCard(title: "Overview", icon: "info.circle", tone: CapturedEntryRow.tone(for: entry)) {
                VStack(spacing: 0) {
                    KeyValueRow(key: "URL", value: entry.request.url, monospacedValue: true)
                    Divider()
                    KeyValueRow(key: "Method", value: entry.request.method)
                    Divider()
                    KeyValueRow(key: "Status", value: statusLine(entry), valueTone: CapturedEntryRow.tone(for: entry))
                    Divider()
                    KeyValueRow(key: "State", value: entry.state.rawValue.capitalized)
                    if let duration = entry.duration {
                        Divider()
                        KeyValueRow(key: "Duration", value: DonkFormat.duration(duration))
                    }
                    Divider()
                    KeyValueRow(key: "Sizes", value: "↑ \(DonkFormat.bytes(entry.requestSize))  ↓ \(DonkFormat.bytes(entry.responseSize))")
                    if let metrics = entry.timing.transactions.last {
                        if let networkProtocol = metrics.networkProtocol {
                            Divider()
                            KeyValueRow(key: "Protocol", value: networkProtocol)
                        }
                        if let address = metrics.remoteAddress {
                            Divider()
                            KeyValueRow(key: "Remote", value: address, monospacedValue: true)
                        }
                        if let tls = metrics.tlsProtocol {
                            Divider()
                            KeyValueRow(key: "TLS", value: [tls, metrics.tlsCipherSuite].compactMap { $0 }.joined(separator: " · "))
                        }
                    }
                    if let error = entry.error {
                        Divider()
                        KeyValueRow(key: "Error", value: "\(error.domain) \(error.code)\n\(error.message)", valueTone: .error)
                    }
                }
            } accessory: {
                CopyButton(label: "cURL", title: "cURL") { CurlExporter.command(for: entry.request) }
            }
            HeaderListView(entry.request.headers.map { ($0.name, $0.value) }, title: "Request headers")
            bodyCard(title: "Request body", icon: "arrow.up.circle", body: entry.request.body)
            if let response = entry.response {
                HeaderListView(response.headers.map { ($0.name, $0.value) }, title: "Response headers")
                bodyCard(title: "Response body", icon: "arrow.down.circle", body: response.body)
            }
        }
    }

    @ViewBuilder
    private func bodyCard(title: String, icon: String, body: BodyData?) -> some View {
        if let body, !body.data.isEmpty {
            DonkCard(title: title, icon: icon, tone: .info) {
                if body.isImage, let image = UIImage(data: body.data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 240)
                        .clipShape(RoundedRectangle(cornerRadius: DonkRadius.small, style: .continuous))
                } else if let text = body.prettyJSON ?? body.text {
                    CodeView(text: String(text.prefix(60_000)), language: CodeLanguage.detect(contentType: body.contentType, text: text))
                } else {
                    Text("Binary · \(DonkFormat.bytes(body.originalSize))")
                        .font(DonkFont.callout)
                        .foregroundColor(DonkColor.textSecondary)
                }
                if body.isTruncated {
                    TonePill("Truncated · \(DonkFormat.bytes(body.originalSize)) total", tone: .neutral, icon: "scissors")
                }
            } accessory: {
                if let text = body.text {
                    CopyButton(text: text, label: title)
                }
            }
        }
    }

    private func statusLine(_ entry: NetworkEntry) -> String {
        guard let response = entry.response else { return entry.statusLabel }
        let reason = response.reasonPhrase
        return reason.isEmpty ? "\(response.statusCode)" : "\(response.statusCode) \(reason)"
    }
}
