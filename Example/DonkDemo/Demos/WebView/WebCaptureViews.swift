import Donk
import DonkUI
import SwiftUI
import WebKit

struct WebViewHost: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView {
        webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// MARK: - Presentation helpers

extension NetworkEntry {
    var webInitiatorLabel: String {
        switch web?.initiator {
        case .document: return "document"
        case .fetch: return "fetch"
        case .xhr: return "xhr"
        case .beacon: return "beacon"
        case .websocket: return "websocket"
        case .eventSource: return "sse"
        case .resource: return "resource"
        case nil: return kind.rawValue
        }
    }

    var webInitiatorIcon: String {
        switch web?.initiator {
        case .document: return "doc.richtext"
        case .fetch: return "arrow.down.circle"
        case .xhr: return "arrow.left.arrow.right.circle"
        case .beacon: return "dot.radiowaves.right"
        case .websocket: return "bolt.horizontal.circle"
        case .eventSource: return "antenna.radiowaves.left.and.right"
        case .resource: return "photo.on.rectangle"
        case nil: return "globe"
        }
    }

    var captureLevelTone: DonkTone {
        switch web?.captureLevel {
        case .full: return .success
        case .metadata: return .info
        case .observed, nil: return .neutral
        }
    }

    var statusTone: DonkTone {
        switch statusCategory {
        case .pending: return .neutral
        case .success: return .success
        case .redirect: return .info
        case .clientError: return .warning
        case .serverError, .failure: return .error
        }
    }

    var displayPath: String {
        let path = path
        return path.isEmpty ? "/" : path
    }
}

// MARK: - Row

struct WebEntryRow: View {
    let entry: NetworkEntry
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            HStack(spacing: 6) {
                MethodBadge(entry.methodLabel)
                TonePill(entry.webInitiatorLabel, tone: .web, icon: compact ? nil : entry.webInitiatorIcon)
                if !compact, let level = entry.web?.captureLevel {
                    TonePill(level.rawValue, tone: entry.captureLevelTone)
                }
                Spacer(minLength: 4)
                StatusPill(entry.statusLabel, tone: entry.statusTone, isLive: entry.state.isInFlight)
            }
            Text(DonkTextBreaking.breakable(compact ? (entry.host ?? "") + entry.displayPath : entry.displayPath))
                .font(DonkFont.code)
                .foregroundColor(DonkColor.textPrimary)
                .lineLimit(compact ? 1 : 2)
            if !compact {
                Text(subtitle)
                    .font(DonkFont.caption)
                    .foregroundColor(DonkColor.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, compact ? 2 : 4)
    }

