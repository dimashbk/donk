import Donk
import DonkUI
import SwiftUI

struct NetworkDemoView: View {
    @StateObject private var model = NetworkDemoModel()
    @State private var showsCaptured = false
    @State private var didAutorun = false

    var body: some View {
        List {
            captureSection
            if !model.paused.isEmpty {
                pausedSection
            }
            recentSection
            ForEach(NetworkDemoSection.allCases) { section in
                Section {
                    ForEach(section.actions) { action in
                        actionRow(action)
                    }
                } header: {
                    DonkSectionHeader(section.rawValue)
                }
            }
            rulesSection
        }
        .donkListStyle()
        .donkNavigationTitle("HTTP / URLSession")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showsCaptured = true
                } label: {
                    Image(systemName: "list.bullet.rectangle.portrait")
                }
                .accessibilityLabel("Captured requests")
            }
        }
        .sheet(isPresented: $showsCaptured) {
            CapturedEntriesView(model: model)
        }
        .onAppear(perform: autorunIfRequested)
    }

    // MARK: - Sections

    private var captureSection: some View {
        Section {
            Toggle(isOn: Binding(get: { model.isRunning }, set: { model.setRunning($0) })) {
                DonkLabelRow(
                    icon: "antenna.radiowaves.left.and.right",
                    tone: model.isRunning ? .success : .neutral,
                    title: "Capture",
                    subtitle: model.isRunning ? "Every URLSession request is recorded" : "Stopped — requests pass through untouched"
                )
            }
            HStack(spacing: DonkSpacing.m) {
                DonkIconBadge("tray.full", tone: .accent, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("NetworkStore.shared.count")
                        .font(DonkFont.codeCaption)
                        .foregroundColor(DonkColor.textSecondary)
                    Text(DonkFormat.number(model.count))
                        .font(DonkFont.metric)
                        .foregroundColor(DonkColor.textPrimary)
                        .monospacedDigit()
                }
                Spacer()
                Button("Clear") { model.clear() }
                    .buttonStyle(.bordered)
                    .disabled(model.count == 0)
            }
            .padding(.vertical, DonkSpacing.xxs)
            if let result = model.lastResult {
                Label {
                    Text(DonkTextBreaking.breakable(result))
                        .font(DonkFont.caption)
                        .foregroundColor(DonkColor.textSecondary)
                } icon: {
                    Image(systemName: "checkmark.circle")
                        .foregroundColor(DonkColor.success)
                }
            }
        } header: {
            DonkSectionHeader("Capture")
        }
    }

    private var recentSection: some View {
        Section {
            if model.recent.isEmpty {
                HStack(spacing: DonkSpacing.m) {
                    Image(systemName: "network.slash")
                        .foregroundColor(DonkColor.textTertiary)
                    Text("Nothing captured yet. Tap any request below.")
                        .font(DonkFont.callout)
                        .foregroundColor(DonkColor.textSecondary)
                }
                .padding(.vertical, DonkSpacing.s)
            } else {
                ForEach(model.recent) { entry in
                    NavigationLink {
                        CapturedEntryDetailView(entryID: entry.id, model: model)
                    } label: {
                        CapturedEntryRow(entry: entry)
                    }
                }
            }
        } header: {
            DonkSectionHeader("Last 5 captured", icon: "clock.arrow.circlepath", count: model.count) {
                if model.count > 0 {
                    Button("All") { showsCaptured = true }
                        .font(DonkFont.captionEmphasized)
                }
            }
        }
    }

    private var pausedSection: some View {
        Section {
            ForEach(model.paused) { exchange in
                PausedExchangeRow(exchange: exchange, model: model)
            }
        } header: {
            DonkSectionHeader("Paused at breakpoint", icon: "pause.circle.fill", count: model.paused.count)
        }
    }

    private var rulesSection: some View {
        Section {
            Button {
                model.addSampleRules()
            } label: {
                DonkLabelRow(icon: "wand.and.stars", tone: .success, title: "Add sample rules", subtitle: "Mock /todos/1 locally · pause httpbin /anything") {
                    if model.sampleRulesActive {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(DonkColor.success)
                    }
                }
            }
            .disabled(model.sampleRulesActive)
            .opacity(model.sampleRulesActive ? 0.55 : 1)
            Button {
                model.removeSampleRules()
            } label: {
                DonkLabelRow(icon: "trash", tone: .error, title: "Remove sample rules", subtitle: "Requests go to the network again")
            }
            .disabled(!model.sampleRulesActive)
            .opacity(model.sampleRulesActive ? 1 : 0.45)
            actionRow(.getJSON, subtitleOverride: model.sampleRulesActive ? "Answered by the mock, never leaves the device" : nil)
            actionRow(.breakpointTarget)
        } header: {
            DonkSectionHeader("Rules & breakpoints", icon: "slider.horizontal.3")
        } footer: {
            Text("The breakpoint waits for you in the Paused section above. Unresolved breakpoints resume unedited after 5 minutes.")
                .font(DonkFont.caption)
        }
    }

    // MARK: - Rows

    private func actionRow(_ action: NetworkDemoAction, subtitleOverride: String? = nil) -> some View {
        Button {
            DonkHaptics.light()
            model.run(action)
        } label: {
            DonkLabelRow(icon: action.icon, tone: action.tone, title: action.title, subtitle: subtitleOverride ?? action.subtitle) {
                if model.running.contains(action) {
                    ProgressView()
                } else {
                    MethodBadge(action.method)
                }
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    private func autorunIfRequested() {
        guard !didAutorun else { return }
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-DonkNetworkDemoAutorun") {
            didAutorun = true
            model.runAll([
                .getJSON, .postJSON, .put, .notFound, .serverError, .redirect, .gzip, .image, .largeJSON, .chunked,
                .sharedCompletion, .asyncAwait, .delegateSession, .multipart, .startCancel, .dnsFailure, .sse,
            ])
        } else if arguments.contains("-DonkNetworkDemoMock") {
            didAutorun = true
            model.runMockedRequest()
        } else if arguments.contains("-DonkNetworkDemoRules") {
            didAutorun = true
            model.addSampleRules()
            model.runAll([.getJSON, .breakpointTarget, .redirect, .serverError])
        }
    }
}

// MARK: - Paused exchange

private struct PausedExchangeRow: View {
    let exchange: PausedExchange
    @ObservedObject var model: NetworkDemoModel

    var body: some View {
        VStack(alignment: .leading, spacing: DonkSpacing.s) {
            HStack(spacing: DonkSpacing.s) {
                MethodBadge(method)
                TonePill(exchange.phase == .request ? "Request" : "Response", tone: .warning, icon: "pause.fill")
                Spacer()
                Text(DonkFormat.relative(exchange.createdAt))
                    .font(DonkFont.caption2)
                    .foregroundColor(DonkColor.textTertiary)
            }
            Text(DonkTextBreaking.breakable(url))
                .font(DonkFont.codeCaption)
                .foregroundColor(DonkColor.textPrimary)
                .lineLimit(3)
            Text(exchange.ruleName)
                .font(DonkFont.caption)
                .foregroundColor(DonkColor.textSecondary)
            HStack(spacing: DonkSpacing.s) {
                Button("Resume") { model.resume(exchange) }
                    .buttonStyle(.borderedProminent)
                Button("Edit") { model.editAndResume(exchange) }
                    .buttonStyle(.bordered)
                if exchange.phase == .request {
                    Button("Respond") { model.respondLocally(exchange) }
                        .buttonStyle(.bordered)
                }
                Button("Abort", role: .destructive) { model.abort(exchange) }
                    .buttonStyle(.bordered)
            }
            .font(DonkFont.captionEmphasized)
            .controlSize(.small)
        }
        .padding(.vertical, DonkSpacing.xs)
    }

    private var method: String {
        if case let .request(request) = exchange.payload { return request.method }
        return "RESP"
    }

    private var url: String {
        if case let .request(request) = exchange.payload { return request.url }
        if case let .response(response) = exchange.payload { return "HTTP \(response.statusCode) · \(response.body.count) chars" }
        return ""
    }
}
