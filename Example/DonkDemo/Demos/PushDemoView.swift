import Donk
import DonkUI
import SwiftUI
import UserNotifications

struct PushDemoView: View {
    @ObservedObject private var inbox = PushInbox.shared
    @State private var permission: UNAuthorizationStatus = .notDetermined
    @State private var delay: TimeInterval = 1
    @State private var lastResult: PushSimulationResult?
    @State private var lastAction = ""
    @State private var isShowingRoot = false
    @State private var isBusy = false

    init() {
        PushDemoBootstrap.startIfNeeded()
    }

    var body: some View {
        List {
            setupSection
            ForEach(PushDemoPayloads.all) { template in
                templateSection(template)
            }
            if let lastResult {
                resultSection(lastResult)
            }
            inboxSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Push notifications")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    isShowingRoot = true
                } label: {
                    Image(systemName: "ladybug.fill")
                }
                .accessibilityLabel("Open DonkPush")
            }
        }
        .sheet(isPresented: $isShowingRoot) {
            DonkNavigationContainer {
                DonkPush.makeRootView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { isShowingRoot = false }
                        }
                    }
            }
            .donkTheme()
        }
        .task { await refreshPermission() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            Task { await refreshPermission() }
        }
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("-DonkPushOpenRoot") {
                isShowingRoot = true
            }
        }
    }

    // MARK: - Sections

    private var setupSection: some View {
        Section {
            HStack {
                Label("Permission", systemImage: "bell.badge")
                Spacer()
                StatusPill(permissionTitle, tone: permissionTone)
            }
            if permission == .notDetermined {
                Button {
                    Task {
                        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                        await refreshPermission()
                    }
                } label: {
                    Label("Request permission", systemImage: "hand.raised")
                }
            }
            Picker("Banner delay", selection: $delay) {
                Text("1 s").tag(TimeInterval(1))
                Text("5 s").tag(TimeInterval(5))
                Text("10 s").tag(TimeInterval(10))
            }
            .pickerStyle(.segmented)
            Button {
                isShowingRoot = true
            } label: {
                Label("Open DonkPush", systemImage: "ladybug")
            }
            HStack {
                Label("History", systemImage: "clock.arrow.circlepath")
                Spacer()
                Text("\(DonkPush.recordCount()) recorded")
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("Setup")
        } footer: {
            Text("Banner schedules a real local notification with the payload as userInfo. Inject calls the app's UNUserNotificationCenter delegate directly. Silent calls didReceiveRemoteNotification. With a 5 s or 10 s delay, background or kill the app to test cold start.")
        }
    }

    private func templateSection(_ template: PushTemplate) -> some View {
        Section {
            Text(template.payload)
                .font(.caption.monospaced())
                .foregroundColor(.secondary)
                .lineLimit(3)
            HStack(spacing: 8) {
                if PushDemoPayloads.isSilent(template) {
                    actionButton("Silent", icon: "moon.zzz.fill", tint: DonkColor.grpc) {
                        await run(template, .silent)
                    }
                } else {
                    actionButton("Banner", icon: "bell.badge.fill", tint: DonkColor.accent) {
                        await run(template, .banner(delay: delay))
                    }
                    actionButton("Inject", icon: "arrow.down.right.circle.fill", tint: DonkColor.info) {
                        await run(template, .inject)
                    }
                    actionButton("Tap", icon: "hand.tap.fill", tint: DonkColor.success) {
                        await run(template, .tap)
                    }
                }
            }
            .buttonStyle(.borderless)
        } header: {
            Text(template.name)
        }
    }

    private func resultSection(_ result: PushSimulationResult) -> some View {
        Section {
            Label(result.title, systemImage: icon(for: result.status))
                .foregroundColor(color(for: result.status))
            ForEach(Array(result.lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("Last result · \(lastAction)")
        }
    }

    private var inboxSection: some View {
        Section {
            if inbox.items.isEmpty {
                Text("Nothing received yet. Send a push above; the app delegate records exactly what it receives.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            ForEach(inbox.items.prefix(20)) { item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(item.source)
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(item.date, style: .time)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if let match = PushDemoPayloads.matchingTemplate(for: item.payload) {
                        TonePill(text: "Identical to “\(match.name)”", tone: .success, icon: "checkmark.seal.fill")
                    } else {
                        TonePill(text: "Not a demo template (composer or simctl)", tone: .neutral, icon: "questionmark.circle")
                    }
                    Text(item.payload)
                        .font(.caption2.monospaced())
                        .foregroundColor(.secondary)
                        .lineLimit(8)
                }
                .padding(.vertical, 2)
                .contextMenu {
                    Button {
                        DonkPasteboard.copy(item.payload, label: "Payload")
                    } label: {
                        Label("Copy payload", systemImage: "doc.on.doc")
                    }
                }
            }
        } header: {
            Text("App delegate inbox (\(inbox.items.count))")
        } footer: {
            Text("Recorded by DemoAppDelegate in willPresent, didReceive and didReceiveRemoteNotification. The green badge means the userInfo deep-equals a template payload.")
        }
    }

    // MARK: - Helpers

    private func actionButton(_ title: String, icon: String, tint: Color, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            Label(title, systemImage: icon)
                .font(.footnote.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .foregroundColor(tint)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.14)))
        }
        .disabled(isBusy)
    }

    @MainActor
    private func run(_ template: PushTemplate, _ method: PushSimulationMethod) async {
        isBusy = true
        lastAction = "\(template.name) · \(label(for: method))"
        let result = await DonkPush.simulate(template.payload, via: method)
        lastResult = result
        isBusy = false
        switch result.status {
        case .success: DonkToast.show(result.title, tone: .success)
        case .warning: DonkToast.show(result.title, tone: .warning)
        case .failure: DonkToast.show(result.title, tone: .error)
        }
        await refreshPermission()
    }

    private func label(for method: PushSimulationMethod) -> String {
        switch method {
        case let .banner(delay): return "Banner \(Int(delay)) s"
        case .inject: return "Inject"
        case .tap: return "Tap"
        case .silent: return "Silent"
        }
    }

    @MainActor
    private func refreshPermission() async {
        permission = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    private var permissionTitle: String {
        switch permission {
        case .authorized: return "Authorized"
        case .denied: return "Denied"
        case .provisional: return "Provisional"
        case .ephemeral: return "Ephemeral"
        case .notDetermined: return "Not determined"
        @unknown default: return "Unknown"
        }
    }

    private var permissionTone: DonkTone {
        switch permission {
        case .authorized, .provisional, .ephemeral: return .success
        case .denied: return .error
        default: return .warning
        }
    }

    private func icon(for status: PushSimulationResult.Status) -> String {
        switch status {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failure: return "xmark.octagon.fill"
        }
    }

    private func color(for status: PushSimulationResult.Status) -> Color {
        switch status {
        case .success: return DonkColor.success
        case .warning: return DonkColor.warning
        case .failure: return DonkColor.error
        }
    }
}
