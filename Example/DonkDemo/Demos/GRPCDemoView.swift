import Donk
import DonkUI
import SwiftUI

struct GRPCDemoView: View {
    @StateObject private var model = GRPCDemoModel()
    @State private var editingExchange: PausedExchange?
    @State private var showsInspector = false

    var body: some View {
        List {
            serverSection
            if !model.pending.isEmpty {
                breakpointsSection
            }
            unarySection
            streamingSection
            chatSection
            if model.usesPublicServer {
                publicSection
            }
            rulesSection
            if !model.activity.isEmpty {
                activitySection
            }
            callsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("gRPC")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showsInspector = true
                } label: {
                    Label("Network inspector", systemImage: "list.bullet.rectangle.portrait")
                }
            }
        }
        .sheet(isPresented: $showsInspector) {
            DonkNavigationContainer {
                DonkNetworkUI.makeRootView()
            }
            .donkTheme()
        }
        .sheet(item: $editingExchange) { exchange in
            DonkNavigationContainer {
                DonkNetworkUI.makeBreakpointView(exchange)
            }
            .donkTheme()
        }
        .onAppear { model.start() }
        .onDisappear { model.closeChat() }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.pending.map(\.id))
    }

    // MARK: - Server

    private var serverSection: some View {
        Section {
            HStack(spacing: 12) {
                serverIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text("In-app echo server")
                        .font(.body.weight(.semibold))
                    Text(serverSubtitle)
                        .font(.footnote.monospacedDigit())
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                if case .running = model.serverState {
                    StatusPill("LIVE", tone: .success, isLive: true)
                }
            }
            .padding(.vertical, 4)
            Toggle(isOn: $model.usesPublicServer) {
                DonkLabelRow(icon: "globe", tone: .info, title: "Public server", subtitle: "grpcb.in:9000 · hello.HelloService")
            }
        } footer: {
            Text("Every call below goes through DonkGRPC.interceptors(host:), so it is recorded, mockable and pausable.")
        }
    }

    @ViewBuilder
    private var serverIcon: some View {
        switch model.serverState {
        case .starting:
            ProgressView()
                .frame(width: 32, height: 32)
        case .running:
            DonkIconBadge("server.rack", tone: .grpc)
        case .failed:
            DonkIconBadge("exclamationmark.triangle.fill", tone: .error)
        }
    }

    private var serverSubtitle: String {
        switch model.serverState {
        case .starting: return "Starting…"
        case let .running(port): return "127.0.0.1:\(port) · plaintext HTTP/2"
        case let .failed(message): return message
        }
    }

    // MARK: - Calls

    private var unarySection: some View {
        Section("Unary") {
            actionRow(icon: "arrow.left.arrow.right", tone: .grpc, title: "Unary call", subtitle: "Echo.Get with auth metadata", action: model.unary)
            actionRow(icon: "xmark.octagon", tone: .warning, title: "Unary error", subtitle: "Server answers NOT_FOUND", action: model.unaryError)
            actionRow(icon: "timer", tone: .error, title: "Deadline exceeded", subtitle: "1.5 s handler, 500 ms deadline", action: model.deadlineExceeded)
        }
    }

    private var streamingSection: some View {
        Section("Streaming") {
            Button(action: model.serverStream) {
                VStack(alignment: .leading, spacing: 8) {
                    DonkLabelRow(icon: "arrow.down.to.line.compact", tone: .grpc, title: "Server stream", subtitle: "\(model.streamLength) messages over 4 s") {
                        if let progress = model.streamProgress {
                            Text("\(progress)/\(model.streamLength)")
                                .font(.footnote.monospacedDigit())
                                .foregroundColor(.secondary)
                        } else {
                            Image(systemName: "play.fill")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    if let progress = model.streamProgress {
                        ProgressView(value: Double(progress), total: Double(model.streamLength))
                            .tint(DonkColor.grpc)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.streamProgress != nil)
            actionRow(icon: "arrow.up.to.line.compact", tone: .grpc, title: "Client stream", subtitle: "5 messages, then one response", isBusy: model.isCollecting, action: model.clientStream)
            actionRow(icon: "stop.circle", tone: .neutral, title: "Cancel a stream", subtitle: "100-message stream, cancelled after 1.5 s", action: model.cancelStream)
            actionRow(
                icon: "bolt.horizontal",
                tone: .warning,
                title: "Burst stream",
                subtitle: "\(model.floodLength) messages, no delay; the render queue keeps memory bounded",
                isBusy: model.isFlooding,
                action: model.floodStream
            )
        }
    }

    private var chatSection: some View {
        Section {
            if model.isChatOpen {
                if model.chat.isEmpty {
                    Text("Say something to the echo server.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } else {
                    VStack(spacing: 8) {
                        ForEach(model.chat) { line in
                            ChatBubble(line: line)
                        }
                    }
                    .padding(.vertical, 4)
                }
                HStack(spacing: 8) {
                    TextField("Message", text: $model.chatDraft)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.send)
                        .onSubmit(model.sendChat)
                    Button(action: model.sendChat) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.chatDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityLabel("Send")
                }
                Button(role: .destructive, action: model.closeChat) {
                    Label("End chat", systemImage: "xmark.circle")
                        .foregroundColor(DonkColor.error)
                }
            } else {
                actionRow(icon: "bubble.left.and.bubble.right", tone: .grpc, title: "Bidirectional chat", subtitle: "Echo.Update stays open while you type", action: model.openChat)
            }
        } header: {
            Text("Bidirectional")
        }
    }

    private var publicSection: some View {
        Section("grpcb.in") {
            actionRow(icon: "hand.wave", tone: .info, title: "SayHello", subtitle: "Unary call over the internet", action: model.sayHello)
            actionRow(icon: "text.bubble", tone: .info, title: "LotsOfReplies", subtitle: "Server stream from grpcb.in", action: model.lotsOfReplies)
        }
    }

    // MARK: - Rules

    private var rulesSection: some View {
        Section {
            if model.hasSampleRules {
                actionRow(icon: "trash", tone: .error, title: "Remove sample rules", subtitle: "Back to real server responses", action: model.toggleSampleRules)
            } else {
                actionRow(icon: "wand.and.stars", tone: .accent, title: "Add sample gRPC rules", subtitle: "Mock Echo.Get · pause Echo.Expand", action: model.toggleSampleRules)
            }
        } header: {
            Text("Rules")
        } footer: {
            if model.hasSampleRules, !model.rulesEnabled {
                Text("Rules are switched off globally, so the sample rules are inactive.")
            } else {
                Text("Echo.Get answers from a local mock after 400 ms. Every Echo.Expand response pauses until you resume it here or in donk.")
            }
        }
    }

    private var breakpointsSection: some View {
        Section {
            ForEach(model.pending) { exchange in
                PausedExchangeRow(
                    exchange: exchange,
                    resume: { model.resume(exchange) },
                    abort: { model.abort(exchange) },
                    edit: { editingExchange = exchange }
                )
            }
        } header: {
            HStack {
                Text("Paused")
                CountBadge(model.pending.count, tone: .warning)
                Spacer()
                if model.pending.count > 1 {
                    Button("Resume all", action: model.resumeAll)
                        .font(.footnote.weight(.semibold))
                        .textCase(nil)
                }
            }
        }
    }

    // MARK: - Activity

    private var activitySection: some View {
        Section("Last results") {
            ForEach(model.activity) { item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: icon(for: item.outcome))
                        .foregroundColor(color(for: item.outcome))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.subheadline.weight(.semibold))
                        Text(item.detail)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .lineLimit(3)
                    }
                    Spacer(minLength: 0)
                    Text(DonkFormat.time(item.date))
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var callsSection: some View {
        Section {
            if model.recentEntries.isEmpty {
                EmptyStateView(
                    icon: "point.3.connected.trianglepath.dotted",
                    title: "No gRPC calls yet",
                    message: "Tap any button above. Calls appear here live, with their status and message count.",
                    tone: .grpc
                )
                .frame(minHeight: 220)
                .listRowBackground(Color.clear)
            } else {
                ForEach(model.recentEntries) { entry in
                    GRPCEntryRow(entry: entry)
                }
            }
        } header: {
            HStack {
                Text("Recent gRPC calls")
                Spacer()
                if !model.recentEntries.isEmpty {
                    Button("Clear", action: model.clearEntries)
                        .font(.footnote.weight(.semibold))
                        .textCase(nil)
                }
            }
        }
    }

    // MARK: - Helpers

    private func actionRow(
        icon: String,
        tone: DonkTone,
        title: String,
        subtitle: String,
        isBusy: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            DonkLabelRow(icon: icon, tone: tone, title: title, subtitle: subtitle) {
                if isBusy {
                    ProgressView()
                } else {
                    Image(systemName: "play.fill")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
    }

    private func icon(for outcome: GRPCDemoModel.Outcome) -> String {
        switch outcome {
        case .success: return "checkmark.circle.fill"
        case .failure: return "xmark.circle.fill"
        case .info: return "info.circle.fill"
        }
    }

    private func color(for outcome: GRPCDemoModel.Outcome) -> Color {
        switch outcome {
        case .success: return DonkColor.success
        case .failure: return DonkColor.error
        case .info: return DonkColor.info
        }
    }
}

private struct ChatBubble: View {
    let line: GRPCDemoModel.ChatLine

    var body: some View {
        HStack {
            if line.isMine { Spacer(minLength: 40) }
            Text(line.text)
                .font(.subheadline)
                .foregroundColor(line.isMine ? .white : .primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(line.isMine ? DonkColor.grpc : DonkColor.fill)
                )
                .contextMenu {
                    Button {
                        DonkPasteboard.copy(line.text, label: "Message")
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                }
            if !line.isMine { Spacer(minLength: 40) }
        }
    }
}

private struct PausedExchangeRow: View {
    let exchange: PausedExchange
    let resume: () -> Void
    let abort: () -> Void
    let edit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TonePill(exchange.phase == .request ? "REQUEST" : "RESPONSE", tone: .warning, icon: "pause.circle.fill")
                Text(exchange.ruleName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(DonkFormat.relative(exchange.createdAt))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            if !preview.isEmpty {
                Text(preview)
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
                    .lineLimit(3)
            }
            HStack(spacing: 8) {
                Button(action: resume) {
                    Label("Resume", systemImage: "play.fill")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(PillButtonStyle(color: DonkColor.success, isProminent: true))
                Button(action: abort) {
                    Label("Abort", systemImage: "stop.fill")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(PillButtonStyle(color: DonkColor.error, isProminent: false))
                Spacer(minLength: 0)
                Button(action: edit) {
                    Label("Edit", systemImage: "square.and.pencil")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(PillButtonStyle(color: DonkColor.accent, isProminent: false))
            }
        }
        .padding(.vertical, 4)
    }

    private var preview: String {
        let body: String
        switch exchange.payload {
        case let .request(request): body = request.body
        case let .response(response): body = response.body
        }
        let compact = (try? JSONValue.parse(body).compact()) ?? body
        return String(compact.prefix(240))
    }
}

private struct PillButtonStyle: ButtonStyle {
    let color: Color
    let isProminent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.footnote.weight(.semibold))
            .lineLimit(1)
            .foregroundColor(isProminent ? .white : color)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(isProminent ? color : color.opacity(0.14)))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .fixedSize()
            .contentShape(Capsule())
    }
}

private struct GRPCEntryRow: View {
    let entry: NetworkEntry

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    MethodBadge(entry.methodLabel)
                    if entry.origin != .network {
                        TonePill(originLabel, tone: .warning, icon: "wand.and.stars")
                    }
                }
                Text(DonkTextBreaking.breakable(entry.title))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(detail)
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            StatusPill(entry.statusLabel, tone: tone, isLive: entry.state.isInFlight)
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button {
                DonkPasteboard.copy(entry.request.url, label: "URL")
            } label: {
                Label("Copy URL", systemImage: "link")
            }
            Button {
                DonkPasteboard.copy(GRPCurlExporter.command(for: entry, plaintext: true), label: "grpcurl")
            } label: {
                Label("Copy grpcurl", systemImage: "terminal")
            }
        }
    }

    private var detail: String {
        var parts: [String] = []
        if let grpc = entry.grpc {
            parts.append("↑\(grpc.sentMessageCount) ↓\(grpc.receivedMessageCount) msgs")
        }
        if entry.state == .paused {
            parts.append("paused")
        } else if let duration = entry.duration {
            parts.append(DonkFormat.duration(duration))
        }
        if let host = entry.host {
            parts.append(host)
        }
        return parts.joined(separator: " · ")
    }

    private var originLabel: String {
        switch entry.origin {
        case .network: return ""
        case .mocked: return "Mocked"
        case .rewritten: return "Rewritten"
        case .breakpoint: return "Breakpoint"
        }
    }

    private var tone: DonkTone {
        if entry.state == .paused { return .warning }
        switch entry.statusCategory {
        case .pending: return .info
        case .success: return .success
        case .redirect: return .info
        case .clientError: return .warning
        case .serverError, .failure: return .error
        }
    }
}