    private var subtitle: String {
        var parts = [entry.host ?? entry.request.url]
        if let duration = entry.duration { parts.append(DonkFormat.duration(duration)) }
        if entry.responseSize > 0 { parts.append(DonkFormat.bytes(entry.responseSize)) }
        if let id = entry.web?.webViewID { parts.append(id) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Captured list

struct WebCapturedListView: View {
    @ObservedObject var model: WebViewDemoModel

    var body: some View {
        List {
            Section {
                Toggle(isOn: $model.isCapturing) {
                    DonkLabelRow(icon: "record.circle", tone: .error, title: "Capture", subtitle: "DonkWebViewCapture.start() / stop()")
                }
                Toggle(isOn: $model.isInspectable) {
                    DonkLabelRow(icon: "safari", tone: .info, title: "Inspectable", subtitle: "Safari ▸ Develop on iOS 16.4+")
                }
            } header: {
                DonkSectionHeader("Capture")
            }

            Section {
                SelfCheckCard(model: model)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section {
                RobustnessCheckCard(check: model.robustness)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section {
                if model.entries.isEmpty {
                    EmptyStateView(
                        icon: "safari",
                        title: "No WebView traffic yet",
                        message: "Tap a scenario in the playground or open a site.",
                        tone: .web
                    )
                    .frame(minHeight: 220)
                } else {
                    ForEach(model.entries) { entry in
                        NavigationLink {
                            WebEntryDetailView(entry: entry)
                        } label: {
                            WebEntryRow(entry: entry)
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
                }
            } header: {
                DonkSectionHeader("Captured", icon: "safari", count: model.entries.count) {
                    if !model.entries.isEmpty {
                        Button("Clear") { model.clear() }
                            .font(DonkFont.captionEmphasized)
                    }
                }
            }
        }
        .donkListStyle()
    }
}

// MARK: - Self check

struct SelfCheckCard: View {
    @ObservedObject var model: WebViewDemoModel

    var body: some View {
        DonkCard(title: "Self-test", icon: "checkmark.seal", tone: .success) {
            Text("Runs every playground scenario and checks the captured entries, including fetch and XHR bodies.")
                .font(DonkFont.footnote)
                .foregroundColor(DonkColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if !model.checks.isEmpty {
                VStack(spacing: 0) {
                    ForEach(model.checks) { check in
                        HStack(alignment: .top, spacing: 10) {
                            icon(for: check.status)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(check.title)
                                    .font(DonkFont.callout.weight(.semibold))
                                    .foregroundColor(DonkColor.textPrimary)
                                Text(check.detail)
                                    .font(DonkFont.caption)
                                    .foregroundColor(DonkColor.textSecondary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 6)
                        if check.id != model.checks.last?.id {
                            Divider()
                        }
                    }
                }
            }
        } accessory: {
            Button {
                model.verify()
            } label: {
                if model.isVerifying {
                    ProgressView()
                } else {
                    Text(model.checks.isEmpty ? "Run" : "Run again")
                        .font(DonkFont.label)
                }
            }
            .disabled(model.isVerifying)
        }
    }

    @ViewBuilder
    private func icon(for status: SelfCheck.Status) -> some View {
        switch status {
        case .pending:
            ProgressView().scaleEffect(0.7)
        case .passed:
            Image(systemName: "checkmark.circle.fill").foregroundColor(DonkColor.success)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundColor(DonkColor.error)
        }
    }
}

// MARK: - Live strip

struct WebLiveStrip: View {
    let entries: [NetworkEntry]
    let total: Int
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    LiveDot(tone: .web, size: 7, isAnimating: entries.contains { $0.state.isInFlight })
                    Text("Captured")
                        .font(DonkFont.label)
                        .foregroundColor(DonkColor.textPrimary)
                    CountBadge(total, tone: .web)
                    Spacer()
                    Image(systemName: "chevron.up")
                        .font(DonkFont.captionEmphasized)
                        .foregroundColor(DonkColor.textTertiary)
                }
                if entries.isEmpty {
                    Text("Requests made by the page appear here")
                        .font(DonkFont.caption)
                        .foregroundColor(DonkColor.textSecondary)
                } else {
                    ForEach(entries) { entry in
                        WebEntryRow(entry: entry, compact: true)
                    }
                }
            }
            .padding(DonkSpacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .donkCardBackground()
        }
        .buttonStyle(.donkPressable)
    }
}

// MARK: - Detail

struct WebEntryDetailView: View {
    let entry: NetworkEntry
    @State private var section: DetailSection = .request

    private enum DetailSection: String, CaseIterable {
        case request = "Request"
        case response = "Response"
        case timing = "Timing"
    }

    var body: some View {
        DonkScrollContainer {
            overview
            SegmentedTabs(selection: $section, tabs: DetailSection.allCases, title: { $0.rawValue })
            switch section {
            case .request:
                HeaderListView(entry.request.headers.map { ($0.name, $0.value) }, title: "Request Headers")
                bodyCard(title: "Request Body", body: entry.request.body, fileName: "request")
            case .response:
                if let error = entry.error {
                    DonkCard(title: "Error", icon: "exclamationmark.triangle.fill", tone: .error) {
                        KeyValueRow(key: "Domain", value: error.domain, monospacedValue: true)
                        KeyValueRow(key: "Code", value: String(error.code), monospacedValue: true)
                        KeyValueRow(key: "Message", value: error.message, layout: .vertical)
                    }
                }
                if let response = entry.response {
                    HeaderListView(response.headers.map { ($0.name, $0.value) }, title: "Response Headers", emptyText: emptyHeadersText)
                    bodyCard(title: "Response Body", body: response.body, fileName: "response")
                } else if entry.error == nil {
                    EmptyStateView(icon: "tray", title: "No response", message: noResponseText, tone: .neutral)
                        .frame(minHeight: 200)
                }
            case .timing:
                timing
            }
        }
        .donkNavigationTitle(entry.webInitiatorLabel.capitalized)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                CopyButton(label: "cURL") { CurlExporter.command(for: entry.request) }
            }
        }
    }

    private var overview: some View {
        DonkCard(title: entry.request.method, icon: entry.webInitiatorIcon, tone: .web) {
            VStack(spacing: 0) {
                KeyValueRow(key: "URL", value: entry.request.url, monospacedValue: true)
                Divider()
                KeyValueRow(key: "Status", value: statusText, valueTone: entry.statusTone)
                Divider()
                KeyValueRow(key: "State", value: entry.state.rawValue)
                Divider()
                KeyValueRow(key: "Initiator", value: entry.web?.initiator.rawValue ?? "—")
                Divider()
                KeyValueRow(key: "Capture", value: captureText, valueTone: entry.captureLevelTone)
                Divider()
                KeyValueRow(key: "Web view", value: entry.web?.webViewID ?? "—", monospacedValue: true)
                if let page = entry.web?.pageURL {
                    Divider()
                    KeyValueRow(key: "Page", value: page, monospacedValue: true)
                }
                Divider()
                KeyValueRow(key: "Duration", value: entry.duration.map(DonkFormat.duration) ?? "—")
            }
        } accessory: {
            CopyButton(text: entry.request.url, label: "URL")
        }
    }

    @ViewBuilder
    private func bodyCard(title: String, body: BodyData?, fileName: String) -> some View {
        if let body {
            DonkCard(title: title, icon: "doc.text", tone: .accent) {
                HStack(spacing: 6) {
                    TonePill(DonkFormat.bytes(body.originalSize), tone: .neutral)
                    if let type = body.contentType {
                        TonePill(type, tone: .info)
                    }
                    if body.isTruncated {
                        TonePill(body.data.isEmpty ? "not captured" : "truncated", tone: .warning)
                    }
                }
                if body.data.isEmpty {
                    Text("The body is not available at this capture level.")
                        .font(DonkFont.footnote)
                        .foregroundColor(DonkColor.textSecondary)
                } else if body.data.count <= 200 * 1024 {
                    JSONBodyView(data: body.data, layout: .embedded, fileName: fileName)
                } else {
                    CodeView(text: body.text ?? "Binary body", language: body.isJSON ? .json : .plain)
                }
            } accessory: {
                if let text = body.text, !body.data.isEmpty {
                    CopyButton(text: text, label: "Body")
                }
            }
        } else {
            DonkCard(title: title, icon: "doc.text", tone: .neutral) {
                Text("No body")
                    .font(DonkFont.footnote)
                    .foregroundColor(DonkColor.textSecondary)
            }
        }
    }

    private var timing: some View {
        DonkCard(title: "Timing", icon: "clock", tone: .info) {
            VStack(spacing: 0) {
                KeyValueRow(key: "Started", value: DonkFormat.time(entry.timing.startedAt), monospacedValue: true)
                Divider()
                KeyValueRow(key: "Response", value: entry.timing.responseStartedAt.map(DonkFormat.time) ?? "—", monospacedValue: true)
                Divider()
                KeyValueRow(key: "Ended", value: entry.timing.endedAt.map(DonkFormat.time) ?? "—", monospacedValue: true)
                if let metrics = entry.timing.transactions.first {
                    if let value = metrics.networkProtocol {
                        Divider()
                        KeyValueRow(key: "Protocol", value: value, monospacedValue: true)
                    }
                    if metrics.requestBodyBytes > 0 {
                        Divider()
                        KeyValueRow(key: "Sent", value: DonkFormat.bytes(metrics.requestBodyBytes))
                    }
                    if metrics.responseBodyBytes > 0 {
                        Divider()
                        KeyValueRow(key: "Received", value: DonkFormat.bytes(metrics.responseBodyBytes))
                    }
                    if let start = metrics.requestStart, let end = metrics.responseStart {
                        Divider()
                        KeyValueRow(key: "Waiting", value: DonkFormat.duration(end.timeIntervalSince(start)))
                    }
                }
            }
        }
    }

    private var statusText: String {
        guard let code = entry.response?.statusCode, code > 0 else { return entry.statusLabel }
        let phrase = ResponseSnapshot.reasonPhrase(for: code)
        return phrase.isEmpty ? String(code) : "\(code) \(phrase)"
    }

    private var captureText: String {
        switch entry.web?.captureLevel {
        case .full: return "full (headers + bodies)"
        case .metadata: return "metadata (status + headers)"
        case .observed: return "observed (timing only)"
        case nil: return "—"
        }
    }

    private var emptyHeadersText: String {
        entry.web?.captureLevel == .observed ? "Not visible to the page" : "No headers"
    }

    private var noResponseText: String {
        switch entry.web?.initiator {
        case .beacon: return "Beacon responses are never exposed to the page."
        case .resource, .document: return "Only timing is observable for this entry."
        default: return entry.state.isInFlight ? "Waiting for the response." : "The page did not receive a response."
        }
    }
}
